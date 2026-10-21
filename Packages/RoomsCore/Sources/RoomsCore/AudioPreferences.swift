import Foundation

/// iOS call-tuned speaker gain is quieter than desktop playback; remote tracks accept up to 10× gain.
public enum PlaybackGain {
    public static let participantRange = 0.0...2.0
    static let maximum = 6.0
    static func clamp(_ value: Double, to range: ClosedRange<Double>, fallback: Double) -> Double {
        value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
    }
}

public struct ParticipantAudioPreference: Codable, Equatable, Sendable {
    public var volume: Double
    public var muted: Bool
    public init(volume: Double = 1, muted: Bool = false) {
        self.volume = PlaybackGain.clamp(volume, to: PlaybackGain.participantRange, fallback: 1)
        self.muted = muted
    }
    public func playbackVolume(roomMuted: Bool, roomGain: Double = 1) -> Double {
        guard !roomMuted, !muted else { return 0 }
        let personal = PlaybackGain.clamp(volume, to: PlaybackGain.participantRange, fallback: 1)
        let room = roomGain.isFinite ? max(0, roomGain) : 1
        return min(PlaybackGain.maximum, personal * room)
    }
}

public struct AudioPreferences: Codable, Equatable, Sendable {
    public var noiseSuppression = true
    /// Room slider position (0–100 %) for everything heard in the room; see ``RoomLoudness``.
    public var roomLevel = RoomLoudness.defaultLevel
    public var participants: [String: ParticipantAudioPreference] = [:]
    /// Short sounds when someone enters or leaves the room (on by default, as on desktop).
    public var roomEventSounds = true
    /// The microphone as the person last left it with the mic button; a first-ever join starts muted (desktop RC24).
    public var microphoneOn = false
    /// Other people's chosen entrance and leave sounds; off plays the classic cue for everyone.
    public var personalSounds = true
    /// Listener-side level for room cues and personal sounds, 0–1.
    public var soundEffectsLevel = 1.0 {
        didSet { soundEffectsLevel = Self.effectsLevel(soundEffectsLevel) }
    }
    /// People whose personal sounds this listener silenced, oldest first; they get the classic cue.
    /// Capped like desktop `personal-sound-mutes.ts`: muting one more forgets the oldest.
    public private(set) var mutedEntranceUsers: [String] = []
    public static let maxMutedEntranceUsers = 500
    public var roomGain: Double { RoomLoudness.gain(forLevel: roomLevel) }
    public init() {}
    private enum CodingKeys: String, CodingKey { case noiseSuppression, roomLevel, roomVolume, participants, roomEventSounds, microphoneOn, personalSounds, soundEffectsLevel, mutedEntranceUsers }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        noiseSuppression = try container.decodeIfPresent(Bool.self, forKey: .noiseSuppression) ?? true
        if let level = try container.decodeIfPresent(Double.self, forKey: .roomLevel) {
            roomLevel = PlaybackGain.clamp(level, to: RoomLoudness.range, fallback: RoomLoudness.defaultLevel)
        } else if let legacy = try container.decodeIfPresent(Double.self, forKey: .roomVolume) {
            // The former 50–300 % multiplier keeps the loudness the person chose.
            roomLevel = RoomLoudness.level(forGain: legacy)
        }
        participants = try container.decodeIfPresent([String: ParticipantAudioPreference].self, forKey: .participants) ?? [:]
        roomEventSounds = try container.decodeIfPresent(Bool.self, forKey: .roomEventSounds) ?? true
        microphoneOn = try container.decodeIfPresent(Bool.self, forKey: .microphoneOn) ?? false
        personalSounds = (try? container.decodeIfPresent(Bool.self, forKey: .personalSounds)) ?? true
        soundEffectsLevel = Self.effectsLevel((try? container.decodeIfPresent(Double.self, forKey: .soundEffectsLevel)) ?? 1)
        let muted = (try? container.decodeIfPresent([LossyString].self, forKey: .mutedEntranceUsers)) ?? []
        var seen = Set<String>()
        mutedEntranceUsers = Array(muted.compactMap(\.value).filter { Self.validEntranceUser($0) && seen.insert($0).inserted }
            .prefix(Self.maxMutedEntranceUsers))
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(noiseSuppression, forKey: .noiseSuppression)
        try container.encode(roomLevel, forKey: .roomLevel)
        try container.encode(participants, forKey: .participants)
        try container.encode(roomEventSounds, forKey: .roomEventSounds)
        try container.encode(microphoneOn, forKey: .microphoneOn)
        try container.encode(personalSounds, forKey: .personalSounds)
        try container.encode(soundEffectsLevel, forKey: .soundEffectsLevel)
        try container.encode(mutedEntranceUsers, forKey: .mutedEntranceUsers)
    }
    /// Desktop `normalizeSoundEffectsLevel`: finite values clamp to 0–1, anything else is full level.
    public static func effectsLevel(_ value: Double) -> Double { value.isFinite ? min(1, max(0, value)) : 1 }
    /// Whether `actor`'s own entrance and leave sounds may play for this listener.
    public func allowsPersonalSound(from actor: String) -> Bool { personalSounds && !entranceMuted(actor) }
    public func entranceMuted(_ id: String) -> Bool { mutedEntranceUsers.contains(id) }
    /// Only user ids of the desktop's shape are kept; unmuting accepts anything already on the list.
    public mutating func setEntranceMuted(_ id: String, _ muted: Bool) {
        guard entranceMuted(id) != muted else { return }
        guard muted else { mutedEntranceUsers.removeAll { $0 == id }; return }
        guard Self.validEntranceUser(id) else { return }
        mutedEntranceUsers.append(id)
        if mutedEntranceUsers.count > Self.maxMutedEntranceUsers { mutedEntranceUsers.removeFirst(mutedEntranceUsers.count - Self.maxMutedEntranceUsers) }
    }
    /// Desktop `^[A-Za-z0-9_-]{1,128}$`.
    public static func validEntranceUser(_ id: String) -> Bool {
        let bytes = id.utf8
        return (1...128).contains(bytes.count) && bytes.allSatisfy { byte in
            (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
                || byte == UInt8(ascii: "_") || byte == UInt8(ascii: "-")
        }
    }
    public func participant(_ id: String) -> ParticipantAudioPreference { participants[id] ?? .init() }
    /// Per-track gain. Pass `boostRoom: false` when the playout limiter applies the room gain instead.
    public func playbackVolume(for id: String, roomMuted: Bool, boostRoom: Bool = true) -> Double {
        participant(id).playbackVolume(roomMuted: roomMuted, roomGain: boostRoom ? roomGain : 1)
    }
    public mutating func setRoomLevel(_ value: Double) {
        guard value.isFinite else { return }
        roomLevel = PlaybackGain.clamp(value, to: RoomLoudness.range, fallback: RoomLoudness.defaultLevel)
    }
    public mutating func setParticipant(_ id: String, volume: Double? = nil, muted: Bool? = nil) {
        var value = participant(id)
        if let volume {
            guard volume.isFinite else { return }
            value.volume = PlaybackGain.clamp(volume, to: PlaybackGain.participantRange, fallback: 1)
        }
        if let muted { value.muted = muted }
        if value == ParticipantAudioPreference() { participants.removeValue(forKey: id) }
        else { participants[id] = value }
    }
    public mutating func resetParticipant(_ id: String) { participants.removeValue(forKey: id) }
}

/// One element of a saved list that is dropped, not fatal, when it is not a string.
private struct LossyString: Decodable {
    let value: String?
    init(from decoder: Decoder) throws { value = try? decoder.singleValueContainer().decode(String.self) }
}

/// Device-local preferences, isolated by backend origin and signed-in account.
@MainActor public final class AudioPreferenceStore {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    private func key(origin: URL, userID: String) -> String {
        let scope = [origin.absoluteString, userID]
        let encoded = (try? JSONEncoder().encode(scope)) ?? Data()
        return "rooms.audio.v1." + encoded.base64EncodedString()
    }
    public func load(origin: URL, userID: String) -> AudioPreferences {
        guard let data = defaults.data(forKey: key(origin: origin, userID: userID)),
              var value = try? JSONDecoder().decode(AudioPreferences.self, from: data) else { return .init() }
        value.participants = value.participants.mapValues { .init(volume: $0.volume, muted: $0.muted) }
        return value
    }
    public func save(_ value: AudioPreferences, origin: URL, userID: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key(origin: origin, userID: userID))
    }
}
