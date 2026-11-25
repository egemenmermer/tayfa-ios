import Foundation

/// Why a voice connection ended without the person leaving it, reduced to what decides an automatic rejoin.
public enum RoomLoss: Equatable, Sendable {
    /// The phone lost the connection on its own: network, timeout, a suspended app, a server restart.
    case connection
    /// The server removed this participant: a moderator's "Sesten çıkar", revoked access, or a leave from another client.
    case removed
    /// The same account joined the room from another device, which replaced this one.
    case replaced
    /// The room itself was closed.
    case closed
    /// Ended on purpose because the microphone or camera could not be stopped safely.
    case safety
    /// Only a lost connection comes back by itself; every other ending was somebody's decision.
    public var allowsRejoin: Bool { self == .connection }
}

/// The one automatic rejoin of a voice room that the phone lost on its own.
///
/// Two cases bring the room back once:
/// - It was lost during an OS interruption such as a phone call, or soon after it (`MediaRecovery.rejoinsLostConnection`).
///   It comes back as soon as the interruption is over, as before.
/// - It was lost while the app was in the background, for any connection reason and however long ago. It comes back
///   when the person returns to the app. iOS suspends a backgrounded app whose audio stopped, and the server then drops
///   the silent peer. A suspended app only notices after it resumes, so a connection that went into the background also
///   counts as lost there when it starts failing within `confirmAfterReturn` of the return, before it has proven itself
///   again in the foreground. The failure itself may come much later (reconnect attempts, deadlines).
///
/// The microphone comes back as the person left it, unless they were away `longAbsence` or longer: from leaving the
/// app until returning to it, or for the length of the phone call. Then the room still comes back, but the microphone
/// starts off, so nobody is heard without knowing. Deafen is not decided here and stays as it was.
///
/// It cannot loop: only an established connection arms it, the pending rejoin is spent by the single join it starts,
/// a join that fails before connecting never arms it again, and any explicit leave, join, move or call clears it.
///
/// Every `now` must come from one monotonic clock that keeps counting while the device sleeps.
public struct RoomRejoin: Sendable {
    /// Covers the server's ping timeout and the transport's failure detection after the app resumes.
    public static let confirmAfterReturn: TimeInterval = 45
    /// Away this long or longer, the rejoined room starts with the microphone off.
    public static let longAbsence: TimeInterval = 600
    /// How the microphone starts in the rejoined room.
    public enum Microphone: Equatable, Sendable {
        case on
        /// Off because the person had it off.
        case off
        /// Off although the person had it on: they were away `longAbsence` or longer.
        case offAfterLongAbsence
    }
    public private(set) var foreground = true
    private var returnedAt: TimeInterval = -.infinity
    private var leftAt: TimeInterval?
    /// From leaving the app to the latest return.
    private var lastAbsence: TimeInterval = 0
    private var interruptedAt: TimeInterval?
    /// The length of the latest OS interruption (phone call).
    private var lastInterruption: TimeInterval = 0
    /// The established connection spent time in the background and has not been confirmed in the foreground since.
    private var awayUnconfirmed = false
    /// A reconnect began while the connection was still unconfirmed after the background.
    private var brokeWhileAway = false
    private var pending: Pending?
    private struct Pending: Sendable { let microphone: Bool; let waitsForReturn: Bool }

    public init() {}

    public var isPending: Bool { pending != nil }
    /// A background loss waits for the person to come back to the app.
    public var waitsForReturn: Bool { pending?.waitsForReturn == true && !foreground }

    /// LiveKit reports the connection up: joined, or reconnected by itself.
    public mutating func connected() { awayUnconfirmed = !foreground; brokeWhileAway = false }
    /// `established`: a connection was up or reconnecting when the app left the foreground.
    public mutating func wentToBackground(established: Bool, now: TimeInterval) {
        if foreground { leftAt = now }
        foreground = false
        if established { awayUnconfirmed = true }
    }
    public mutating func returned(now: TimeInterval) {
        if let leftAt { lastAbsence = max(0, now - leftAt) }
        leftAt = nil; foreground = true; returnedAt = now
    }
    /// An OS interruption (phone call) began or ended; only its length is kept here.
    public mutating func interruptionBegan(now: TimeInterval) { if interruptedAt == nil { interruptedAt = now } }
    public mutating func interruptionEnded(now: TimeInterval) {
        if let interruptedAt { lastInterruption = max(0, now - interruptedAt) }
        interruptedAt = nil
    }
    /// LiveKit started reconnecting. Remembered when the connection had not been confirmed since the background.
    public mutating func reconnecting(now: TimeInterval) { if unconfirmed(now: now) { brokeWhileAway = true } }

    /// The connection ended without the person leaving. Returns whether a rejoin is now pending.
    /// - Parameters:
    ///   - established: the connection was up or reconnecting, not still joining.
    ///   - voiceRoom: a community voice room, not a private call.
    ///   - duringInterruption: `MediaRecovery` asks for the phone-call rejoin.
    ///   - microphone: whether the person had the microphone on, including one an interruption took away.
    @discardableResult
    public mutating func lost(_ loss: RoomLoss, established: Bool, voiceRoom: Bool, duringInterruption: Bool, microphone: Bool, now: TimeInterval) -> Bool {
        defer { awayUnconfirmed = false; brokeWhileAway = false }
        guard loss.allowsRejoin else { pending = nil; return false }
        if duringInterruption {
            pending = Pending(microphone: microphone, waitsForReturn: false)
        } else if voiceRoom, established, brokeWhileAway || unconfirmed(now: now) {
            pending = Pending(microphone: microphone, waitsForReturn: true)
        } else {
            pending = nil
        }
        return pending != nil
    }

    /// An explicit leave, a new join or move, a call taking over, or an account change: nothing comes back.
    public mutating func cancel() { pending = nil; awayUnconfirmed = false; brokeWhileAway = false }

    /// Spends the pending rejoin once it may start: audio is usable and, after a background loss, the app is in front.
    /// Returns how the microphone starts, or nil when nothing starts now.
    public mutating func take(audioUsable: Bool) -> Microphone? {
        guard let pending, audioUsable, foreground || !pending.waitsForReturn else { return nil }
        self.pending = nil
        guard pending.microphone else { return .off }
        let away = pending.waitsForReturn ? lastAbsence : lastInterruption
        return away >= Self.longAbsence ? .offAfterLongAbsence : .on
    }

    private func unconfirmed(now: TimeInterval) -> Bool {
        awayUnconfirmed && (!foreground || now - returnedAt < Self.confirmAfterReturn)
    }
}
