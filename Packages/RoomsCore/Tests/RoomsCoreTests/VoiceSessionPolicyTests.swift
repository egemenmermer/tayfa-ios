import XCTest
@testable import RoomsCore

final class VoiceSessionPolicyTests: XCTestCase {
    private let none = VoiceSessionPolicy.Need()
    private let listen = VoiceSessionPolicy.Need(playout: true)
    private let talk = VoiceSessionPolicy.Need(playout: true, recording: true)

    func testEveryActiveSessionMixesWithOtherAppsAndNeverDucksThem() {
        var policy = VoiceSessionPolicy()
        for (old, new) in [(none, listen), (listen, talk), (talk, listen), (none, talk)] {
            guard case .configure(let configuration, _) = policy.step(from: old, to: new) else { return XCTFail("expected a configuration") }
            XCTAssertTrue(configuration.options.contains(.mixWithOthers))
            XCTAssertFalse(configuration.options.contains(.duckOthers))
        }
        policy.speakerPreferred = false
        guard case .configure(let receiver, _) = policy.step(from: talk, to: talk) else { return XCTFail("expected a configuration") }
        XCTAssertTrue(receiver.options.contains(.mixWithOthers))
    }

    func testListenerGetsLiveKitsPlaybackPresetAndActivatesOnlyFromIdle() {
        var policy = VoiceSessionPolicy()
        XCTAssertEqual(policy.step(from: none, to: listen), .configure(.init(category: .playback, mode: .spokenAudio, options: [.mixWithOthers]), activate: true))
        XCTAssertEqual(policy.step(from: listen, to: listen), .configure(.init(category: .playback, mode: .spokenAudio, options: [.mixWithOthers]), activate: false))
    }

    func testTalkingKeepsBluetoothAirPlayAndSpeakerRoutingOfTheMediaPresets() {
        var policy = VoiceSessionPolicy()
        _ = policy.step(from: none, to: listen)
        let speaker = VoiceSessionPolicy.Configuration(category: .playAndRecord, mode: .default,
                                                       options: [.mixWithOthers, .allowBluetoothHFP, .allowBluetoothA2DP, .allowAirPlay, .defaultToSpeaker])
        XCTAssertEqual(policy.step(from: listen, to: talk), .configure(speaker, activate: false))
        policy.speakerPreferred = false
        let receiver = VoiceSessionPolicy.Configuration(category: .playAndRecord, mode: .default,
                                                        options: [.mixWithOthers, .allowBluetoothHFP, .allowBluetoothA2DP, .allowAirPlay])
        XCTAssertEqual(policy.step(from: talk, to: talk), .configure(receiver, activate: false))
    }

    func testMutingKeepsTheCallCategoryUntilNothingNeedsAudio() {
        var policy = VoiceSessionPolicy()
        _ = policy.step(from: none, to: talk)
        guard case .configure(let muted, _) = policy.step(from: talk, to: listen) else { return XCTFail("expected a configuration") }
        XCTAssertEqual(muted.category, .playAndRecord)
        XCTAssertEqual(policy.step(from: listen, to: none), .deactivate)
        XCTAssertFalse(policy.recorded)
        XCTAssertEqual(policy.step(from: none, to: none), .none)
        guard case .configure(let next, true) = policy.step(from: none, to: listen) else { return XCTFail("expected an activation") }
        XCTAssertEqual(next.category, .playback)
    }

    func testPlaybackThatOutlivesTheCallLeavesTheCallCategory() {
        // Sinema or a chat video holds playout while the voice room ends.
        var policy = VoiceSessionPolicy()
        _ = policy.step(from: none, to: talk)
        policy.callEnded()
        guard case .configure(let after, false) = policy.step(from: talk, to: listen) else { return XCTFail("expected a configuration") }
        XCTAssertEqual(after.category, .playback)
        // A call still recording takes the call category back at once.
        policy.callEnded()
        guard case .configure(let still, false) = policy.step(from: talk, to: talk) else { return XCTFail("expected a configuration") }
        XCTAssertEqual(still.category, .playAndRecord)
    }
}
