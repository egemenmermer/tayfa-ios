import AVFoundation
import AVKit
import Combine
import LiveKit
import MediaPlayer
import RoomsCore
import UIKit

/// The community cinema hall's shared player: relay playback, live alignment and film sync
/// (desktop `apps/desktop/src/cinema/HallPlayer.tsx` and `HallStage.tsx`).
///
/// Contract for the hall UI:
/// - `HallPlayerController(api:hallID:activity:)`, created once per open hall; `start()` / `stop()`.
/// - It follows `activity.room` (the hall's activity snapshot) on its own and sends the commands playback
///   needs (`queue.next`, `playback`) through `activity`. The hall UI runs the activity's polling.
/// - `onZap` asks the hall UI to open the previous (-1) or next (+1) live channel.
/// - `HallPlayerSurface(player:style:)` renders the stage or the mini player for the same controller.
@MainActor final class HallPlayerController: NSObject, ObservableObject {
    enum Style { case stage, mini }
    enum Phase: Equatable { case idle, loading, playing, buffering, paused, failed }

    @Published private(set) var phase: Phase = .idle
    /// Why the stream cannot play right now (desktop copy), or nil.
    @Published private(set) var failure: String?
    /// Live: this viewer paused or fell behind and no longer sees what the hall sees.
    @Published private(set) var behindLive = false
    @Published private(set) var localPaused = false
    /// Films and series: the position in the work and its length, in seconds.
    @Published private(set) var positionSec: Double = 0
    @Published private(set) var durationSec: Double?
    /// The relayed source's audio streams and the one the hall hears.
    @Published private(set) var audioTracks: [CinemaAudioTrack] = []
    @Published private(set) var audioTrack: Int?
    @Published private(set) var badges: [String] = []
    /// Only this viewer's sound; never shared with the hall.
    @Published private(set) var muted = false
    @Published private(set) var pictureInPictureActive = false
    @Published private(set) var pictureInPicturePossible = false
    /// The official YouTube player while the hall plays a YouTube item.
    @Published private(set) var youtube: YouTubePlayerController?
    /// A short-lived message after a refused action (audio language).
    @Published private(set) var notice: String?

    let api: APIClient
    let hallID: String
    let activity: WatchTogetherModel
    var onZap: ((Int) -> Void)?
    let player = AVPlayer()

    private var started = false
    private var subscriptions: Set<AnyCancellable> = []
    private var itemSubscriptions: Set<AnyCancellable> = []
    private var loop: Task<Void, Never>?
    private var watchTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var youtubeTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?
    /// `item:epoch:attempt` of the relay that is loaded or loading.
    private var loadedKey: String?
    private var attempt = 0
    private var reconnects = 0
    private var source: CinemaWatch?
    private var loader: CinemaRelayLoader?
    private var lastPlaylist: CinemaPlaylist.Summary?
    private var timers = HallSync.VODTimers()
    private var seekAllowedAtMs: Double = 0
    private var endedFor: String?
    private var badgeCache: [String: [String]] = [:]
    private var youtubeItem: String?
    private var youtubeTimeline: ActivityTimeline?
    private var youtubeLastSync = Date.distantPast
    private var audioRequirement: SessionRequirementHandle?
    private var remoteTargets: [Any] = []
    private var nowPlayingAt = Date.distantPast
    private struct LayerEntry { weak var layer: AVPlayerLayer?; let style: Style }
    private var layers: [ObjectIdentifier: LayerEntry] = [:]
    private var layerOrder: [ObjectIdentifier] = []
    private var pip: AVPictureInPictureController?
    private var pipPossible: AnyCancellable?
    private var backgrounded = false
    private var pictureInPictureStarting = false
    private struct HostEntry { weak var view: UIView? }
    private var youtubeHosts: [HostEntry] = []

    init(api: APIClient, hallID: String, activity: WatchTogetherModel) {
        self.api = api; self.hallID = hallID; self.activity = activity
        super.init()
        player.automaticallyWaitsToMinimizeStalling = true
        player.preventsDisplaySleepDuringVideoPlayback = true
    }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        activity.$room.receive(on: DispatchQueue.main).sink { [weak self] room in MainActor.assumeIsolated { self?.roomChanged(room) } }.store(in: &subscriptions)
        player.publisher(for: \.timeControlStatus).receive(on: DispatchQueue.main).sink { [weak self] status in MainActor.assumeIsolated { self?.controlStatusChanged(status) } }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification).receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.enteredBackground(true) } }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification).receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.enteredBackground(false) } }.store(in: &subscriptions)
        registerRemoteCommands()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(HallSync.tickSeconds))
                guard let self, !Task.isCancelled else { return }
                self.tick()
            }
        }
        roomChanged(activity.room)
    }

    func stop() {
        guard started else { return }
        started = false
        subscriptions.removeAll(); itemSubscriptions.removeAll()
        [loop, watchTask, reconnectTask, youtubeTask, noticeTask].forEach { $0?.cancel() }
        loop = nil; watchTask = nil; reconnectTask = nil; youtubeTask = nil; noticeTask = nil
        if pip?.isPictureInPictureActive == true { pip?.stopPictureInPicture() }
        pip = nil; pipPossible = nil; pictureInPictureActive = false; pictureInPicturePossible = false
        clearRelay(); dropYouTube()
        loadedKey = nil; reconnects = 0; endedFor = nil
        phase = .idle; failure = nil; notice = nil
        unregisterRemoteCommands()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        releaseAudio()
    }

    // MARK: State for the surface

    var current: ActivityQueueItem? { activity.room?.current }
    var title: String? { current?.media.title }
    var isLive: Bool { current?.media.isLive == true }
    var isRelay: Bool { current?.media.isCommunity == true }
    var viewers: Int { activity.room?.participants.count ?? 0 }
    var canDirect: Bool { activity.room != nil && activity.canDirect }
    var hasNext: Bool { activity.room?.next != nil }
    /// Why the remote is out of reach (desktop `directReason`).
    var directReason: String {
        guard activity.room != nil else { return "Salon hizmeti bağlı değil." }
        if activity.room?.participant(activity.me)?.canControl == false { return "Bu salonda oynatmayı yönetme iznin yok." }
        return "Kumanda ev sahibinde. Sıraya öneri ekleyebilirsin."
    }
    /// Whether the room's film or video is running (live channels always run).
    var roomPlaying: Bool { isLive || activity.room?.timeline.playing == true }
    /// The room position for the seek bar: the player's work position, else the shared timeline.
    var displayPosition: Double {
        guard let room = activity.room else { return 0 }
        if youtube != nil || positionSec <= 0 { return min(durationSec ?? .infinity, max(0, expected(room))) }
        return positionSec
    }

    // MARK: Following the room

    private func roomChanged(_ room: ActivityRoom?) {
        guard started else { return }
        guard let room, let item = room.current else {
            clearRelay(); dropYouTube(); loadedKey = nil
            phase = .idle; failure = nil; durationSec = nil; positionSec = 0; badges = []
            releaseAudio()
            updateNowPlaying(force: true)
            return
        }
        if item.media.isCommunity, item.media.ref != nil {
            dropYouTube()
            let key = "\(item.id):\(room.timeline.epoch):\(attempt)"
            if key != loadedKey { loadedKey = key; watch(item) }
        } else if item.media.kind == "youtube", let videoID = item.media.videoId {
            clearRelay(); loadedKey = nil
            if youtubeItem != item.id { loadYouTube(item, videoID: videoID) }
            else if let previous = youtubeTimeline, previous != room.timeline { syncYouTube() }
            youtubeTimeline = room.timeline
        } else {
            clearRelay(); dropYouTube(); loadedKey = nil
            phase = .idle
        }
        updateNowPlaying(force: true)
    }

    private func watch(_ item: ActivityQueueItem) {
        watchTask?.cancel(); reconnectTask?.cancel()
        // The last frame stays on screen until the next channel or film is ready.
        clearRelay(keepFrame: true)
        localPaused = false; behindLive = false; positionSec = 0; durationSec = nil; failure = nil
        audioTracks = []; audioTrack = nil
        phase = .loading
        acquireAudio()
        guard let ref = item.media.ref else { return }
        loadBadges(ref)
        watchTask = Task { [weak self] in
            // The hall may have moved on, or the relay not caught up with the room yet.
            var retries = 2
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    let value = try await self.api.cinemaWatch(hall: self.hallID)
                    try Task.checkCancellation()
                    guard value.itemRef == ref else {
                        guard retries > 0 else { return }
                        retries -= 1
                        try await Task.sleep(for: .milliseconds(700))
                        continue
                    }
                    self.play(value)
                    return
                } catch is CancellationError {
                    return
                } catch {
                    self.phase = .failed; self.failure = Self.text(error)
                    return
                }
            }
        }
    }

    private func play(_ watch: CinemaWatch) {
        reconnects = 0
        source = watch
        durationSec = watch.durationSec; audioTracks = watch.audioTracks; audioTrack = watch.audioTrack
        timers = HallSync.VODTimers(); seekAllowedAtMs = 0; lastPlaylist = nil
        let session = watch.session
        let loader = CinemaRelayLoader(api: api, hallID: hallID, watch: watch,
                                       onGone: { [weak self] in Task { @MainActor in self?.relayGone(session) } },
                                       onPlaylist: { [weak self] summary in Task { @MainActor in self?.playlistServed(summary, session: session) } })
        self.loader = loader
        let asset = AVURLAsset(url: loader.url)
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)
        let item = AVPlayerItem(asset: asset)
        // Keeps the pitch while live alignment plays at 0.95–1.05×.
        item.audioTimePitchAlgorithm = .timeDomain
        observe(item)
        player.isMuted = muted
        player.replaceCurrentItem(with: item)
        preferMovieAudio()
        if watch.live || activity.room?.timeline.playing == true { player.play() }
        refreshPictureInPicture()
        updateNowPlaying(force: true)
    }

    private func observe(_ item: AVPlayerItem) {
        itemSubscriptions.removeAll()
        item.publisher(for: \.status).receive(on: DispatchQueue.main)
            .sink { [weak self] status in MainActor.assumeIsolated { self?.itemStatusChanged(status) } }.store(in: &itemSubscriptions)
        NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification, object: item).receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.playedToEnd() } }.store(in: &itemSubscriptions)
        NotificationCenter.default.publisher(for: AVPlayerItem.failedToPlayToEndTimeNotification, object: item).receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.itemFailed() } }.store(in: &itemSubscriptions)
        NotificationCenter.default.publisher(for: AVPlayerItem.newErrorLogEntryNotification, object: item).receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.errorLogged() } }.store(in: &itemSubscriptions)
    }

    private func clearRelay(keepFrame: Bool = false) {
        watchTask?.cancel(); watchTask = nil
        reconnectTask?.cancel(); reconnectTask = nil
        itemSubscriptions.removeAll()
        loader?.cancelAll(); loader = nil
        source = nil; lastPlaylist = nil
        if player.currentItem != nil { player.pause(); if !keepFrame { player.replaceCurrentItem(with: nil) } }
        behindLive = false; localPaused = false
        pip?.canStartPictureInPictureAutomaticallyFromInline = false
    }

    private func playlistServed(_ summary: CinemaPlaylist.Summary, session: String) {
        guard source?.session == session else { return }
        lastPlaylist = summary
    }

    /// 404/410: the relay session ended (the hall moved on, the audio changed or the relay restarted).
    private func relayGone(_ session: String) {
        guard source?.session == session else { return }
        reconnect()
    }
    private func reconnect() {
        guard reconnectTask == nil else { return }
        guard reconnects < HallSync.maxReconnects else {
            phase = .failed; failure = CinemaError(code: "CINEMA_STREAM_FAILED").localizedDescription
            return
        }
        reconnects += 1
        phase = .loading; failure = nil
        let delay = HallSync.reconnectDelay(attempt: reconnects)
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.reconnectTask = nil
            self.watchAgain()
        }
    }
    private func watchAgain() {
        attempt += 1
        roomChanged(activity.room)
    }

    private func itemStatusChanged(_ status: AVPlayerItem.Status) {
        switch status {
        case .readyToPlay: if phase == .loading, player.timeControlStatus == .paused, !roomPlaying { phase = .paused }
        case .failed: itemFailed()
        default: break
        }
    }
    private func itemFailed() {
        guard source != nil, reconnectTask == nil else { return }
        let status = player.currentItem?.errorLog()?.events.last?.errorStatusCode ?? 0
        if [401, 404, 410].contains(status) { reconnect(); return }
        phase = .failed; failure = CinemaError(code: "CINEMA_STREAM_FAILED").localizedDescription
    }
    /// A 410 on a segment means the relay session is over; other HTTP errors are left to AVPlayer's retries.
    private func errorLogged() {
        guard let source, player.currentItem?.errorLog()?.events.last?.errorStatusCode == 410 else { return }
        relayGone(source.session)
    }
    private func controlStatusChanged(_ status: AVPlayer.TimeControlStatus) {
        guard source != nil, phase != .failed else { return }
        switch status {
        case .playing: phase = .playing; failure = nil
        case .waitingToPlayAtSpecifiedRate: if phase != .loading { phase = .buffering }
        case .paused: if phase != .loading || player.currentItem?.status == .readyToPlay { phase = .paused }
        @unknown default: break
        }
        refreshPictureInPicture()
        updateNowPlaying(force: true)
    }

    /// A film's natural end moves the hall on, once per opening and only while it is still the current item.
    private func playedToEnd() {
        guard let source, !source.live, let room = activity.room, let item = room.current, item.media.ref == source.itemRef else { return }
        let key = HallSync.endKey(itemID: item.id, epoch: room.timeline.epoch)
        guard endedFor != key else { return }
        endedFor = key
        activity.quiet(.next(fromItemID: item.id, skip: false))
    }

    // MARK: Sync loop (once a second)

    private func tick() {
        if let youtube {
            if youtube.ready { youtube.command("position") }
            updateNowPlaying(force: false)
            return
        }
        guard let source, let item = player.currentItem, item.status == .readyToPlay, let room = activity.room,
              room.current?.media.ref == source.itemRef else { return }
        if roomPlaying { preferMovieAudio() }
        let now = Date().timeIntervalSince1970 * 1000
        let window = seekWindow(item), currentTime = item.currentTime().seconds
        guard currentTime.isFinite else { return }
        if source.live {
            if localPaused { if !behindLive { behindLive = true }; return }
            let step = HallSync.live(currentTime: currentTime, window: window, nowMs: now, seekAllowedAtMs: seekAllowedAtMs)
            if let target = step.seekTo { seekAllowedAtMs = now + 3000; seek(target); setRate(1) }
            else { setRate(step.rate) }
            if behindLive != step.behindLive { behindLive = step.behindLive }
            if player.timeControlStatus == .paused { player.play() }
            updateNowPlaying(force: false)
            return
        }
        let target = expected(room)
        let work = HallSync.workPosition(offsetSec: source.offsetSec, originPdtMs: source.originPdtMs, playingDateMs: playingDateMs(item, window: window, currentTime: currentTime), currentTime: currentTime)
        // Whole seconds are enough for the seek bar and avoid redrawing the stage on every tick.
        if Int(positionSec) != Int(max(0, work)) || positionSec == 0 { positionSec = max(0, work) }
        switch HallSync.vod(target: target, work: work, currentTime: currentTime, window: window, nowMs: now, timers: &timers) {
        case .rewatch: watchAgain(); return
        case .seek(let position): seek(position)
        case .none: break
        }
        if room.timeline.playing, player.timeControlStatus == .paused { player.play() }
        if !room.timeline.playing, player.timeControlStatus != .paused { player.pause() }
        updateNowPlaying(force: false)
    }

    private func expected(_ room: ActivityRoom) -> Double {
        WatchSync.expectedPosition(room.timeline, nowMs: Date().timeIntervalSince1970 * 1000, serverOffsetMs: activity.serverOffsetMs)
    }
    /// The seekable window, from the start of the first range to the end of the last.
    private func seekWindow(_ item: AVPlayerItem) -> ClosedRange<Double>? {
        let ranges = item.seekableTimeRanges.map(\.timeRangeValue)
        guard let first = ranges.first, let last = ranges.last else { return nil }
        let start = first.start.seconds, end = last.end.seconds
        guard start.isFinite, end.isFinite, end >= start else { return nil }
        return start...end
    }
    /// EXT-X-PROGRAM-DATE-TIME of what is on screen (films' work position only); the loader's last playlist when AVPlayer has none.
    private func playingDateMs(_ item: AVPlayerItem, window: ClosedRange<Double>?, currentTime: Double) -> Double? {
        if let date = item.currentDate() { return date.timeIntervalSince1970 * 1000 }
        return HallSync.estimatedDateMs(firstPdtMs: lastPlaylist?.firstPdtMs, windowStart: window?.lowerBound, currentTime: currentTime)
    }
    private func seek(_ seconds: Double) {
        player.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }
    private func setRate(_ rate: Double) {
        guard player.timeControlStatus != .paused, abs(Double(player.rate) - rate) > 0.001 else { return }
        player.rate = Float(rate)
    }

    // MARK: Controls

    /// Live: catch up with the hall.
    func goLive() {
        localPaused = false; behindLive = false
        if let item = player.currentItem, let window = seekWindow(item) { seek(HallSync.liveEdge(window)) }
        player.play()
    }
    /// Live only: pause or resume for this viewer.
    func toggleLocalPause() {
        guard isLive else { return }
        localPaused.toggle()
        if localPaused { player.pause(); behindLive = true } else { player.play() }
    }
    func retry() {
        reconnects = 0; failure = nil
        if youtubeItem != nil, let item = current, let videoID = item.media.videoId { loadYouTube(item, videoID: videoID) } else { watchAgain() }
    }
    /// Films and YouTube: play or pause for everyone (remote holder).
    func togglePlayback() {
        guard canDirect, !isLive, let room = activity.room else { return }
        var position = displayPosition
        // A finished video starts over instead of pausing at its end.
        if !room.timeline.playing, let length = youtube?.duration ?? durationSec, length > 0, position >= length - 1 { position = 0 }
        activity.run(.playback(playing: !room.timeline.playing, positionSec: position))
    }
    /// Films and YouTube: move everyone to `seconds` (remote holder).
    func seekShared(to seconds: Double) {
        guard canDirect, !isLive, let room = activity.room else { return }
        activity.run(.playback(playing: room.timeline.playing, positionSec: min(durationSec ?? youtube?.duration ?? seconds, max(0, seconds))))
    }
    func skip() {
        guard canDirect, let item = current, hasNext else { return }
        activity.run(.next(fromItemID: item.id, skip: true))
    }
    func zap(_ step: Int) {
        guard canDirect else { return }
        onZap?(step)
    }
    func toggleMute() {
        muted.toggle()
        player.isMuted = muted
        youtube?.command("volume", ["volume": muted ? 0 : 100])
    }
    /// The hall's audio language: the remote holder picks it for everyone and the relay restarts with it.
    func setAudioTrack(_ track: Int) {
        guard canDirect, let ref = current?.media.ref, track != audioTrack else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                self.audioTrack = try await self.api.cinemaSetAudio(hall: self.hallID, ref: ref, track: track) ?? track
                self.retry()
            } catch { self.show(Self.text(error)) }
        }
    }
    private func show(_ text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }
    private func loadBadges(_ ref: String) {
        if let cached = badgeCache[ref] { badges = cached; return }
        badges = []
        Task { [weak self] in
            guard let self, let details = try? await self.api.cinemaDetails(hall: self.hallID, ref: ref) else { return }
            self.badgeCache[ref] = details.item.badges
            if self.current?.media.ref == ref { self.badges = details.item.badges }
        }
    }
    static func text(_ error: Error) -> String {
        if let error = error as? CinemaError { return error.localizedDescription }
        if let error = error as? ActivityError { return error.localizedDescription }
        return CinemaError(code: "CINEMA_STREAM_FAILED").localizedDescription
    }

    // MARK: YouTube items (desktop `CinemaYouTubeStage`)

    private func loadYouTube(_ item: ActivityQueueItem, videoID: String) {
        dropYouTube()
        youtubeItem = item.id; youtubeTimeline = activity.room?.timeline
        phase = .loading; failure = nil; badges = []; durationSec = nil
        acquireAudio()
        youtubeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let page = try await self.api.youtubePlayer(videoID: videoID)
                let origin = await self.api.origin
                guard !Task.isCancelled, self.youtubeItem == item.id else { return }
                let controller = YouTubePlayerController(url: page.url, nonce: page.nonce, origin: origin)
                controller.onEvent = { [weak self] event, data in self?.youtubeEvent(event, data) }
                self.youtube = controller
                self.placeYouTube()
            } catch is CancellationError {
                return
            } catch {
                self.phase = .failed; self.failure = YouTubePlayerController.errorText(0)
            }
        }
    }
    private func dropYouTube() {
        youtubeTask?.cancel(); youtubeTask = nil
        youtube?.onEvent = nil
        youtube?.webView.removeFromSuperview()
        youtube = nil; youtubeItem = nil; youtubeTimeline = nil
    }
    /// The YouTube page is a single web view: the newest host in a window (full screen, stage, mini) shows it.
    func attachYouTube(_ host: UIView) {
        youtubeHosts.removeAll { $0.view == nil || $0.view === host }
        youtubeHosts.append(HostEntry(view: host))
        placeYouTube()
    }
    func detachYouTube(_ host: UIView) {
        youtubeHosts.removeAll { $0.view == nil || $0.view === host }
        placeYouTube()
    }
    func placeYouTube() {
        guard let webView = youtube?.webView, let host = youtubeHosts.last(where: { $0.view?.window != nil })?.view, webView.superview !== host else { return }
        webView.frame = host.bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.addSubview(webView)
    }
    private func syncYouTube() {
        guard let youtube, youtube.ready, let room = activity.room, room.current?.id == youtubeItem else { return }
        youtubeLastSync = Date()
        youtube.command("seek", ["positionSec": expected(room)])
        youtube.command(room.timeline.playing ? "play" : "pause")
    }
    private func youtubeEvent(_ event: String, _ data: [String: Any]) {
        guard let youtube, let room = activity.room, let item = room.current, item.id == youtubeItem else { return }
        switch event {
        case "ready":
            youtube.command("volume", ["volume": muted ? 0 : 100])
            syncYouTube()
        case "error":
            phase = .failed; failure = youtube.failure
        case "position", "state":
            durationSec = youtube.duration
            let state = (data["state"] as? NSNumber)?.intValue ?? -1
            switch state {
            case 1: phase = .playing; failure = nil
            case 3: phase = .buffering
            case 2, 5: phase = .paused
            default: break
            }
            if state == 0 { youtubeEnded(room, item); return }
            guard event == "position", let position = (data["positionSec"] as? NSNumber)?.doubleValue, position.isFinite else { return }
            if HallSync.youtubeNeedsSync(roomPlaying: room.timeline.playing, playerState: state, positionSec: position, expectedSec: expected(room), sinceLastSync: Date().timeIntervalSince(youtubeLastSync)) { syncYouTube() }
        default:
            break
        }
    }
    /// Report the end once per opening; a player that ran ahead of the room follows the room instead.
    private func youtubeEnded(_ room: ActivityRoom, _ item: ActivityQueueItem) {
        let key = HallSync.endKey(itemID: item.id, epoch: room.timeline.epoch)
        guard endedFor != key else { return }
        if WatchSync.ranAhead(expected: expected(room), duration: youtube?.duration) { syncYouTube(); return }
        endedFor = key
        activity.quiet(.next(fromItemID: item.id, skip: false))
    }

    // MARK: Audio session, Now Playing and lock-screen controls

    /// LiveKit owns the app's audio session. The hall holds a playout requirement, so leaving a voice room never
    /// deactivates the session under the film, and the silent switch and the background do not mute it.
    private func acquireAudio() {
        if audioRequirement == nil { audioRequirement = try? AudioManager.shared.acquireSessionRequirement(.playbackOnly) }
        preferMovieAudio()
    }
    private func releaseAudio() { try? audioRequirement?.release(); audioRequirement = nil }
    /// Without a voice room the hall asks for non-mixable movie playback (lock-screen controls, Picture in
    /// Picture). While a voice room runs, LiveKit's call session is left alone: the film then plays on the call
    /// route, possibly quieter and through voice processing, which is better than breaking the call.
    private func preferMovieAudio() {
        let session = AVAudioSession.sharedInstance()
        guard !AudioManager.shared.isEngineRunning, session.category != .playAndRecord else { return }
        if session.category == .playback, session.mode == .moviePlayback, !session.categoryOptions.contains(.mixWithOthers) { return }
        try? session.setCategory(.playback, mode: .moviePlayback, options: [])
        try? session.setActive(true)
    }
    private func updateNowPlaying(force: Bool) {
        guard force || Date().timeIntervalSince(nowPlayingAt) >= 5 else { return }
        nowPlayingAt = Date()
        guard started, let item = current else { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil; return }
        var info: [String: Any] = [MPMediaItemPropertyTitle: item.media.title, MPMediaItemPropertyArtist: "Tayfa Sinema",
                                   MPNowPlayingInfoPropertyIsLiveStream: item.media.isLive,
                                   MPNowPlayingInfoPropertyPlaybackRate: phase == .playing ? 1.0 : 0.0]
        if !item.media.isLive, let durationSec, durationSec > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = durationSec
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = displayPosition
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
    private func registerRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        remoteTargets = [center.playCommand.addTarget(handler: remoteHandler(true)), center.pauseCommand.addTarget(handler: remoteHandler(false)),
                         center.togglePlayPauseCommand.addTarget(handler: remoteHandler(nil))]
    }
    private func remoteHandler(_ play: Bool?) -> @Sendable (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        { [weak self] _ in
            guard Thread.isMainThread else { DispatchQueue.main.async { MainActor.assumeIsolated { _ = self?.remoteCommand(play) } }; return .success }
            return MainActor.assumeIsolated { self?.remoteCommand(play) ?? .commandFailed }
        }
    }
    private func unregisterRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        for target in remoteTargets { center.playCommand.removeTarget(target); center.pauseCommand.removeTarget(target); center.togglePlayPauseCommand.removeTarget(target) }
        remoteTargets = []
    }
    /// Lock screen play/pause: a live channel pauses only here; films change for everyone, for the remote holder.
    private func remoteCommand(_ play: Bool?) -> MPRemoteCommandHandlerStatus {
        guard current != nil else { return .noActionableNowPlayingItem }
        if isLive {
            if play == nil || play == localPaused { toggleLocalPause() }
            return .success
        }
        guard canDirect, let room = activity.room else { return .commandFailed }
        if play == nil || play != room.timeline.playing { togglePlayback() }
        return .success
    }

    // MARK: Video layers and Picture in Picture

    /// Each surface shows the player through its own layer; Picture in Picture uses the newest stage layer.
    func register(_ layer: AVPlayerLayer, style: Style) {
        let id = ObjectIdentifier(layer)
        layers[id] = LayerEntry(layer: layer, style: style)
        layerOrder.removeAll { $0 == id }; layerOrder.append(id)
        layer.player = backgrounded && !pictureInPictureActive ? nil : player
        refreshPictureInPicture()
    }
    func unregister(_ layer: AVPlayerLayer) {
        let id = ObjectIdentifier(layer)
        layers[id] = nil; layerOrder.removeAll { $0 == id }
        if pip?.playerLayer !== layer || !pictureInPictureActive { layer.player = nil }
        refreshPictureInPicture()
    }
    func togglePictureInPicture() {
        guard let pip else { return }
        if pip.isPictureInPictureActive { pip.stopPictureInPicture() } else if pip.isPictureInPicturePossible { pip.startPictureInPicture() }
    }
    private func refreshPictureInPicture() {
        layerOrder.removeAll { layers[$0]?.layer == nil }
        guard AVPictureInPictureController.isPictureInPictureSupported(), isRelay else {
            pip?.canStartPictureInPictureAutomaticallyFromInline = false
            pictureInPicturePossible = false
            return
        }
        let entries = layerOrder.compactMap { layers[$0] }
        let target = (entries.last { $0.style == .stage } ?? entries.last)?.layer
        if let target, pip?.playerLayer !== target, !pictureInPictureActive {
            pip?.delegate = nil
            let controller = AVPictureInPictureController(playerLayer: target)
            controller?.delegate = self
            pip = controller
            pipPossible = controller?.publisher(for: \.isPictureInPicturePossible).receive(on: DispatchQueue.main)
                .sink { [weak self] possible in MainActor.assumeIsolated { self?.pictureInPicturePossible = possible } }
        }
        // Goes to Picture in Picture by itself when the app leaves the foreground during playback.
        pip?.canStartPictureInPictureAutomaticallyFromInline = source != nil && player.timeControlStatus != .paused
    }
    /// Background audio keeps playing only without a video layer (Apple QA1668), unless the film is in
    /// Picture in Picture (or about to be: automatic Picture in Picture may start around the same moment).
    private func enteredBackground(_ background: Bool) {
        backgrounded = background
        guard !background || (!pictureInPictureActive && !pictureInPictureStarting) else { return }
        for entry in layers.values { entry.layer?.player = background ? nil : player }
    }
}

extension HallPlayerController: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        MainActor.assumeIsolated {
            pictureInPictureStarting = true
            // The window needs the picture even if the app already detached it for the background.
            for entry in layers.values { entry.layer?.player = player }
        }
    }
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        MainActor.assumeIsolated { pictureInPictureStarting = false; pictureInPictureActive = true }
    }
    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        MainActor.assumeIsolated {
            pictureInPictureActive = false
            if backgrounded { enteredBackground(true) }
            refreshPictureInPicture()
        }
    }
    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        MainActor.assumeIsolated {
            pictureInPictureStarting = false; pictureInPictureActive = false
            if backgrounded { enteredBackground(true) }
        }
    }
    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        completionHandler(true)
    }
}
