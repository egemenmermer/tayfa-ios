import XCTest
@testable import RoomsCore

final class MediaRecoveryTests: XCTestCase {
    func testInterruptionRestoresOnlyPreviouslyEnabledMicrophoneInTheSameConnectedRoom() {
        var state = MediaRecovery(); state.connected()
        state.interruptionBegan(microphoneEnabled: true)
        state.interruptionBegan(microphoneEnabled: false)
        XCTAssertFalse(state.shouldRestoreMicrophone)
        state.interruptionEnded(shouldResume: true, now: 0)
        XCTAssertTrue(state.shouldRestoreMicrophone)
        state.cancelMicrophoneRestore(); XCTAssertFalse(state.shouldRestoreMicrophone)
        state.interruptionBegan(microphoneEnabled: false)
        state.interruptionEnded(shouldResume: true, now: 0); XCTAssertFalse(state.shouldRestoreMicrophone)
        state.interruptionBegan(microphoneEnabled: true)
        state.interruptionEnded(shouldResume: false, now: 0); XCTAssertFalse(state.shouldRestoreMicrophone)
        state.resumeAudio(); XCTAssertTrue(state.shouldRestoreMicrophone)
        state.reset(); state.connected(); XCTAssertFalse(state.shouldRestoreMicrophone)
    }
    func testRoomLostDuringOrJustAfterAPhoneCallIsRejoinedOnce() {
        var state = MediaRecovery(); state.connected()
        XCTAssertFalse(state.rejoinsLostConnection(now: 0))
        state.interruptionBegan(microphoneEnabled: true)
        XCTAssertTrue(state.rejoinsLostConnection(now: 500))
        state.interruptionEnded(shouldResume: true, now: 1000)
        XCTAssertTrue(state.interruptedMicrophoneIntent)
        // The drop is often noticed only when the app wakes up after the call.
        state.reset(); state.requireRetry()
        XCTAssertTrue(state.rejoinsLostConnection(now: 1000 + MediaRecovery.rejoinGrace - 1))
        XCTAssertFalse(state.rejoinsLostConnection(now: 1000 + MediaRecovery.rejoinGrace))
        state.cancelRejoin(); XCTAssertFalse(state.rejoinsLostConnection(now: 1001))
    }
    func testInterruptionOutsideARoomDoesNotRejoinLater() {
        var state = MediaRecovery()
        state.interruptionBegan(); state.interruptionEnded(shouldResume: true, now: 10)
        state.beginJoin(now: 11); state.connected()
        XCTAssertFalse(state.rejoinsLostConnection(now: 12))
    }
    func testJoinDeadlineCannotAffectReplacementRoom() {
        var state = MediaRecovery(); let old = state.reset(); state.beginJoin(now: 10)
        XCTAssertFalse(state.expired(ticket: old, now: 34.9)); XCTAssertTrue(state.expired(ticket: old, now: 35))
        let current = state.reset(); state.beginJoin(now: 40)
        XCTAssertFalse(state.expired(ticket: old, now: 100)); XCTAssertFalse(state.owns(old))
        XCTAssertTrue(state.expired(ticket: current, now: 65))
    }
    func testRepeatedReconnectDoesNotExtendDeadline() {
        var state = MediaRecovery(); let ticket = state.reset(); state.connected(); state.reconnect(now: 10); state.reconnect(now: 29)
        XCTAssertFalse(state.expired(ticket: ticket, now: 39)); XCTAssertTrue(state.expired(ticket: ticket, now: 40))
        state.connected(); XCTAssertFalse(state.expired(ticket: ticket, now: 100))
    }
    func testBackgroundReturnKeepsElapsedDeadline() {
        var state = MediaRecovery(); let ticket = state.reset(); state.connected(); state.reconnect(now: 5)
        XCTAssertTrue(state.expired(ticket: ticket, now: 50)); state.requireRetry()
        XCTAssertEqual(state.phase, .retry); XCTAssertFalse(state.expired(ticket: ticket, now: 60))
    }
    func testInterruptionOutlivesRoomAndRequiresExplicitResumeWithoutHint() {
        var state = MediaRecovery(); state.interruptionBegan(); state.reset()
        state.resumeAudio(); XCTAssertFalse(state.canUseAudio)
        state.interruptionEnded(shouldResume: false, now: 0); XCTAssertFalse(state.canUseAudio)
        state.resumeAudio(); XCTAssertTrue(state.canUseAudio)
        state.interruptionBegan(); state.interruptionEnded(shouldResume: true, now: 0); XCTAssertTrue(state.canUseAudio)
    }
    func testScreenBackgroundNeverDisablesVoiceOrSelectsAnotherStream() {
        var selection = ScreenSelection(); selection.select("a")
        XCTAssertTrue(selection.wants(source: "microphone", publicationID: "mic", presenterScreenID: nil, foreground: false))
        XCTAssertFalse(selection.wants(source: "screen_share_audio", publicationID: "audio", presenterScreenID: "a", foreground: false))
        XCTAssertTrue(selection.wants(source: "screen_share", publicationID: "a", presenterScreenID: "a", foreground: true))
        selection.reconcile(available: ["b"], subscribed: ["b"])
        XCTAssertNil(selection.id); XCTAssertEqual(selection.state, .ended)
        XCTAssertFalse(selection.wants(source: "screen_share", publicationID: "b", presenterScreenID: "b", foreground: true))
    }
    func testDiagnosticsBoundedCategoricalAndNoUserData() {
        var info = MediaDiagnostics(); for _ in 0..<40 { info.record(.routeChanged) }
        XCTAssertEqual(info.events.count, 20)
        let report = info.report(phase: .retry, network: .cellular, route: .bluetooth, foreground: true, interrupted: false, microphoneMuted: true, rendering: false, people: -1, streams: 2)
        XCTAssertTrue(report.contains("participants=0")); XCTAssertTrue(report.contains("network=cellular"))
        for value in ["token", "https://", "wss://", "userID", "channelID", "SSID", "password"] { XCTAssertFalse(report.contains(value)) }
    }
}
