import Foundation

/// One roster change seen by this listener. `sound` is the actor's attribute at that moment.
public struct RosterCue: Equatable, Sendable {
    public let kind: RoomCue
    public let actor: String
    /// The listener's own join or departure.
    public let local: Bool
    public let sound: String?
    public init(kind: RoomCue, actor: String, local: Bool = false, sound: String? = nil) {
        self.kind = kind; self.actor = actor; self.local = local; self.sound = sound
    }
}

public struct CueDecision: Equatable, Sendable {
    public enum Play: Equatable, Sendable { case classic, personal(String) }
    public let kind: RoomCue
    public let actor: String
    public let play: Play
    public init(kind: RoomCue, actor: String, play: Play) { self.kind = kind; self.actor = actor; self.play = play }
    public var sound: String? { if case .personal(let sound) = play { sound } else { nil } }
}

/// Decides what one listener hears for roster changes, so a room never becomes a queue of clips.
/// Pure and clock-injected (milliseconds); the runtime owns timers and playback. Port of desktop
/// `PersonalCuePolicy` (`shared-contracts/src/personal-sound-policy.ts`).
///
/// - The listener's own events always play the classic cue.
/// - A departure is held for `leaveHoldMs`; a return inside the hold silences both (reconnects).
/// - Returning soon after leaving, or leaving soon after joining, plays the classic cue.
/// - At most one personal sound per person and event per `perPersonCooldownMs`.
/// - At most one personal sound per `roomWindowMs` for the whole room; others fall back to classic.
/// - Classic cues closer than `classicCoalesceMs` collapse into one.
/// - Without a sound, or when `allow(actor)` is false, the classic cue plays.
public struct PersonalCuePolicy: Sendable {
    private struct Held: Sendable { let actor: String; let cue: RosterCue; let at: Double; let joined: Double? }
    public let config: PersonalSoundPolicy
    private var joined: [String: Double] = [:]
    private var left: [String: Double] = [:]
    /// In arrival order: departures are released in the order they happened.
    private var held: [Held] = []
    private var personal: [String: Double] = [:]
    private var roomPersonalAt = -Double.infinity
    private var classicAt = -Double.infinity
    public init(config: PersonalSoundPolicy = .standard) { self.config = config }

    public mutating func push(_ cue: RosterCue, now: Double, allow: (String) -> Bool) -> [CueDecision] {
        if cue.local { return classic(cue, now: now) }
        if cue.kind == .enter {
            if let index = held.firstIndex(where: { $0.actor == cue.actor }) {
                let returning = held.remove(at: index)
                if let time = returning.joined { joined[cue.actor] = time }
                return []
            }
            let leftAt = left[cue.actor]
            joined[cue.actor] = now
            if let leftAt, now - leftAt < config.rejoinClassicMs { return classic(cue, now: now) }
            return decide(cue, now: now, allow: allow)
        }
        let joinedAt = joined.removeValue(forKey: cue.actor)
        let entry = Held(actor: cue.actor, cue: cue, at: now, joined: joinedAt)
        if let index = held.firstIndex(where: { $0.actor == cue.actor }) { held[index] = entry } else { held.append(entry) }
        return []
    }
    /// Releases departures whose hold has passed.
    public mutating func tick(now: Double, allow: (String) -> Bool) -> [CueDecision] {
        var out: [CueDecision] = []
        for entry in held {
            if now - entry.at < config.leaveHoldMs { continue }
            held.removeAll { $0.actor == entry.actor }
            left[entry.actor] = entry.at
            let shortStay = entry.joined.map { entry.at - $0 < config.shortStayClassicMs } ?? false
            out += shortStay ? classic(entry.cue, now: now) : decide(entry.cue, now: now, allow: allow)
        }
        return out
    }
    /// When the next held departure is due, for the runtime's timer.
    public func nextDue() -> Double? { held.map { $0.at + config.leaveHoldMs }.min() }
    /// A new room or account, or cues that cannot be heard: forget pending departures and history.
    public mutating func reset() {
        joined = [:]; left = [:]; held = []; personal = [:]
        roomPersonalAt = -.infinity; classicAt = -.infinity
    }
    private mutating func decide(_ cue: RosterCue, now: Double, allow: (String) -> Bool) -> [CueDecision] {
        let key = "\(cue.kind.rawValue):\(cue.actor)"
        guard let sound = cue.sound, !sound.isEmpty, allow(cue.actor),
              personal[key].map({ now - $0 >= config.perPersonCooldownMs }) ?? true,
              now - roomPersonalAt >= config.roomWindowMs else { return classic(cue, now: now) }
        personal[key] = now
        roomPersonalAt = now
        // The clip itself announces the event; a classic cue right on top of it adds nothing.
        classicAt = now
        return [CueDecision(kind: cue.kind, actor: cue.actor, play: .personal(sound))]
    }
    private mutating func classic(_ cue: RosterCue, now: Double) -> [CueDecision] {
        if now - classicAt < config.classicCoalesceMs { return [] }
        classicAt = now
        return [CueDecision(kind: cue.kind, actor: cue.actor, play: .classic)]
    }
}
