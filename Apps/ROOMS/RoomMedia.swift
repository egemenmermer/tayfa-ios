import Foundation
import Combine
import AVFoundation
import CallKit
import Network
import os
import LiveKit
import RoomsCore

struct RoomPerson: Identifiable {
    let id: String; let name: String; let local: Bool; let muted: Bool; let speaking: Bool; var deafened = false
    /// Entrance and leave sounds this person chose (server-owned LiveKit attributes).
    var sounds = ParticipantSounds()
}
struct CameraFeed: Identifiable { let id: String; let name: String; let local: Bool; let track: VideoTrack? }

struct ScreenStream: Identifiable { let id: String; let participantID: String; let name: String; let hasAudio: Bool }

@MainActor final class RoomMedia: NSObject, ObservableObject, RoomDelegate {
    @Published private(set) var camera = CameraSnapshot()
    @Published private(set) var cameras: [CameraFeed] = []
    @Published private(set) var cameraAllowed = false
    private var cameraSession: RoomCameraSession?
    private var cameraTransport: NativeRoomCamera?
    private var visibleCameraIDs: Set<String> = []
    /// Movable video-call window while the app is in the background.
    private let pictureInPicture = CallPictureInPicture()
    @Published private(set) var pictureInPictureActive = false
    /// The call stays on screen either in the app or in Picture in Picture.
    private var visible: Bool { foreground || pictureInPictureActive }
    func setVisibleCameras(_ ids: Set<String>) {
        guard visibleCameraIDs != ids else { return }; visibleCameraIDs = ids
        if let room { reconcileSubscriptions(room) }
    }
    func toggleCamera() async { await cameraSession?.toggle() }
    func switchCamera() async { await cameraSession?.switchPosition() }
    private func installCamera(_ current: Room) {
        let transport = NativeRoomCamera(room: current, isForeground: { [weak self] in self?.foreground == true })
        let session = RoomCameraSession(transport: transport)
        cameraSession = session; cameraTransport = transport
        session.onChange = { [weak self, weak session, weak current] state in
            guard let self, let current, self.room === current, self.cameraSession === session else { return }
            self.camera = state; self.refresh(current)
        }
        session.onUnsafeStop = { [weak self, weak current] in
            guard let self, let current else { return }
            self.failConnection(current, message: "Kamera güvenle kapatılamadı. Odaya tekrar katıl.")
        }
    }
    @Published private(set) var people: [RoomPerson] = []
    @Published private(set) var streams: [ScreenStream] = []
    /// This phone's own screen share through the ROOMS broadcast extension.
    @Published private(set) var sharingScreen = false
    @Published private(set) var screenShareBusy = false
    /// Grants (true) or returns (false) the room's screen-share permission; set per joined room.
    var screenLease: ((Bool) async throws -> Void)?
    private var broadcastObserver: AnyCancellable?
    @Published private(set) var video: VideoTrack?
    @Published private(set) var status = ""
    @Published private(set) var muted = true
    @Published private(set) var hearingMuted = false
    @Published private(set) var screenMuted = false
    @Published private(set) var screenVolume = 1.0
    @Published private(set) var screenRendering = false
    @Published private(set) var selection = ScreenSelection()
    @Published var error: String?
    @Published private(set) var microphoneBusy = false
    @Published private(set) var audioPreferences = AudioPreferences()
    private let preferenceStore = AudioPreferenceStore()
    private var preferenceScope: (origin: URL, userID: String)?
    private var configuredMicrophone: ObjectIdentifier?
    private(set) var room: Room?
    @Published private(set) var audioNotice: String?
    @Published private(set) var audioInterrupted = false
    @Published private(set) var audioNeedsResume = false
    @Published private(set) var outputName = "Ses çıkışı"
    @Published private(set) var speakerPreferred = true
    @Published private(set) var canChooseReceiver = false
    @Published private(set) var audioInputs: [AudioInput] = []
    @Published private(set) var currentInputID: String?
    @Published private(set) var network: MediaDiagnostics.Network = .unknown
    struct AudioInput: Identifiable { let id: String; let name: String }
    private var recovery = MediaRecovery()
    var onInterruptionRecovery: ((Bool) -> Void)?
    /// LiveKit data handlers by topic; each feature registers its own (move signal, viewers, whiteboard cursors).
    private var dataHandlers: [String: (RoomDataPacket) -> Void] = [:]
    /// Who watches which screen share: viewer identity → presenter identity, from `rooms-watch-v1`.
    @Published private(set) var watchers: [String: String] = [:]
    /// The microphone wanted for the next join this session; nil until the first join reads the saved state.
    private var desiredMicrophone: Bool?
    /// Deafen follows the person into the next voice room (move, room switch, rejoin) like `desiredMicrophone`.
    private var hearingCarry = HearingCarry()
    private var disconnectedInterruptionMicrophone: Bool?
    /// Sees phone and FaceTime calls, so a call that ended without an interruption-end notice is noticed.
    private let callObserver = CXCallObserver()
    private var diagnostics = MediaDiagnostics()
    private var routeKind: MediaDiagnostics.Route = .none
    private var observers: Set<AnyCancellable> = []
    private let pathMonitor = NWPathMonitor()
    private var cleanupTask: Task<Void, Never>?
    private var audioActionTask: Task<Void, Never>?
    private var subscriptionRetry: Task<Void, Never>?
    private var subscriptionFailures = 0
    private var audioEventEpoch = OperationEpoch()

    /// Applies the room level to everything played here and keeps it under the speaker's full scale.
    private let playout = RoomPlayoutProcessor()
    override init() {
        super.init()
        playout.onActive = { [weak self] in self?.refreshAudio() }
        GameSounds.player = { [weak self] cue in self?.playGameCue(cue) }
        handleData(topic: WatchAnnouncement.topic) { [weak self] packet in self?.receiveWatch(packet) }
        // Publication waits for the room's screen-share permission, so it is not automatic.
        BroadcastManager.shared.shouldPublishTrack = false
        broadcastObserver = BroadcastManager.shared.isBroadcastingPublisher.removeDuplicates().receive(on: DispatchQueue.main)
            .sink { [weak self] on in Task { @MainActor [weak self] in await self?.broadcastChanged(on) } }
        AudioManager.shared.renderPreProcessingDelegate = playout
        pictureInPicture.onActiveChange = { [weak self] active in self?.pictureInPictureChanged(active) }
        NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
            .sink { [weak self] notification in
                let removed = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
                Task { @MainActor [weak self] in self?.routeChanged(removed: removed) }
            }.store(in: &observers)
        NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
            .sink { [weak self] notification in
                let began = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue
                let options = (notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0
                let resume = AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume)
                Task { @MainActor [weak self] in self?.interruption(began: began, shouldResume: resume) }
            }.store(in: &observers)
        NotificationCenter.default.publisher(for: AVAudioSession.mediaServicesWereResetNotification)
            .sink { [weak self] _ in Task { @MainActor [weak self] in self?.mediaServicesReset() } }.store(in: &observers)
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let network: MediaDiagnostics.Network = path.status != .satisfied ? .offline : path.usesInterfaceType(.wifi) ? .wifi : path.usesInterfaceType(.cellular) ? .cellular : path.usesInterfaceType(.wiredEthernet) ? .wired : .other
            Task { @MainActor [weak self] in self?.network = network }
        }
        pathMonitor.start(queue: DispatchQueue(label: "rooms.network-observation"))
        updateRoute()
    }
    deinit { pathMonitor.cancel() }
    var diagnosticsReport: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "version=\(version) (\(build))\n" + diagnostics.report(phase: recovery.phase, network: network, route: routeKind, foreground: foreground, interrupted: audioInterrupted, microphoneMuted: muted, rendering: screenRendering, people: people.count, streams: streams.count)
    }
    private func updateRoute() {
        let session = AVAudioSession.sharedInstance()
        let port = session.currentRoute.outputs.first?.portType
        switch port {
        case .builtInSpeaker: routeKind = .speaker; outputName = "Hoparlör"
        case .builtInReceiver: routeKind = .receiver; outputName = "Ahize"
        case .headphones, .headsetMic: routeKind = .headphones; outputName = "Kulaklık"
        case .bluetoothHFP, .bluetoothA2DP, .bluetoothLE: routeKind = .bluetooth; outputName = "Bluetooth"
        case .airPlay: routeKind = .airplay; outputName = "AirPlay"
        case nil: routeKind = .none; outputName = "Ses çıkışı yok"
        default: routeKind = .other; outputName = "Harici ses çıkışı"
        }
        canChooseReceiver = session.category == .playAndRecord
        audioInputs = (session.availableInputs ?? []).map { AudioInput(id: $0.uid, name: $0.portName) }
        currentInputID = session.currentRoute.inputs.first?.uid
    }
    func setSpeakerPreferred(_ value: Bool) {
        guard connected, !audioInterrupted, canChooseReceiver else { return }
        speakerPreferred = value
        AudioManager.shared.audioSession.isSpeakerOutputPreferred = value
        // Routing preferences only; LiveKit retains category and activation ownership.
        do { try AVAudioSession.sharedInstance().setPreferredInput(nil); audioNotice = nil }
        catch { audioNotice = "Ses çıkışı değiştirilemedi. Sistem seçicisini kullan." }
        updateRoute()
    }
    func selectAudioInput(_ id: String) {
        let session = AVAudioSession.sharedInstance()
        guard connected, !audioInterrupted, let input = session.availableInputs?.first(where: { $0.uid == id }) else { return }
        do { try session.setPreferredInput(input); audioNotice = nil; updateRoute() }
        catch { audioNotice = "Kulaklık seçilemedi. Sistem seçicisini kullan." }
    }
    private func routeChanged(removed: Bool) {
        updateRoute(); diagnostics.record(removed ? .routeRemoved : .routeChanged)
        guard room != nil, removed else { return }
        recovery.cancelMicrophoneRestore()
        // Avoid unexpectedly sending a conversation through the loudspeaker.
        hearingMuted = true; hearingCarry.record(true); screenMuted = true; refreshAudio(); muteForAudioEvent(); stopCues(); stopGameCues(); stopPreview()
        onHearingChange?(true)
        audioNotice = "Kulaklık bağlantısı kesildi. Mikrofon ve sesler kapatıldı; çıkışı kontrol edip yeniden aç."
    }
    private func muteForAudioEvent() {
        guard let current = room else { return }
        audioEventEpoch.advance(); muted = true
        let previous = audioActionTask
        audioActionTask = Task { [weak self, weak current] in
            await previous?.value
            guard let self, let current, self.room === current else { return }
            do { _ = try await current.localParticipant.setMicrophone(enabled: false) }
            catch { if self.room === current { self.diagnostics.record(.microphoneFailed); self.failConnection(current, message: "Mikrofon güvenle kapatılamadı. Odaya tekrar katıl.") } }
            if self.room === current { self.refresh(current) }
        }
    }
    private func interruption(began: Bool, shouldResume: Bool) {
        defer { if !cuesAudible { stopCues() } }
        if began { recovery.interruptionBegan(microphoneEnabled: !muted) } else { recovery.interruptionEnded(shouldResume: shouldResume, now: ProcessInfo.processInfo.systemUptime) }
        audioInterrupted = recovery.interrupted; audioNeedsResume = recovery.needsAudioResume
        diagnostics.record(began ? .interruption : .interruptionEnded)
        guard room != nil else {
            if !began && !audioNeedsResume { recoverInterruptedConnection() }
            return
        }
        if began {
            audioNotice = "Ses başka bir uygulama tarafından kesildi. Mikrofon kapatıldı."
            muteForAudioEvent()
            if let session = cameraSession { Task { await session.stop() } }
        } else {
            audioNotice = shouldResume ? nil : "Ses kesintisi bitti. Devam etmek için sesi sürdür."
        }
        do { try AudioManager.shared.setEngineAvailability(recovery.canUseAudio ? .default : .none) }
        catch { diagnostics.record(.audioFailed); audioNeedsResume = true; audioNotice = "Ses sürdürülemedi. Tekrar dene veya odaya yeniden katıl." }
        if !began && !audioNeedsResume { restoreInterruptedMicrophone() }
    }
    func resumeAudio() {
        guard !audioInterrupted else { return }
        recovery.resumeAudio()
        if room == nil {
            audioNeedsResume = false
            recoverInterruptedConnection()
            return
        }
        guard connected else { return }
        do { try AudioManager.shared.setEngineAvailability(.default); audioNeedsResume = false; audioNotice = nil; updateRoute(); restoreInterruptedMicrophone() }
        catch { diagnostics.record(.audioFailed); audioNotice = "Ses sürdürülemedi. Odaya tekrar katıl." }
    }
    private func recoverInterruptedConnection() {
        guard !audioInterrupted, !audioNeedsResume, let microphone = disconnectedInterruptionMicrophone else { return }
        disconnectedInterruptionMicrophone = nil
        onInterruptionRecovery?(microphone)
    }
    private func restoreInterruptedMicrophone() {
        guard recovery.shouldRestoreMicrophone, let current = room, connected, !audioNeedsResume else { return }
        let ticket = recovery.ticket, audioTicket = audioEventEpoch.advance(), previous = audioActionTask
        audioActionTask = Task { @MainActor [weak self, weak current] in
            await previous?.value
            guard let self, let current, self.room === current, self.recovery.owns(ticket),
                  self.audioEventEpoch.owns(audioTicket), self.recovery.shouldRestoreMicrophone,
                  !self.audioNeedsResume else { return }
            do {
                _ = try await current.localParticipant.setMicrophone(enabled: true, captureOptions: self.captureOptions())
                guard self.room === current else { return }
                if !self.recovery.owns(ticket) || !self.audioEventEpoch.owns(audioTicket) || !self.recovery.shouldRestoreMicrophone || self.audioNeedsResume {
                    _ = try await current.localParticipant.setMicrophone(enabled: false)
                } else { self.recovery.cancelMicrophoneRestore(); self.audioNotice = nil }
                self.refresh(current)
            } catch {
                guard self.room === current else { return }
                if !self.audioEventEpoch.owns(audioTicket) || !self.recovery.canUseAudio {
                    self.failConnection(current, message: "Mikrofon güvenle kapatılamadı. Odaya tekrar katıl.")
                    return
                }
                self.recovery.cancelMicrophoneRestore()
                self.diagnostics.record(.microphoneFailed)
                self.audioNotice = "Ses geri geldi; mikrofon açılamadı. Mikrofon düğmesinden yeniden dene."
                self.refresh(current)
            }
        }
    }
    private func mediaServicesReset() {
        diagnostics.record(.servicesReset)
        if let room { failConnection(room, message: "iPhone ses sistemi yeniden başladı. Odaya tekrar katıl.") }
    }
    private func failConnection(_ current: Room, message: String) {
        guard room === current else { return }
        Task { [weak self] in
            guard let self, self.room === current else { return }
            await self.disconnect(failure: message)
        }
    }


    func useAudioPreferences(origin: URL, userID: String, soundClient: APIClient) {
        preferenceScope = (origin, userID)
        audioPreferences = preferenceStore.load(origin: origin, userID: userID)
        configuredMicrophone = nil; desiredMicrophone = nil; hearingCarry.reset()
        forgetPersonalSounds(); self.soundClient = soundClient
    }
    func clearAudioPreferences() {
        preferenceScope = nil; audioPreferences = AudioPreferences(); configuredMicrophone = nil; desiredMicrophone = nil; hearingCarry.reset(); diagnostics = MediaDiagnostics()
        forgetPersonalSounds()
    }
    private func saveAudioPreferences() {
        if let scope = preferenceScope { preferenceStore.save(audioPreferences, origin: scope.origin, userID: scope.userID) }
    }
    /// Opens iOS's broadcast picker; the share starts once the person taps "Yayını Başlat".
    func startScreenShare() {
        guard connected, !screenShareBusy, !sharingScreen else { return }
        error = nil
        BroadcastManager.shared.requestActivation()
    }
    func stopScreenShare() { BroadcastManager.shared.requestStop() }
    private func broadcastChanged(_ on: Bool) async {
        guard let current = room, connected else { if on { BroadcastManager.shared.requestStop() }; return }
        screenShareBusy = true; defer { screenShareBusy = false }
        if on {
            // The lease and the publish fail for different reasons, so each gets its own message.
            var stage = ScreenShareStage.lease
            do {
                try await screenLease?(true)
                guard room === current else { return }
                stage = .publish
                _ = try await current.localParticipant.setScreenShare(enabled: true)
            } catch {
                guard room === current else { return }
                self.error = ScreenShareFailure.message(stage: stage, error: error)
                BroadcastManager.shared.requestStop()
                try? await screenLease?(false)
            }
        } else {
            _ = try? await current.localParticipant.setScreenShare(enabled: false)
            try? await screenLease?(false)
        }
        if room === current { refresh(current) }
    }
    func setRoomEventSounds(_ enabled: Bool) {
        guard enabled != audioPreferences.roomEventSounds else { return }
        audioPreferences.roomEventSounds = enabled; saveAudioPreferences()
        if !enabled { stopCues() }
    }
    func setGameSounds(_ enabled: Bool) {
        guard enabled != audioPreferences.gameSounds else { return }
        audioPreferences.gameSounds = enabled; saveAudioPreferences()
        if !enabled { stopGameCues() }
    }
    func setPersonalSounds(_ enabled: Bool) {
        guard enabled != audioPreferences.personalSounds else { return }
        audioPreferences.personalSounds = enabled; saveAudioPreferences()
        if !enabled { stopCuePlayers(personalOnly: true) }
    }
    func setSoundEffectsLevel(_ value: Double) {
        guard value.isFinite else { return }
        audioPreferences.soundEffectsLevel = value; saveAudioPreferences()
        for entry in cuePlayers { entry.player.volume = cueVolume(personal: entry.personal) }
    }
    func entranceMuted(_ id: String) -> Bool { audioPreferences.entranceMuted(id) }
    func setEntranceMuted(_ id: String, _ muted: Bool) {
        guard entranceMuted(id) != muted else { return }
        audioPreferences.setEntranceMuted(id, muted); saveAudioPreferences()
        if muted { stopCuePlayers(personalOnly: true, actor: id) }
    }

    // MARK: Room cues and personal sounds
    /// The desktop's enter/leave cues and the personal sounds people chose, played only on this phone
    /// and never sent to the room. The tracker turns roster changes into per-person cues, the shared
    /// policy decides classic or personal, and a personal clip that is not ready in time becomes the
    /// classic cue instead of playing late. Same runtime rules as desktop `room-event-sounds.tsx`.
    private var cueTracker = RoomCueTracker()
    private var cuePolicy = PersonalCuePolicy()
    private var classicGate = ClassicCueGate()
    private var cueTimer: Task<Void, Never>?
    /// Pending personal playback belongs to the cue generation it started in.
    private var cueEpoch = OperationEpoch()
    private var cuePlayers: [(actor: String, personal: Bool, player: AVAudioPlayer)] = []
    /// Departures the policy still holds and when they happened: the readiness deadline of the leave
    /// sound counts from there, and a reconnect baseline that shows the person again settles them.
    private var departures: [String: Double] = [:]
    /// Account and room the policy's history belongs to; a change starts it over.
    private var cueRoom: [String] = []
    /// The Stoat voice channel whose members' sounds may be read; nil for DM calls.
    private var soundChannel: String?
    private var soundClient: APIClient?
    let soundCache = PersonalSoundCache()
    /// Leave sounds the cache is warming, so frequent roster refreshes only reach it on a change.
    private var prefetchPlan: [PersonalSoundPrefetch.Item] = []
    /// Cache work in the order it was asked for: a newer warm-up list or a clear is never overtaken.
    private var soundCacheWork: Task<Void, Never>?
    /// Signed-in client for the personal-sound settings screen.
    var personalSoundClient: APIClient? { soundClient }
    private static func cueNow() -> Double { ProcessInfo.processInfo.systemUptime * 1000 }
    private var cuesAudible: Bool { audioPreferences.roomEventSounds && !hearingMuted && !audioInterrupted && !audioNeedsResume }
    private func cueVolume(personal: Bool) -> Float {
        let policy = PersonalSoundPolicy.standard
        return Float((personal ? policy.personalGain : policy.classicGain) * audioPreferences.soundEffectsLevel)
    }
    private func allowsPersonalSound(_ actor: String) -> Bool {
        soundChannel != nil && soundClient != nil && audioPreferences.allowsPersonalSound(from: actor)
    }
    /// `roster` is the remote participants in join order with their chosen sounds.
    private func updateCues(channel: String?, connected: Bool, roster: [(actor: String, sounds: ParticipantSounds)]) {
        let scope = preferenceScope.map { "\($0.origin.absoluteString)|\($0.userID)" } ?? ""
        let others = Dictionary(roster, uniquingKeysWith: { first, _ in first })
        let cues = cueTracker.update(scope: scope, channel: channel, connected: connected, others: others)
        cuePlayers.removeAll { !$0.player.isPlaying }
        // A new room or account, or leaving (left, kicked, failed), starts over and silences the clips of
        // the people still in the room; the own leave cue below still plays. The listener's own
        // reconnect inside the room keeps held departures, cooldowns and the rejoin history.
        let room = [scope, channel ?? ""]
        if room != cueRoom { cueRoom = room; stopCues() }
        guard cuesAudible else { stopCues(); return }
        let now = Self.cueNow()
        // Someone whose departure is still held and who is back in a reconnect baseline returned in
        // time; the baseline itself never plays.
        if cueTracker.rebased, connected {
            for actor in others.keys where departures.removeValue(forKey: actor) != nil {
                _ = cuePolicy.push(RosterCue(kind: .enter, actor: actor), now: now, allow: allowsPersonalSound)
            }
        }
        var decisions: [CueDecision] = []
        for cue in cues {
            if !cue.local, cue.kind == .enter { departures[cue.actor] = nil }
            if !cue.local, cue.kind == .leave {
                departures[cue.actor] = now
                // The leaver's clip gets the whole hold to arrive.
                if let sound = cue.sound, allowsPersonalSound(cue.actor) { warm(sound, actor: cue.actor) }
            }
            decisions += cuePolicy.push(cue, now: now, allow: allowsPersonalSound)
        }
        play(decisions, now: now)
        if !cues.isEmpty { scheduleCueTick() }
        prefetchLeaveSounds(connected ? roster : [])
    }
    /// Cues nobody can hear are not counted (desktop `stop()`): what plays stops, pending clips and held
    /// departures are dropped and the policy starts over, so deafening, turning room sounds off or an
    /// interruption does not spend cooldowns. Also on a room or account change.
    private func stopCues() {
        stopCuePlayers()
        cuePolicy.reset(); classicGate.reset(); cueEpoch.advance(); departures = [:]
        cueTimer?.cancel(); cueTimer = nil
        warmLeaveSounds([])
    }
    private func scheduleCueTick() {
        cueTimer?.cancel(); cueTimer = nil
        guard let due = cuePolicy.nextDue() else { return }
        let delay = max(0, due - Self.cueNow())
        cueTimer = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(delay.rounded(.up))))
            guard !Task.isCancelled, let self else { return }
            guard self.cuesAudible else { self.stopCues(); return }
            let now = Self.cueNow()
            self.play(self.cuePolicy.tick(now: now, allow: self.allowsPersonalSound), now: now)
            // Released departures that coalesced into nothing are no longer held either.
            let hold = self.cuePolicy.config.leaveHoldMs
            self.departures = self.departures.filter { now - $0.value < hold }
            self.scheduleCueTick()
        }
    }
    private func play(_ decisions: [CueDecision], now: Double) {
        for decision in decisions {
            // A departure's deadline counts from when the person left, so its clip must be in by the release.
            let eventAt = decision.kind == .leave ? departures.removeValue(forKey: decision.actor) ?? now : now
            guard let sound = decision.sound else { playClassic(decision.kind); continue }
            playPersonal(decision, sound: sound, deadline: eventAt + PersonalSoundPolicy.standard.readyDeadlineMs)
        }
    }
    /// Every classic cue, approved or standing in for a personal clip, passes the shared window.
    private func playClassic(_ kind: RoomCue) {
        guard cuesAudible, audioPreferences.soundEffectsLevel > 0, classicGate.admit(now: Self.cueNow()) else { return }
        startCuePlayer(RoomCueTone.wav(kind), actor: "", personal: false)
    }
    private func playPersonal(_ decision: CueDecision, sound: String, deadline: Double) {
        guard let client = soundClient, let channel = soundChannel else { playClassic(decision.kind); return }
        let ticket = cueEpoch.advanceForRead(), actor = decision.actor, kind = decision.kind, cache = soundCache
        Task { [weak self] in
            // A clip already in memory plays at once; only a download races the deadline.
            if let clip = await cache.cached(sound) { self?.finishPersonal(clip, actor: actor, kind: kind, ticket: ticket, settled: CueSettlement()); return }
            guard let self, self.cueEpoch.owns(ticket) else { return }
            let settled = CueSettlement()
            let fallback = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(Int(max(0, deadline - Self.cueNow()).rounded(.up))))
                self?.finishPersonal(nil, actor: actor, kind: kind, ticket: ticket, settled: settled)
            }
            let clip = await cache.clip(sound) { try await client.personalSoundClip(channel: channel, user: actor, sound: sound) }
            fallback.cancel()
            self.finishPersonal(clip, actor: actor, kind: kind, ticket: ticket, settled: settled)
        }
    }
    /// Plays the clip, or the classic cue when it is missing or late; whichever comes first wins. A clip
    /// that started late can outlast the room window, so another one never plays over it.
    private func finishPersonal(_ clip: Data?, actor: String, kind: RoomCue, ticket: UInt64, settled: CueSettlement) {
        guard !settled.done, cueEpoch.owns(ticket) else { return }
        settled.done = true
        guard cuesAudible else { return }
        if let clip, allowsPersonalSound(actor), audioPreferences.soundEffectsLevel > 0,
           !cuePlayers.contains(where: { $0.personal && $0.player.isPlaying }) {
            startCuePlayer(clip, actor: actor, personal: true, fallback: kind)
        } else { playClassic(kind) }
    }
    private func startCuePlayer(_ data: Data, actor: String, personal: Bool, fallback: RoomCue? = nil) {
        guard let player = try? AVAudioPlayer(data: data) else {
            if let fallback { playClassic(fallback) }
            return
        }
        player.volume = cueVolume(personal: personal)
        if player.play() { cuePlayers.append((actor, personal, player)) }
        else if let fallback { playClassic(fallback) }
    }
    // MARK: Game table cues
    /// Synthesized table cues (`GameCueTone`, desktop recipes) for the games of this voice room, heard only here.
    /// They play like the room cues: an `AVAudioPlayer` inside the call session LiveKit owns (no category or
    /// activation change, no second audio engine), so they mix with the voices instead of interrupting them.
    /// Outside a connected room nothing plays (an app-default session would stop other apps' audio).
    private var gameCuePlayers: [AVAudioPlayer] = []
    private var gameCueGate = GameCueGate()
    private var gameCueData: [GameCue: Data] = [:]
    private var gameCuesAudible: Bool {
        connected && audioPreferences.gameSounds && audioPreferences.soundEffectsLevel > 0
            && !hearingMuted && !audioInterrupted && !audioNeedsResume
    }
    func playGameCue(_ cue: GameCue) {
        gameCuePlayers.removeAll { !$0.isPlaying }
        guard gameCuesAudible, gameCuePlayers.count < 4, gameCueGate.admit(cue, now: Self.cueNow()) else { return }
        let data = gameCueData[cue] ?? GameCueTone.wav(cue)
        gameCueData[cue] = data
        guard let player = try? AVAudioPlayer(data: data) else { return }
        player.volume = Float(GameCueTone.gain * audioPreferences.soundEffectsLevel)
        if player.play() { gameCuePlayers.append(player) }
    }
    private func stopGameCues() {
        for player in gameCuePlayers { player.stop() }
        gameCuePlayers = []; gameCueGate.reset()
    }
    /// Stops what is playing: everything, only personal clips, or one person's.
    private func stopCuePlayers(personalOnly: Bool = false, actor: String? = nil) {
        cuePlayers.removeAll { entry in
            guard !personalOnly || entry.personal, actor == nil || entry.actor == actor else { return !entry.player.isPlaying }
            entry.player.stop(); return true
        }
    }
    /// Starts the leaver's clip download now: shared with one already running, skipped while it is
    /// cached or failed within the cache's failure window.
    private func warm(_ sound: String, actor: String) {
        guard let client = soundClient, let channel = soundChannel else { return }
        let cache = soundCache
        Task { _ = await cache.clip(sound) { try await client.personalSoundClip(channel: channel, user: actor, sound: sound) } }
    }
    /// Departures play at once, so the leave sounds of a stable subset of the people present are warmed
    /// ahead, one download at a time, leaving room in the cache for the clips being played.
    private func prefetchLeaveSounds(_ roster: [(actor: String, sounds: ParticipantSounds)]) {
        guard soundClient != nil, soundChannel != nil else { warmLeaveSounds([]); return }
        warmLeaveSounds(PersonalSoundPrefetch.plan(roster, limit: soundCache.prefetchLimit, allow: allowsPersonalSound))
    }
    private func warmLeaveSounds(_ plan: [PersonalSoundPrefetch.Item]) {
        // An identical list is a no-op; a failed warm-up is tried again when the list changes.
        guard plan != prefetchPlan else { return }
        prefetchPlan = plan
        let requests: [PersonalSoundCache.Request]
        if let client = soundClient, let channel = soundChannel {
            requests = plan.map { item in
                PersonalSoundCache.Request(item.sound) { try await client.personalSoundClip(channel: channel, user: item.actor, sound: item.sound) }
            }
        } else { requests = [] }
        onSoundCache { await $0.prefetch(requests) }
    }
    private func onSoundCache(_ work: @escaping @Sendable (PersonalSoundCache) async -> Void) {
        let previous = soundCacheWork, cache = soundCache
        soundCacheWork = Task { await previous?.value; await work(cache) }
    }
    /// Account change or sign-out: no clip, request or pending cue of the previous account survives.
    private func forgetPersonalSounds() {
        stopCues(); stopPreview()
        soundClient = nil; prefetchPlan = []
        onSoundCache { await $0.clear() }
    }

    // MARK: Settings preview
    private var previewPlayer: AVAudioPlayer?
    /// LiveKit owns the audio session. Outside a voice room this holds a playback session for the preview
    /// (speaker, audible with the silent switch on, other apps keep playing); inside one the call session
    /// stays as it is. Released when the preview stops or ends.
    private var previewAudio: SessionRequirementHandle?
    private var previewEnd: PreviewEnd?
    private var previewGeneration: UInt64 = 0
    /// Settings preview of a clip (personal gain) or, with nil, the classic cue. Previews are an explicit
    /// tap, so they ignore the room-sound switches and the effects level.
    func playPreview(_ data: Data?, kind: RoomCue) -> Bool {
        stopPreview()
        guard !audioInterrupted, let audio = try? AudioManager.shared.acquireSessionRequirement(.playbackOnly) else { return false }
        guard let player = try? AVAudioPlayer(data: data ?? RoomCueTone.wav(kind)) else { try? audio.release(); return false }
        previewGeneration &+= 1
        let generation = previewGeneration
        let end = PreviewEnd { [weak self] in
            guard let self, self.previewGeneration == generation else { return }
            self.stopPreview()
        }
        let policy = PersonalSoundPolicy.standard
        player.volume = Float(data == nil ? policy.classicGain : policy.personalGain)
        player.delegate = end
        guard player.play() else { player.delegate = nil; try? audio.release(); return false }
        previewPlayer = player; previewAudio = audio; previewEnd = end
        return true
    }
    func stopPreview() {
        previewPlayer?.delegate = nil; previewPlayer?.stop(); previewPlayer = nil; previewEnd = nil
        try? previewAudio?.release(); previewAudio = nil
    }
    var previewPlaying: Bool { previewPlayer?.isPlaying == true }
    func participantAudio(_ id: String) -> ParticipantAudioPreference { audioPreferences.participant(id) }
    func setParticipantAudio(_ id: String, volume: Double? = nil, muted: Bool? = nil) {
        guard people.contains(where: { $0.id == id && !$0.local }) else { return }
        audioPreferences.setParticipant(id, volume: volume, muted: muted)
        saveAudioPreferences(); refreshAudio()
    }
    func setRoomLevel(_ value: Double) {
        audioPreferences.setRoomLevel(value); saveAudioPreferences(); refreshAudio()
    }
    func resetParticipantAudio(_ id: String) {
        audioPreferences.resetParticipant(id); saveAudioPreferences(); refreshAudio()
    }
    private func captureOptions() -> AudioCaptureOptions {
        AudioCaptureOptions(noiseSuppression: audioPreferences.noiseSuppression,
                            echoCancellationMode: .software, autoGainControlMode: .software, noiseSuppressionMode: .software)
    }
    private func processingOptions(_ enabled: Bool) -> AudioProcessingOptions {
        // Apple's AEC/NS path is coupled. Use software effects so NS can be
        // disabled independently while retaining echo cancellation and gain control.
        AudioProcessingOptions(noiseSuppression: enabled, echoCancellationMode: .software,
                               autoGainControlMode: .software, noiseSuppressionMode: .software)
    }
    private var microphoneTrack: LocalAudioTrack? {
        room?.localParticipant.trackPublications.values.first { $0.source == .microphone }?.track as? LocalAudioTrack
    }
    func setNoiseSuppression(_ enabled: Bool) {
        guard !microphoneBusy, enabled != audioPreferences.noiseSuppression else { return }
        do {
            if let track = microphoneTrack { try track.setAudioProcessingOptions(processingOptions(enabled)); configuredMicrophone = ObjectIdentifier(track) }
            audioPreferences.noiseSuppression = enabled; saveAudioPreferences(); error = nil
        } catch { self.error = "Mikrofon gürültü azaltma ayarı uygulanamadı. Tekrar dene." }
    }
    private func configureMicrophoneIfNeeded() {
        guard let track = microphoneTrack, configuredMicrophone != ObjectIdentifier(track) else { return }
        do { try track.setAudioProcessingOptions(processingOptions(audioPreferences.noiseSuppression)); configuredMicrophone = ObjectIdentifier(track) }
        catch { self.error = "Mikrofon gürültü azaltma ayarı uygulanamadı. Tekrar dene." }
    }
    private var foreground = true
    private var reconcileTask: Task<Void, Never>?
    private var screenTimeout: Task<Void, Never>?
    private var reconnectTimeout: Task<Void, Never>?
    private var connectTimeout: Task<Void, Never>?
    private var subscriptionEpoch = OperationEpoch()
    var connected: Bool { room?.connectionState == .connected }
    var selectedStream: ScreenStream? { streams.first { $0.id == selection.id } }
    /// iOS auto-lock (sooner in Low Power Mode) would stop the camera and the watched stream.
    var keepsScreenAwake: Bool { connected && (camera.isOn || selection.id != nil) }

    /// `soundChannel` is the Stoat voice channel behind the grant, for reading members' personal sounds;
    /// DM calls pass nil and keep the classic cues.
    func connect(grant: MediaGrant, soundChannel: String? = nil) async throws {
        let ticket = await disconnect()
        try Task.checkCancellation()
        guard recovery.owns(ticket) else { throw CancellationError() }
        _ = try EndpointPolicy.media(grant.serverUrl)
        self.soundChannel = try soundChannel.map(EndpointPolicy.id)
        // Before the room exists, so the join cue and the first remote tracks already respect it.
        hearingMuted = hearingCarry.resolve(voiceRoom: soundChannel != nil)
        let room = Room(delegate: self, roomOptions: RoomOptions(
            defaultScreenShareCaptureOptions: ScreenShareCaptureOptions(dimensions: .h1080_169, fps: 15, useBroadcastExtension: true),
            defaultAudioCaptureOptions: captureOptions(), adaptiveStream: true, dynacast: true))
        self.room = room; installCamera(room); status = "Odaya bağlanılıyor…"; error = nil
        recovery.beginJoin(now: ProcessInfo.processInfo.systemUptime); diagnostics.record(.joining)
        AudioManager.shared.audioSession.isSpeakerOutputPreferred = speakerPreferred
        connectTimeout = Task { [weak self, weak room] in
            try? await Task.sleep(for: .seconds(25))
            guard !Task.isCancelled, let self, let room, self.room === room,
                  self.recovery.expired(ticket: ticket, now: ProcessInfo.processInfo.systemUptime) else { return }
            self.diagnostics.record(.timeout)
            await self.disconnect(failure: RoomsError.timeout.localizedDescription)
        }
        do {
            try AudioManager.shared.setEngineAvailability(recovery.canUseAudio ? .default : .none)
            try await room.connect(url: grant.serverUrl, token: grant.token, connectOptions: ConnectOptions(autoSubscribe: false, reconnectAttempts: 5, reconnectAttemptDelay: 1, reconnectMaxDelay: 7, socketConnectTimeoutInterval: 15, primaryTransportConnectTimeout: 20))
            guard self.room === room, recovery.owns(ticket), !Task.isCancelled else { await room.disconnect(); throw CancellationError() }
            connectTimeout?.cancel(); recovery.connected(); status = "Bağlandı"; updateRoute(); refresh(room)
            // The room is told only now that it is up; the person never has to deafen again after a move.
            if hearingMuted { refreshAudio(); stopCues(); onHearingChange?(true) }
        } catch {
            if self.room === room { await disconnect(failure: "Bağlantı kurulamadı. Odaya tekrar katıl.") }
            throw error
        }
    }
    @discardableResult func disconnect(failure: String? = nil) async -> UInt64 {
        // Before the reset below, so a deafened listener stays silent.
        updateCues(channel: nil, connected: false, roster: [])
        soundChannel = nil
        if sharingScreen || BroadcastManager.shared.isBroadcasting {
            BroadcastManager.shared.requestStop()
            let lease = screenLease; Task { try? await lease?(false) }
        }
        sharingScreen = false; screenLease = nil
        // A phone call suspends the app; the room it drops during or right after the call comes back once.
        let rejoin = failure != nil && recovery.rejoinsLostConnection(now: ProcessInfo.processInfo.systemUptime)
        if rejoin {
            disconnectedInterruptionMicrophone = recovery.interruptedMicrophoneIntent
        } else { disconnectedInterruptionMicrophone = nil }
        recovery.cancelRejoin()
        pictureInPicture.teardown(); let previousCamera = cameraSession; previousCamera?.invalidate(); cameraSession = nil; cameraTransport = nil; camera = CameraSnapshot(); cameras = []; cameraAllowed = false; visibleCameraIDs = []
        let previous = room; room = nil; configuredMicrophone = nil
        let ticket = recovery.reset()
        if failure != nil { recovery.requireRetry() }
        subscriptionEpoch.advance(); reconcileTask?.cancel(); screenTimeout?.cancel(); reconnectTimeout?.cancel(); connectTimeout?.cancel(); subscriptionRetry?.cancel()
        reconnectTimeout = nil; connectTimeout = nil; subscriptionRetry = nil; subscriptionFailures = 0
        desiredSubscriptions = [:]; microphoneBusy = false
        rendererOwner = nil; screenRendering = false; video = nil; people = []; streams = []; watchers = [:]; selection.select(nil); muted = true; hearingMuted = false; screenMuted = false
        status = failure == nil ? "" : "Bağlantı kesildi"; error = failure; audioNotice = nil
        audioInterrupted = recovery.interrupted; audioNeedsResume = recovery.needsAudioResume
        diagnostics.record(.disconnected)
        let oldCleanup = cleanupTask; let oldAudio = audioActionTask; audioActionTask = nil
        let cleanup = Task {
            let cameraStop = Task { await previousCamera?.shutdown() }
            await oldCleanup?.value
            // Disconnect also interrupts a pending SDK publish; waiting for it first can deadlock teardown.
            if let previous { await previous.disconnect() }
            await cameraStop.value; await oldAudio?.value
        }
        cleanupTask = cleanup
        await cleanup.value
        if recovery.owns(ticket) { cleanupTask = nil }
        if rejoin, recovery.owns(ticket) {
            error = nil
            status = audioInterrupted ? "Arama bitince odaya yeniden bağlanılacak." : "Odaya yeniden bağlanılıyor…"
            recoverInterruptedConnection()
        }
        return ticket
    }
    private(set) var microphoneIntentRevision: UInt64 = 0
    /// Whether the next voice-room join opens the microphone: as it was left (desktop RC24). Switching rooms
    /// keeps the current state; the first join of a session uses the saved choice, which starts muted.
    func microphoneForJoin() -> Bool {
        if connected, !microphoneBusy { desiredMicrophone = !muted }
        // A deafened listener does not talk (see `toggleMicrophone`), so the join must not try to open the microphone.
        if hearingCarry.deafened { return false }
        return desiredMicrophone ?? audioPreferences.microphoneOn
    }
    var joinsWithMicrophone: Bool { hearingCarry.deafened ? false : connected ? !muted : desiredMicrophone ?? audioPreferences.microphoneOn }
    /// The mute direction needs only a room (also while LiveKit reconnects); turning the microphone on needs a connection.
    var canToggleMicrophone: Bool {
        VoiceControlPolicy.canToggleMicrophone(muted: muted, hasRoom: room != nil, connected: connected, busy: microphoneBusy, audioBlocked: audioInterrupted || audioNeedsResume)
    }
    /// `remember: false` for automatic changes (deafen, restoring a join) that must not become the saved choice.
    func toggleMicrophone(remember: Bool = true) async {
        microphoneIntentRevision &+= 1
        recovery.cancelMicrophoneRestore()
        audioEventEpoch.advance()
        guard let room, !microphoneBusy, !audioInterrupted, !audioNeedsResume else { return }
        // Muting is local and allowed while reconnecting; enabling needs the connection.
        guard connected || !muted else { return }
        microphoneBusy = true; let ticket = recovery.ticket
        defer { if recovery.owns(ticket) { microphoneBusy = false } }
        await audioActionTask?.value
        guard self.room === room, recovery.owns(ticket), recovery.canUseAudio else { return }
        let audioTicket = audioEventEpoch.advanceForRead()
        let enable = muted
        // `muted` may have flipped while waiting for a pending audio action; enabling still needs the connection.
        if enable && !connected { return }
        // As on desktop: a deafened listener does not talk; hearing comes back first.
        if enable && hearingMuted { error = "Mikrofonu açmak için önce oda sesini aç."; return }
        if enable {
            let allowed = await AVAudioApplication.requestRecordPermission()
            guard self.room === room, recovery.canUseAudio, audioEventEpoch.owns(audioTicket) else { return }
            if !allowed { error = "Mikrofon izni yok. Dinlemeye devam edebilirsin; Ayarlar’dan mikrofon erişimini aç."; return }
        }
        do {
            _ = try await room.localParticipant.setMicrophone(enabled: enable, captureOptions: captureOptions())
            if self.room === room {
                if enable && (!recovery.canUseAudio || !audioEventEpoch.owns(audioTicket)) { _ = try await room.localParticipant.setMicrophone(enabled: false) }
                error = nil; configuredMicrophone = nil; updateRoute(); refresh(room)
                // `refresh` waits for a live connection; a mute done while reconnecting is reflected right away.
                if !enable, !connected { muted = true }
                desiredMicrophone = !muted
                if remember, audioPreferences.microphoneOn == muted { audioPreferences.microphoneOn = !muted; saveAudioPreferences() }
            }
        }
        catch {
            if self.room === room {
                self.diagnostics.record(.microphoneFailed)
                if enable && (!recovery.canUseAudio || !audioEventEpoch.owns(audioTicket)) {
                    failConnection(room, message: "Mikrofon güvenle kapatılamadı. Odaya tekrar katıl.")
                } else if !enable {
                    // A microphone that may still be live while the person asked for silence is not left running.
                    if connected { self.error = "Mikrofon kapatılamadı. Tekrar dene."; refresh(room) }
                    else { failConnection(room, message: "Mikrofon güvenle kapatılamadı. Odaya tekrar katıl.") }
                } else { self.error = "Mikrofon açılamadı. Dinlemeye devam edebilirsin."; refresh(room) }
            }
        }
    }
    /// Called with the new deafen state so the room can be told; the toggle never waits for it.
    var onHearingChange: ((Bool) -> Void)?
    func toggleHearing() {
        hearingMuted.toggle(); hearingCarry.record(hearingMuted); refreshAudio(); onHearingChange?(hearingMuted)
        if hearingMuted { stopCues() }
        // Deafening also mutes the microphone (desktop and Discord do the same); undeafening keeps it muted.
        if hearingMuted && !muted { Task { await toggleMicrophone(remember: false) } }
        if !hearingMuted, error == "Mikrofonu açmak için önce oda sesini aç." { error = nil }
        if let room { refresh(room) }
    }
    func setScreenAudio(volume: Double? = nil, muted: Bool? = nil) {
        if let volume { screenVolume = min(1, max(0, volume)) }; if let muted { screenMuted = muted }; refreshAudio()
    }
    private var rendererOwner: UUID?
    func claimRenderer(_ owner: UUID) { rendererOwner = owner; screenRendering = false; if foreground, let id = selection.id { startScreenTimeout(id) } }
    func releaseRenderer(_ owner: UUID) { if rendererOwner == owner { rendererOwner = nil; screenRendering = false } }
    func watch(_ id: String?) {
        if id != nil, id == selection.id { return }
        guard id == nil || streams.contains(where: { $0.id == id }) else { error = "Ekran paylaşımı sona erdi."; return }
        screenTimeout?.cancel(); screenRendering = false; video = nil; selection.select(id); error = nil
        if let room { refresh(room) }
        if let id { startScreenTimeout(id) }
    }
    func markRendering(_ value: Bool, id: String?, owner: UUID? = nil) {
        if let owner, rendererOwner != owner { return }
        guard id != nil, selection.id == id else { return }
        screenRendering = value
        if value { screenTimeout?.cancel() }
    }
    private func startScreenTimeout(_ id: String) {
        screenTimeout?.cancel()
        screenTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(25))
            guard !Task.isCancelled, let self, self.foreground, self.selection.id == id, !self.screenRendering else { return }
            self.selection.fail(); self.video = nil; self.error = "Yayın açılamadı. Tekrar dene."; if let room = self.room { self.refresh(room) }
        }
    }
    func setForeground(_ value: Bool) {
        guard foreground != value else { return }
        foreground = value
        // Picture in Picture keeps the camera only when iOS grants multitasking camera access.
        let keepCamera = !value && pictureInPictureActive && cameraTransport?.runsInBackground == true
        if let session = cameraSession { Task { await session.setForeground(value, keepRunning: keepCamera) } }
        diagnostics.record(value ? .foreground : .background)
        // iOS does not always report the end of an interruption; back in the app with no call, it is over.
        if value, recovery.interrupted, !callObserver.calls.contains(where: { !$0.hasEnded }) {
            interruption(began: false, shouldResume: true)
        }
        if value, let room, recovery.expired(ticket: recovery.ticket, now: ProcessInfo.processInfo.systemUptime) {
            diagnostics.record(.timeout); failConnection(room, message: "Bağlantı süresi doldu. Odaya tekrar katıl."); return
        }
        if value { updateRoute(); restoreInterruptedMicrophone() }
        if !value, !pictureInPictureActive { screenTimeout?.cancel(); screenRendering = false; video = nil }
        if let room { refresh(room) }
        if value, let id = selection.id, !screenRendering { startScreenTimeout(id) }
    }
    private func refreshAudio() {
        // Once playout runs through the limiter it carries the room gain; until then the tracks do.
        let leveled = playout.loudness.isActive()
        playout.loudness.setGain(leveled ? audioPreferences.roomGain : 1)
        for p in room?.remoteParticipants.values ?? Dictionary<Participant.Identity, RemoteParticipant>().values {
            for pub in p.trackPublications.values {
                guard let audio = pub.track as? RemoteAudioTrack else { continue }
                if pub.source == .microphone { audio.volume = audioPreferences.playbackVolume(for: p.identity?.stringValue ?? "", roomMuted: hearingMuted, boostRoom: !leveled) }
                else if pub.source == .screenShareAudio { audio.volume = screenMuted || !visible ? 0 : screenVolume }
            }
        }
    }
    private func refresh(_ current: Room) {
        guard room === current, current.connectionState == .connected else { return }
        let participants: [Participant] = [current.localParticipant] + current.remoteParticipants.values.sorted { ($0.identity?.stringValue ?? "") < ($1.identity?.stringValue ?? "") }
        let permissions = current.localParticipant.permissions
        cameraAllowed = permissions.canPublish && (permissions.canPublishSources.isEmpty || permissions.canPublishSources.contains(Track.Source.camera.rawValue))
        cameras = visible ? participants.compactMap { participant in
            guard let id = participant.identity?.stringValue,
                  let publication = participant.trackPublications.values.first(where: { $0.source == .camera && !$0.isMuted }),
                  participant !== current.localParticipant || camera.isOn else { return nil }
            return CameraFeed(id: id, name: participant.name ?? id, local: participant === current.localParticipant, track: publication.track as? VideoTrack)
        } : []
        people = participants.compactMap { p in
            guard let id = p.identity?.stringValue else { return nil }
            let local = p === current.localParticipant
            return RoomPerson(id: id, name: p.name ?? id, local: local, muted: !p.isMicrophoneEnabled(), speaking: p.isSpeaking,
                              deafened: local ? hearingMuted : p.attributes["rooms.deafened"] == "1",
                              sounds: ParticipantSounds(attributes: p.attributes))
        }
        muted = audioInterrupted || audioNeedsResume || !current.localParticipant.isMicrophoneEnabled()
        sharingScreen = current.localParticipant.isScreenShareEnabled()
        streams = current.remoteParticipants.values.flatMap { p in
            p.trackPublications.values.filter { $0.source == .screenShareVideo && !$0.isMuted }.map { pub in
                ScreenStream(id: pub.sid.stringValue, participantID: p.identity?.stringValue ?? "", name: p.name ?? "Katılımcı", hasAudio: p.trackPublications.values.contains { $0.source == .screenShareAudio && !$0.isMuted })
            }
        }.sorted { $0.name < $1.name }
        selection.reconcile(available: Set(streams.map(\.id)), subscribed: Set(current.remoteParticipants.values.flatMap { $0.trackPublications.values.filter { $0.track != nil }.map { $0.sid.stringValue } }))
        if let id = selection.id, visible {
            video = current.remoteParticipants.values.flatMap { $0.trackPublications.values }.first { $0.sid.stringValue == id }?.track as? VideoTrack
        } else { video = nil }
        if selection.id == nil || screenRendering { screenTimeout?.cancel() }
        configureMicrophoneIfNeeded(); refreshAudio(); reconcileSubscriptions(current); updatePictureInPicture()
        let present = Set(current.remoteParticipants.values.compactMap { $0.identity?.stringValue })
        if watchers.keys.contains(where: { !present.contains($0) }) { watchers = watchers.filter { present.contains($0.key) } }
        announceWatchIfChanged(current)
        // Join order (server time), so the leave sounds kept warm stay the same while the room does.
        let roster = current.remoteParticipants.values
            .compactMap { p in p.identity.map { (id: $0.stringValue, joined: p.joinedAt ?? .distantFuture, sounds: ParticipantSounds(attributes: p.attributes)) } }
            .sorted { ($0.joined, $0.id) < ($1.joined, $1.id) }
        updateCues(channel: current.name ?? "room", connected: true, roster: roster.map { (actor: $0.id, sounds: $0.sounds) })
    }
    /// Last screen choice told to the room; `.none` until the first announcement on this connection.
    private var announcedWatch: String?? = .none
    private var watchedPresenter: String? { visible ? selectedStream?.participantID : nil }
    private func announceWatchIfChanged(_ current: Room) {
        let watching = watchedPresenter
        if case .some(let last) = announcedWatch, last == watching { return }
        announcedWatch = .some(watching)
        publishWatch(current, watching: watching, to: [])
    }
    private func publishWatch(_ current: Room, watching: String?, to destinations: [Participant.Identity]) {
        // DM call rooms grant no data channel; there is nobody to tell.
        guard current.localParticipant.permissions.canPublishData else { return }
        let options = DataPublishOptions(destinationIdentities: destinations, topic: WatchAnnouncement.topic, reliable: true)
        Task { try? await current.localParticipant.publish(data: WatchAnnouncement.payload(watching: watching), options: options) }
    }
    /// Registers (or with nil removes) the handler for one data topic of the joined room.
    func handleData(topic: String, _ handler: ((RoomDataPacket) -> Void)?) { dataHandlers[topic] = handler }
    /// The viewer is the authenticated sender, never a name inside the payload (desktop `parseWatch`).
    private func receiveWatch(_ packet: RoomDataPacket) {
        guard !packet.fromServer, let viewer = packet.sender, case .some(let watching) = WatchAnnouncement.parse(packet.payload),
              room?.remoteParticipants.values.contains(where: { $0.identity?.stringValue == viewer }) == true else { return }
        if watchers[viewer] != watching { watchers[viewer] = watching }
    }
    /// People watching `presenterID`'s screen, this listener included while it shows that stream.
    func viewers(of presenterID: String) -> [RoomPerson] {
        people.filter { $0.local ? watchedPresenter == presenterID : watchers[$0.id] == presenterID }
    }
    func viewerSummary(of presenterID: String, named: Bool = false) -> String {
        ScreenViewers.summary(viewers(of: presenterID).map { $0.local ? "Sen" : $0.name }, named: named)
    }
    /// Sends a data packet to the joined room, or only to `destinations` (participant identities).
    func publishData(_ payload: Data, topic: String, reliable: Bool, to destinations: [String] = []) async throws {
        guard let current = room, connected else { return }
        let options = DataPublishOptions(destinationIdentities: destinations.map { Participant.Identity(from: $0) }, topic: topic, reliable: reliable)
        try await current.localParticipant.publish(data: payload, options: options)
    }
    /// Shows the watched stream, else a visible remote camera, else the user's own camera.
    private func updatePictureInPicture() {
        guard connected else { pictureInPicture.update(track: nil, mirrored: false, landscape: false); return }
        if let video { pictureInPicture.update(track: video, mirrored: false, landscape: true); return }
        if let remote = cameras.first(where: { !$0.local && $0.track != nil }) {
            pictureInPicture.update(track: remote.track, mirrored: false, landscape: false); return
        }
        if let own = cameras.first(where: { $0.local }), let track = own.track {
            pictureInPicture.update(track: track, mirrored: false, landscape: false); return
        }
        pictureInPicture.update(track: nil, mirrored: false, landscape: false)
    }
    private func pictureInPictureChanged(_ active: Bool) {
        pictureInPictureActive = active
        if !active, !foreground {
            // Closing the window while in the background ends background video like a normal background.
            if let session = cameraSession { Task { await session.setForeground(false) } }
            screenTimeout?.cancel(); screenRendering = false; video = nil
        }
        if let room { refresh(room) }
    }
    private var desiredSubscriptions: [String: Bool] = [:]
    private func reconcileSubscriptions(_ current: Room) {
        let publications = current.remoteParticipants.values.flatMap { p -> [(RemoteTrackPublication, Bool)] in
            let screenID = p.trackPublications.values.first { $0.source == .screenShareVideo }?.sid.stringValue
            return p.trackPublications.values.compactMap { pub in
                guard let remote = pub as? RemoteTrackPublication else { return nil }
                let source = pub.source == .microphone ? "microphone" : pub.source == .screenShareVideo ? "screen_share" : pub.source == .screenShareAudio ? "screen_share_audio" : "camera"
                return (remote, pub.source == .camera ? CameraSubscriptionPolicy.wants(participantID: p.identity?.stringValue ?? "", visible: visibleCameraIDs, foreground: visible) : selection.wants(source: source, publicationID: pub.sid.stringValue, presenterScreenID: screenID, foreground: visible))
            }
        }
        let desired = Dictionary(publications.map { ($0.0.sid.stringValue, $0.1) }, uniquingKeysWith: { _, last in last })
        guard desired != desiredSubscriptions else { return }; desiredSubscriptions = desired
        let previous = reconcileTask; let ticket = subscriptionEpoch.advance()
        reconcileTask = Task { [weak self, weak current] in
            await previous?.value
            guard let self, let current, self.room === current, self.subscriptionEpoch.owns(ticket) else { return }
            var failed = false
            // Unsubscribe old screens before requesting new ones.
            for (pub, wanted) in publications.sorted(by: { !$0.1 && $1.1 }) {
                guard self.room === current, self.subscriptionEpoch.owns(ticket) else { return }
                do { try await pub.set(subscribed: wanted) }
                catch {
                    guard self.room === current, self.subscriptionEpoch.owns(ticket) else { return }
                    failed = true; self.diagnostics.record(.subscriptionFailed)
                    // A failed screen must not prevent microphone subscriptions.
                }
            }
            guard self.room === current, self.subscriptionEpoch.owns(ticket) else { return }
            if failed {
                self.subscriptionFailures += 1
                if self.subscriptionFailures <= 2 {
                    self.desiredSubscriptions = [:]
                    self.subscriptionRetry?.cancel()
                    self.subscriptionRetry = Task { [weak self, weak current] in
                        try? await Task.sleep(for: .seconds(2))
                        guard !Task.isCancelled, let self, let current, self.room === current, self.subscriptionEpoch.owns(ticket) else { return }
                        self.reconcileSubscriptions(current)
                    }
                } else { self.error = "Ses veya yayın aboneliği kurulamadı. Odaya tekrar katıl." }
            } else { self.subscriptionFailures = 0; self.subscriptionRetry?.cancel(); self.subscriptionRetry = nil }
        }
    }
    private nonisolated func scheduleRefresh(_ room: Room) { Task { @MainActor [weak self] in self?.refresh(room) } }
    nonisolated func room(_ room: Room, participantDidConnect participant: RemoteParticipant) {
        Task { @MainActor [weak self] in
            guard let self, self.room === room else { return }
            // A newcomer learns which stream this phone watches; desktop lists it as a viewer.
            if let watching = self.watchedPresenter, let identity = participant.identity { self.publishWatch(room, watching: watching, to: [identity]) }
            self.refresh(room)
        }
    }
    nonisolated func room(_ room: Room, participant: Participant, didUpdateAttributes attributes: [String: String]) { scheduleRefresh(room) }
    nonisolated func room(_ room: Room, participant: RemoteParticipant?, didReceiveData data: Data, forTopic topic: String, encryptionType: EncryptionType) {
        // A packet without a participant comes from the server (e.g. `rooms-move-v1`), never from a peer.
        let packet = RoomDataPacket(topic: topic, payload: data, sender: participant?.identity?.stringValue, fromServer: participant == nil)
        Task { @MainActor [weak self] in
            guard let self, self.room === room else { return }
            self.dataHandlers[topic]?(packet)
        }
    }
    nonisolated func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) { scheduleRefresh(room) }
    nonisolated func room(_ room: Room, didUpdateSpeakingParticipants participants: [Participant]) { scheduleRefresh(room) }
    nonisolated func room(_ room: Room, participant: RemoteParticipant, didPublishTrack publication: RemoteTrackPublication) { scheduleRefresh(room) }
    nonisolated func room(_ room: Room, participant: RemoteParticipant, didUnpublishTrack publication: RemoteTrackPublication) { scheduleRefresh(room) }
    nonisolated func room(_ room: Room, participant: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) { scheduleRefresh(room) }
    nonisolated func room(_ room: Room, participant: RemoteParticipant, didUnsubscribeTrack publication: RemoteTrackPublication) { scheduleRefresh(room) }
    nonisolated func room(_ room: Room, participant: Participant, trackPublication: TrackPublication, didUpdateIsMuted isMuted: Bool) { scheduleRefresh(room) }
    nonisolated func room(_ room: Room, didUpdateConnectionState state: ConnectionState, from old: ConnectionState) {
        Task { @MainActor [weak self] in
            guard let self, self.room === room else { return }
            switch state {
            case .connected: self.recovery.connected(); self.restoreInterruptedMicrophone(); self.diagnostics.record(.connected); self.updateRoute(); self.reconnectTimeout?.cancel(); self.reconnectTimeout = nil; self.desiredSubscriptions = [:]; self.configuredMicrophone = nil; self.announcedWatch = .none; self.status = "Bağlandı"; self.refresh(room)
            case .connecting: self.status = "Odaya bağlanılıyor…"
            case .reconnecting: self.beginReconnect(room)
            case .disconnecting: self.status = "Odadan ayrılınıyor…"
            case .disconnected: self.failConnection(room, message: "Bağlantı kesildi. Odaya tekrar katıl.")
            @unknown default: self.status = "Bağlantı kesildi"
            }
        }
    }
    nonisolated func room(_ room: Room, participant: Participant, didUpdatePermissions permissions: ParticipantPermissions) {
        Task { @MainActor [weak self] in
            guard let self, self.room === room else { return }
            self.refresh(room)
            if participant === room.localParticipant, !self.cameraAllowed, let session = self.cameraSession { await session.revoke() }
        }
    }
    private func beginReconnect(_ room: Room) {
        updateCues(channel: room.name ?? "room", connected: false, roster: [])
        if let session = cameraSession { Task { await session.stop() } }
        recovery.reconnect(now: ProcessInfo.processInfo.systemUptime)
        status = "Bağlantı kesildi. Yeniden deneniyor."
        guard reconnectTimeout == nil else { return }
        diagnostics.record(.reconnecting)
        let ticket = recovery.ticket
        reconnectTimeout = Task { [weak self, weak room] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled, let self, let room, self.room === room,
                  self.recovery.expired(ticket: ticket, now: ProcessInfo.processInfo.systemUptime) else { return }
            self.diagnostics.record(.timeout)
            await self.disconnect(failure: "Bağlantı kesildi. Odaya tekrar katıl.")
        }
    }
    nonisolated func room(_ room: Room, didStartReconnectWithMode mode: ReconnectMode) { Task { @MainActor [weak self] in guard let self, self.room === room else { return }; self.beginReconnect(room) } }
    nonisolated func room(_ room: Room, didCompleteReconnectWithMode mode: ReconnectMode) { Task { @MainActor [weak self] in guard let self, self.room === room else { return }; self.recovery.connected(); self.restoreInterruptedMicrophone(); self.updateRoute(); self.reconnectTimeout?.cancel(); self.reconnectTimeout = nil; self.desiredSubscriptions = [:]; self.configuredMicrophone = nil; self.announcedWatch = .none; self.status = "Bağlandı"; self.refresh(room) } }
}

/// Whether a personal cue already played or fell back; the clip and the deadline race on the main actor.
@MainActor private final class CueSettlement { var done = false }

/// Reports the natural end of a settings preview, so its playback session is given back at once.
private final class PreviewEnd: NSObject, AVAudioPlayerDelegate {
    private let ended: @MainActor @Sendable () -> Void
    init(_ ended: @escaping @MainActor @Sendable () -> Void) { self.ended = ended }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { report() }
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) { report() }
    private func report() { let ended = ended; Task { @MainActor in ended() } }
}

/// One LiveKit data packet of the joined room.
struct RoomDataPacket: Sendable {
    let topic: String
    let payload: Data
    /// The sending participant's identity; nil for server packets.
    let sender: String?
    let fromServer: Bool
}

/// Room playout hook: one buffer of everything heard (all tracks mixed) on LiveKit's audio thread.
final class RoomPlayoutProcessor: NSObject, AudioCustomProcessingDelegate, @unchecked Sendable {
    let loudness = PlayoutLoudness()
    /// Called on the main actor when playout starts passing through the limiter.
    @MainActor var onActive: (() -> Void)?
    private let reported = OSAllocatedUnfairLock(initialState: false)
    func audioProcessingInitialize(sampleRate sampleRateHz: Int, channels: Int) {
        loudness.resetLimiter(); reported.withLock { $0 = false }
    }
    func audioProcessingProcess(audioBuffer: LKAudioBuffer) {
        loudness.process(channels: audioBuffer.channels, frames: audioBuffer.frames) { audioBuffer.rawBuffer(forChannel: $0) }
        if reported.withLock({ value in defer { value = true }; return !value }) {
            DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.onActive?() } }
        }
    }
    func audioProcessingRelease() { reported.withLock { $0 = false } }
}
