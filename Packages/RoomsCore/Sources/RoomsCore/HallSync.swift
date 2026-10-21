import Foundation

/// The hall player's timing rules, ported from desktop `apps/desktop/src/cinema/HallPlayer.tsx`.
/// The room timeline is the authority for films and series; live channels align on the relay's own
/// live edge, which every viewer reads from the same playlist, so the hall sees the same moment.
public enum HallSync {
    /// The sync loop runs once a second.
    public static let tickSeconds: Double = 1
    /// hls.js `liveSyncPosition` with `liveSyncDurationCount: 3` on the relay's 2-second segments.
    public static let liveEdgeOffset: Double = 6
    /// Renew a relay ticket when this little remains by the local clock (desktop `ticketFor`).
    public static let renewBeforeMs: Double = 30_000
    /// Watching again after the relay session ended (404/410): at most this often in a row.
    public static let maxReconnects = 5

    /// The playback rate that closes a live drift gently, or nil to jump.
    public static func liveRate(_ drift: Double) -> Double? {
        if abs(drift) > 3 { return nil }
        if drift > 0.5 { return 1.05 }
        if drift < -0.5 { return 0.95 }
        return 1
    }

    /// One live tick: where to jump (if anywhere), the rate to play at and whether the viewer fell behind.
    public struct LiveStep: Equatable, Sendable {
        public let seekTo: Double?
        public let rate: Double
        public let behindLive: Bool
    }
    /// `window` is the player's seekable range, its end the relay's live edge; the shared target is `liveEdge(window)`.
    /// Not the wall clock: the relay stamps PROGRAM-DATE-TIME from its own start and a provider's connect burst runs
    /// it ahead of real time, so a clock target left the 16 s window and seeked in a loop.
    /// Jumps only go forward and are at least 3 s apart: after one the caller stores `nowMs + 3000` as the next `seekAllowedAtMs`.
    public static func live(currentTime: Double, window: ClosedRange<Double>?, nowMs: Double, seekAllowedAtMs: Double) -> LiveStep {
        guard let window else { return LiveStep(seekTo: nil, rate: 1, behindLive: false) }
        let target = liveEdge(window), drift = target - currentTime, behind = drift > 6
        if let rate = liveRate(drift) { return LiveStep(seekTo: nil, rate: rate, behindLive: behind) }
        // Ahead of the hall only slows down: a stalled upstream stops the window's end while this viewer
        // plays on to it, and jumping back would replay the same seconds over and over.
        if drift < 0 { return LiveStep(seekTo: nil, rate: 0.95, behindLive: false) }
        return LiveStep(seekTo: nowMs > seekAllowedAtMs ? target : nil, rate: 1, behindLive: behind)
    }
    /// hls.js `liveSyncPosition` on AVPlayer: three segments behind the end of the playlist, inside the window.
    public static func liveEdge(_ window: ClosedRange<Double>) -> Double { max(window.lowerBound, window.upperBound - liveEdgeOffset) }

    /// Where playback is in the work. PROGRAM-DATE-TIME pins the relay's output time 0, so this holds
    /// wherever the player started its own timeline (late joiners, remounts).
    public static func workPosition(offsetSec: Double, originPdtMs: Double?, playingDateMs: Double?, currentTime: Double) -> Double {
        if let originPdtMs, let playingDateMs { return offsetSec + (playingDateMs - originPdtMs) / 1000 }
        return offsetSec + currentTime
    }
    /// When the player exposes no playing date, the loader's latest playlist still pins its first listed
    /// segment's PROGRAM-DATE-TIME to the start of the seekable window.
    public static func estimatedDateMs(firstPdtMs: Double?, windowStart: Double?, currentTime: Double) -> Double? {
        guard let firstPdtMs, let windowStart else { return nil }
        return firstPdtMs + (currentTime - windowStart) * 1000
    }

    /// Film and series pacing state kept between ticks.
    public struct VODTimers: Equatable, Sendable {
        public var seekAllowedAtMs: Double = 0
        public var rewatchAllowedAtMs: Double = 0
        public var rewatchDelayMs: Double = 4000
        public init() {}
    }
    public enum VODAction: Equatable, Sendable { case none, seek(Double), rewatch }
    /// One film tick: `target` is the room position (`WatchSync.expectedPosition`), `work` the player's.
    public static func vod(target: Double, work: Double, currentTime: Double, window: ClosedRange<Double>?, nowMs: Double, timers: inout VODTimers) -> VODAction {
        let want = currentTime + (target - work)
        if let window, want < window.lowerBound - 1 || want > window.upperBound + 30 {
            // Outside what this relay holds: ask the server for the room position, backing off so a relay
            // that is still filling is not restarted over and over.
            guard nowMs > timers.rewatchAllowedAtMs else { return .none }
            timers.rewatchAllowedAtMs = nowMs + timers.rewatchDelayMs
            timers.rewatchDelayMs = min(30_000, timers.rewatchDelayMs * 2)
            return .rewatch
        }
        timers.rewatchDelayMs = 4000
        if let window, abs(target - work) > 0.75, nowMs > timers.seekAllowedAtMs {
            timers.seekAllowedAtMs = nowMs + 1500
            return .seek(min(window.upperBound - 0.5, max(window.lowerBound, want)))
        }
        return .none
    }

    public static func needsRenewal(expiresAtMs: Double, nowMs: Double) -> Bool { expiresAtMs - nowMs <= renewBeforeMs }
    /// Seconds to wait before watching again after the `attempt`-th relay loss in a row.
    public static func reconnectDelay(attempt: Int) -> Double { 0.6 * Double(max(1, attempt)) }
    /// A film's natural end is reported once each time it is opened (the epoch changes when it is selected again).
    public static func endKey(itemID: String, epoch: Int) -> String { "\(itemID):\(epoch)" }

    /// Desktop `CinemaYouTubeStage`: whether the official player must be brought back to the room.
    /// Player states follow the YouTube iframe API (1 playing, 3 buffering).
    public static func youtubeNeedsSync(roomPlaying: Bool, playerState: Int, positionSec: Double, expectedSec: Double, sinceLastSync: Double) -> Bool {
        guard sinceLastSync >= 2.5 else { return false }
        if roomPlaying && playerState != 3 && playerState != 1 { return true }
        if !roomPlaying && playerState == 1 { return true }
        return playerState != 3 && abs(positionSec - expectedSec) > 2.5 && sinceLastSync > 4
    }

    /// `m:ss` or `h:mm:ss` (desktop `clock`).
    public static func clock(_ seconds: Double) -> String {
        let total = Int(max(0, seconds.isFinite ? seconds : 0))
        let hours = total / 3600, minutes = total % 3600 / 60, rest = String(format: "%02d", total % 60)
        return hours > 0 ? "\(hours):\(String(format: "%02d", minutes)):\(rest)" : "\(minutes):\(rest)"
    }
}

/// One relay session's ticket, renewed shortly before it expires (desktop `ticketFor`). Renewal never starts
/// or restarts a relay; once the session ended this yields nil, which the player treats as "watch again".
public actor CinemaTicketStore {
    public typealias Renew = @Sendable () async throws -> CinemaTicket
    private var ticket: String
    private var expiresAtMs: Double
    private var ended = false
    private var renewal: Task<String?, Never>?
    private let renew: Renew
    private let now: @Sendable () -> Double

    public init(ticket: String, ttlMs: Double, now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1000 }, renew: @escaping Renew) {
        self.ticket = ticket; self.now = now; self.renew = renew
        expiresAtMs = now() + max(0, ttlMs)
    }
    /// The current ticket, renewed when it is close to expiry or `force`d after a 401; nil once the session ended.
    public func current(force: Bool = false) async -> String? {
        if ended { return nil }
        if !force, !HallSync.needsRenewal(expiresAtMs: expiresAtMs, nowMs: now()) { return ticket }
        if let renewal { return await renewal.value }
        let task = Task { await self.performRenewal() }
        renewal = task
        return await task.value
    }
    private func performRenewal() async -> String? {
        defer { renewal = nil }
        do {
            let next = try await renew()
            ticket = next.ticket; expiresAtMs = now() + max(0, next.ttlMs)
            return ticket
        } catch let error as CinemaError where error.code == "CINEMA_SESSION_ENDED" {
            ended = true
            return nil
        } catch {
            // A lost renewal keeps a ticket that is still valid; an expired one means watching again.
            return expiresAtMs > now() ? ticket : nil
        }
    }
}
