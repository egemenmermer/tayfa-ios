import Foundation

/// What the app's audio session is while LiveKit needs playout or recording.
///
/// LiveKit (2.17.0) still decides *when* the session is needed: engine start and stop, and the playout handles held by
/// Sinema, chat videos and the settings preview. This decides *what* it is. It matches LiveKit's own
/// `AudioSessionEngineObserver.configureAudioSession` with its media presets (the app always asks for WebRTC's
/// software voice processing, so LiveKit picks mode `.default`, not the chat modes) except for one thing: the session
/// always mixes with other apps. Instagram, YouTube or music keep playing beside a voice room, and their playback no
/// longer interrupts the room (desktop and Discord behave the same).
///
/// Other apps are not ducked: `.duckOthers` would lower them for as long as the session is active, which is the whole
/// time in a voice room, not only while someone speaks.
public struct VoiceSessionPolicy: Equatable, Sendable {
    /// What LiveKit needs from the session right now (all engine and external requirements together).
    public struct Need: Equatable, Sendable {
        public var playout: Bool
        public var recording: Bool
        public init(playout: Bool = false, recording: Bool = false) { self.playout = playout; self.recording = recording }
        public var any: Bool { playout || recording }
    }
    public enum Category: Equatable, Sendable { case playback, playAndRecord }
    public enum Mode: Equatable, Sendable { case `default`, spokenAudio }
    public enum Option: Equatable, Hashable, Sendable, CaseIterable {
        case mixWithOthers, duckOthers, allowBluetoothHFP, allowBluetoothA2DP, allowAirPlay, defaultToSpeaker
    }
    public struct Configuration: Equatable, Sendable {
        public let category: Category
        public let mode: Mode
        public let options: Set<Option>
    }
    public enum Step: Equatable, Sendable {
        /// Nothing to change.
        case none
        /// Nothing needs audio any more: deactivate and let other apps resume.
        case deactivate
        /// Set the category; activate only when the session was idle before (LiveKit does the same).
        case configure(Configuration, activate: Bool)
    }

    /// Built-in speaker rather than receiver while no headset or Bluetooth route is connected.
    public var speakerPreferred = true
    /// `.playAndRecord` stays from the first recording until the call ends (LiveKit's `hasRecorded`): switching the
    /// category on every mute would restart the audio route in the middle of the call.
    public private(set) var recorded = false

    public init() {}

    public mutating func step(from old: Need, to new: Need) -> Step {
        if new.recording { recorded = true } else if !new.any { recorded = false }
        guard new.any else { return old.any ? .deactivate : .none }
        return .configure(configuration, activate: !old.any)
    }

    /// The voice room or call ended. Playback that outlives it (Sinema, a chat video) is no longer a call.
    public mutating func callEnded() { recorded = false }

    public var configuration: Configuration {
        guard recorded else { return Configuration(category: .playback, mode: .spokenAudio, options: [.mixWithOthers]) }
        var options: Set<Option> = [.mixWithOthers, .allowBluetoothHFP, .allowBluetoothA2DP, .allowAirPlay]
        if speakerPreferred { options.insert(.defaultToSpeaker) }
        return Configuration(category: .playAndRecord, mode: .default, options: options)
    }
}
