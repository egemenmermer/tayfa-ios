import Foundation

/// Short local sounds when someone enters or leaves the voice room, matching the desktop cues.
public enum RoomCue: String, Sendable { case enter, leave }

/// Initial roster and reconnect snapshots are baselines, never a burst of join cues
/// (port of the desktop `RoomCueTracker`). Each remote join or departure is its own cue carrying that
/// person's chosen sound: a join reads the new roster, a departure the roster it was last seen in.
public struct RoomCueTracker: Sendable {
    private struct State: Sendable {
        let scope: String
        let channel: String?
        let connected: Bool
        let others: [String: ParticipantSounds]
    }
    private var previous: State?
    private var established = false
    /// True when the last update took a new baseline instead of comparing rosters (first roster,
    /// reconnect, room or account change, own departure). A connected baseline inside the same room
    /// settles held departures of people it shows again; the policy resets only on a room or account change.
    public private(set) var rebased = true
    public init() {}

    /// `others` are the remote participants by identity with their sounds; the DJ bot never plays a cue.
    /// Own cues have an empty `actor` and are always `local`.
    public mutating func update(scope: String, channel: String?, connected: Bool, others: [String: ParticipantSounds]) -> [RosterCue] {
        let next = State(scope: scope, channel: channel, connected: connected,
                         others: others.filter { !$0.key.hasPrefix("rooms-music-") })
        let before = previous
        previous = next
        rebased = true
        guard let before, before.scope == next.scope else {
            established = false
            if next.connected, next.channel != nil { established = true; return [.own(.enter)] }
            return []
        }
        guard next.channel != nil else {
            let left = before.channel != nil && established
            established = false
            return left ? [.own(.leave)] : []
        }
        if before.channel != next.channel {
            established = false
            if next.connected { established = true; return [.own(.enter)] }
            return []
        }
        guard next.connected else { return [] }
        if !established { established = true; return [.own(.enter)] }
        guard before.connected else { return [] }
        rebased = false
        let joined = next.others.keys.filter { before.others[$0] == nil }.sorted()
        let departed = before.others.keys.filter { next.others[$0] == nil }.sorted()
        return joined.map { RosterCue(kind: .enter, actor: $0, sound: next.others[$0]?.enter) }
            + departed.map { RosterCue(kind: .leave, actor: $0, sound: before.others[$0]?.leave) }
    }
}

extension RosterCue {
    static func own(_ kind: RoomCue) -> RosterCue { RosterCue(kind: kind, actor: "", local: true) }
}

/// Original low-amplitude two-note PCM cue, no bundled asset or network (same notes as desktop).
public enum RoomCueTone {
    public static let sampleRate = 24_000

    public static func samples(_ cue: RoomCue) -> [Int16] {
        let count = Int((Double(sampleRate) * 0.24).rounded())
        let notes: [Double] = cue == .enter ? [540, 760] : [620, 410]
        return (0..<count).map { index in
            let t = Double(index) / Double(sampleRate)
            let frequency = notes[t < 0.12 ? 0 : 1]
            let phase = t.truncatingRemainder(dividingBy: 0.12) / 0.12
            let envelope = pow(sin(Double.pi * phase), 2)
            return Int16((sin(2 * Double.pi * frequency * t) * envelope * 0.13 * 32767).rounded())
        }
    }

    /// 16-bit mono WAV that `AVAudioPlayer` plays directly.
    public static func wav(_ cue: RoomCue) -> Data { wav(samples: samples(cue)) }
    /// Any mono PCM at ``sampleRate`` as a 16-bit WAV.
    public static func wav(samples pcm: [Int16]) -> Data {
        var data = Data()
        func text(_ value: String) { data.append(contentsOf: Array(value.utf8)) }
        func u32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = UInt32(pcm.count * 2)
        text("RIFF"); u32(36 + bytes); text("WAVE")
        text("fmt "); u32(16); u16(1); u16(1); u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        text("data"); u32(bytes)
        for sample in pcm { withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) } }
        return data
    }
}
