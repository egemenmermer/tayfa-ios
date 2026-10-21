import Foundation

/// Monotonic deadlines and generation ownership, independent of SDK reconnect attempts.
public struct MediaRecovery: Sendable {
    public enum Phase: String, Sendable { case idle, joining, connected, reconnecting, retry }
    public private(set) var phase: Phase = .idle
    public private(set) var startedAt: TimeInterval?
    public private(set) var interrupted = false
    public private(set) var needsAudioResume = false
    private var restoreMicrophone = false
    /// A room lost during an OS interruption (a phone call), or this soon after it, is rejoined once.
    public static let rejoinGrace: TimeInterval = 60
    private var rejoinArmed = false
    private var rejoinUntil: TimeInterval?
    private var epoch = OperationEpoch()
    public init() {}
    public var ticket: UInt64 { epoch.advanceForRead() }
    public func owns(_ ticket: UInt64) -> Bool { epoch.owns(ticket) }
    @discardableResult public mutating func reset() -> UInt64 {
        let ticket = epoch.advance(); phase = .idle; startedAt = nil
        restoreMicrophone = false
        // An OS interruption can outlive the old room. Do not reopen audio during it.
        needsAudioResume = interrupted
        return ticket
    }
    public mutating func beginJoin(now: TimeInterval) { phase = .joining; startedAt = now }
    public mutating func connected() { phase = .connected; startedAt = nil }
    public mutating func reconnect(now: TimeInterval) {
        guard phase == .connected || phase == .reconnecting else { return }
        if phase != .reconnecting { startedAt = now }
        phase = .reconnecting
    }
    public func expired(ticket: UInt64, now: TimeInterval) -> Bool {
        guard owns(ticket), let startedAt else { return false }
        switch phase {
        case .joining: return now - startedAt >= 25
        case .reconnecting: return now - startedAt >= 30
        default: return false
        }
    }
    public mutating func requireRetry() { phase = .retry; startedAt = nil }
    public mutating func interruptionBegan(microphoneEnabled: Bool = false) {
        if !interrupted { restoreMicrophone = microphoneEnabled || restoreMicrophone }
        if [.joining, .connected, .reconnecting].contains(phase) { rejoinArmed = true; rejoinUntil = nil }
        interrupted = true; needsAudioResume = true
    }
    public mutating func interruptionEnded(shouldResume: Bool, now: TimeInterval) {
        interrupted = false; needsAudioResume = !shouldResume
        if rejoinArmed { rejoinUntil = now + Self.rejoinGrace }
    }
    /// iOS suspends the app during a call, so the room often drops while it lasts or right after it.
    public func rejoinsLostConnection(now: TimeInterval) -> Bool {
        guard rejoinArmed else { return false }
        if interrupted { return true }
        return rejoinUntil.map { now < $0 } ?? false
    }
    /// Spends the single automatic rejoin, or drops it after an explicit leave or a new join.
    public mutating func cancelRejoin() { rejoinArmed = false; rejoinUntil = nil }
    public mutating func resumeAudio() { if !interrupted { needsAudioResume = false } }
    public var canUseAudio: Bool { !interrupted && !needsAudioResume }
    public var shouldRestoreMicrophone: Bool { restoreMicrophone && canUseAudio && phase == .connected }
    public var interruptedMicrophoneIntent: Bool { restoreMicrophone }
    public mutating func cancelMicrophoneRestore() { restoreMicrophone = false }
}

/// Diagnostics deliberately accept only categorical values/counts, never arbitrary SDK errors or identifiers.
public struct MediaDiagnostics: Sendable {
    public enum Network: String, Sendable { case unknown, offline, wifi, cellular, wired, other }
    public enum Route: String, Sendable { case none, speaker, receiver, headphones, bluetooth, airplay, other }
    public enum Event: String, Sendable { case joining, connected, reconnecting, disconnected, timeout, interruption, interruptionEnded, routeChanged, routeRemoved, servicesReset, background, foreground, subscriptionFailed, microphoneFailed, audioFailed }
    public private(set) var events: [Event] = []
    public init() {}
    public mutating func record(_ event: Event) { events.append(event); if events.count > 20 { events.removeFirst(events.count - 20) } }
    public func report(phase: MediaRecovery.Phase, network: Network, route: Route, foreground: Bool, interrupted: Bool, microphoneMuted: Bool, rendering: Bool, people: Int, streams: Int) -> String {
        "ROOMS media diagnostics v1\nconnection=\(phase.rawValue)\nnetwork=\(network.rawValue)\nroute=\(route.rawValue)\nforeground=\(foreground)\ninterrupted=\(interrupted)\nmicrophoneMuted=\(microphoneMuted)\nrendering=\(rendering)\nparticipants=\(max(0, people))\nstreams=\(max(0, streams))\nevents=\(events.map(\.rawValue).joined(separator: ","))"
    }
}
