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
/// It cannot loop: only an established connection arms it, the pending rejoin is spent by the single join it starts,
/// a join that fails before connecting never arms it again, and any explicit leave, join, move or call clears it.
public struct RoomRejoin: Sendable {
    /// Covers the server's ping timeout and the transport's failure detection after the app resumes.
    public static let confirmAfterReturn: TimeInterval = 45
    public private(set) var foreground = true
    private var returnedAt: TimeInterval = -.infinity
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
    public mutating func wentToBackground(established: Bool) {
        foreground = false
        if established { awayUnconfirmed = true }
    }
    public mutating func returned(now: TimeInterval) { foreground = true; returnedAt = now }
    /// LiveKit started reconnecting. Remembered when the connection had not been confirmed since the background.
    public mutating func reconnecting(now: TimeInterval) { if unconfirmed(now: now) { brokeWhileAway = true } }

    /// The connection ended without the person leaving. Returns whether a rejoin is now pending.
    /// - Parameters:
    ///   - established: the connection was up or reconnecting, not still joining.
    ///   - voiceRoom: a community voice room, not a private call.
    ///   - duringInterruption: `MediaRecovery` asks for the phone-call rejoin.
    ///   - microphone: the microphone the interruption took away, restored with the rejoin.
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
    /// Returns the microphone to restore, or nil when nothing starts now.
    public mutating func take(audioUsable: Bool) -> Bool? {
        guard let pending, audioUsable, foreground || !pending.waitsForReturn else { return nil }
        self.pending = nil
        return pending.microphone
    }

    private func unconfirmed(now: TimeInterval) -> Bool {
        awayUnconfirmed && (!foreground || now - returnedAt < Self.confirmAfterReturn)
    }
}
