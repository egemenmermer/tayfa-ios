import XCTest
@testable import RoomsCore

final class VoiceControlPolicyTests: XCTestCase {
    func testMutingWorksWhileReconnectingButEnablingNeedsAConnection() {
        // Unmuted and reconnecting: the person can still mute.
        XCTAssertTrue(VoiceControlPolicy.canToggleMicrophone(muted: false, hasRoom: true, connected: false, busy: false, audioBlocked: false))
        // Muted and reconnecting: enabling waits for the connection.
        XCTAssertFalse(VoiceControlPolicy.canToggleMicrophone(muted: true, hasRoom: true, connected: false, busy: false, audioBlocked: false))
        XCTAssertTrue(VoiceControlPolicy.canToggleMicrophone(muted: true, hasRoom: true, connected: true, busy: false, audioBlocked: false))
    }
    func testNoRoomBusyOrBlockedAudioDisablesBothDirections() {
        for muted in [true, false] {
            XCTAssertFalse(VoiceControlPolicy.canToggleMicrophone(muted: muted, hasRoom: false, connected: false, busy: false, audioBlocked: false))
            XCTAssertFalse(VoiceControlPolicy.canToggleMicrophone(muted: muted, hasRoom: true, connected: true, busy: true, audioBlocked: false))
            XCTAssertFalse(VoiceControlPolicy.canToggleMicrophone(muted: muted, hasRoom: true, connected: true, busy: false, audioBlocked: true))
        }
    }
    func testDeafenCarriesIntoTheNextVoiceRoomButNotIntoADMCall() {
        var carry = HearingCarry()
        XCTAssertFalse(carry.resolve(voiceRoom: true))
        carry.record(true)
        XCTAssertTrue(carry.resolve(voiceRoom: true))
        XCTAssertTrue(carry.resolve(voiceRoom: true), "a second join keeps it")
        carry.record(false)
        XCTAssertFalse(carry.resolve(voiceRoom: true))
        carry.record(true)
        XCTAssertFalse(carry.resolve(voiceRoom: false), "a DM call starts with sound")
        XCTAssertFalse(carry.resolve(voiceRoom: true), "and the choice is gone afterwards")
        carry.record(true); carry.reset(); XCTAssertFalse(carry.deafened)
    }
    func testScreenShareLeaseErrorsAreSeparatedFromOtherFailures() {
        let denied = ScreenShareFailure.message(stage: .lease, error: RoomsError.denied)
        XCTAssertTrue(denied.contains("iznin yok"))
        let network = ScreenShareFailure.message(stage: .lease, error: URLError(.notConnectedToInternet))
        XCTAssertFalse(network.contains("iznin"), "a network failure is not blamed on permission")
        XCTAssertNotEqual(ScreenShareFailure.message(stage: .lease, error: RoomsError.expired), denied)
        XCTAssertNotEqual(ScreenShareFailure.message(stage: .lease, error: RoomsError.rateLimited), denied)
        let publish = ScreenShareFailure.message(stage: .publish, error: RoomsError.denied)
        XCTAssertFalse(publish.contains("iznin"), "publish failures are not permission errors")
        XCTAssertNotEqual(publish, network)
    }
}
