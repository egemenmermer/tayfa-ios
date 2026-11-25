import XCTest
@testable import RoomsCore

final class RoomRejoinTests: XCTestCase {
    private func backgrounded() -> RoomRejoin {
        var rule = RoomRejoin(); rule.connected(); rule.wentToBackground(established: true, now: 0); return rule
    }

    func testRoomLostInTheBackgroundComesBackOnceOnReturnWithItsMicrophone() {
        var rule = backgrounded()
        XCTAssertTrue(rule.lost(.connection, established: true, voiceRoom: true, duringInterruption: false, microphone: true, now: 100))
        XCTAssertTrue(rule.waitsForReturn)
        XCTAssertNil(rule.take(audioUsable: true), "nothing starts while the app is still in the background")
        rule.returned(now: 300)
        XCTAssertEqual(rule.take(audioUsable: true), .on)
        XCTAssertNil(rule.take(audioUsable: true), "only one rejoin")
        XCTAssertFalse(rule.isPending)
    }

    func testPhoneCallStillInProgressHoldsTheRejoin() {
        var rule = backgrounded()
        rule.lost(.connection, established: true, voiceRoom: true, duringInterruption: false, microphone: false, now: 10)
        rule.returned(now: 20)
        XCTAssertNil(rule.take(audioUsable: false))
        XCTAssertEqual(rule.take(audioUsable: true), .off)
    }

    func testSuspendedAppNoticingTheLossOnlyAfterReturnStillRejoins() {
        // The reconnect starts soon after the return; LiveKit and the 30 s deadline give up much later.
        var rule = backgrounded()
        rule.returned(now: 1000)
        rule.reconnecting(now: 1010)
        XCTAssertTrue(rule.lost(.connection, established: true, voiceRoom: true, duringInterruption: false, microphone: false, now: 1070))
        XCTAssertEqual(rule.take(audioUsable: true), .off)

        // The foreground check that expires a stale reconnect right at the return.
        rule = backgrounded()
        rule.reconnecting(now: 500)
        rule.returned(now: 900)
        XCTAssertTrue(rule.lost(.connection, established: true, voiceRoom: true, duringInterruption: false, microphone: false, now: 900))

        // Dropped right after the return without a reconnect phase.
        rule = backgrounded()
        rule.returned(now: 1000)
        XCTAssertTrue(rule.lost(.connection, established: true, voiceRoom: true, duringInterruption: false, microphone: false, now: 1000 + RoomRejoin.confirmAfterReturn - 1))
    }

    func testConnectionThatProvedItselfAfterReturnIsAnOrdinaryForegroundLoss() {
        var rule = backgrounded()
        rule.returned(now: 1000)
        rule.reconnecting(now: 1000 + RoomRejoin.confirmAfterReturn)
        XCTAssertFalse(rule.lost(.connection, established: true, voiceRoom: true, duringInterruption: false, microphone: false, now: 1200))

        rule = backgrounded()
        rule.returned(now: 1000)
        rule.connected() // LiveKit reconnected by itself in the foreground.
        rule.reconnecting(now: 1005)
        XCTAssertFalse(rule.lost(.connection, established: true, voiceRoom: true, duringInterruption: false, microphone: false, now: 1010))
    }

    func testForegroundLossWithoutABackgroundPeriodDoesNotRejoin() {
        var rule = RoomRejoin(); rule.connected()
        rule.reconnecting(now: 5)
        XCTAssertFalse(rule.lost(.connection, established: true, voiceRoom: true, duringInterruption: false, microphone: true, now: 40))
        XCTAssertNil(rule.take(audioUsable: true))
    }

    func testTheRejoinCannotLoop() {
        var rule = backgrounded()
        rule.lost(.connection, established: true, voiceRoom: true, duringInterruption: false, microphone: false, now: 10)
        rule.returned(now: 20)
        XCTAssertNotNil(rule.take(audioUsable: true))
        // The rejoin's own join first tears down the old room, then fails before connecting, even if the app is left again.
        rule.cancel()
        rule.wentToBackground(established: false, now: 25)
        XCTAssertFalse(rule.lost(.connection, established: false, voiceRoom: true, duringInterruption: false, microphone: false, now: 30))
        rule.returned(now: 40)
        XCTAssertNil(rule.take(audioUsable: true))

        // The rejoin connects and then drops again in the foreground: no second rejoin.
        rule = backgrounded()
        rule.lost(.connection, established: true, voiceRoom: true, duringInterruption: false, microphone: false, now: 10)
        rule.returned(now: 20)
        XCTAssertNotNil(rule.take(audioUsable: true))
        rule.cancel(); rule.connected()
        rule.reconnecting(now: 25)
        XCTAssertFalse(rule.lost(.connection, established: true, voiceRoom: true, duringInterruption: false, microphone: false, now: 30))
        XCTAssertNil(rule.take(audioUsable: true))
    }

    func testDecisionsOfOthersAreNeverUndone() {
        for loss in [RoomLoss.removed, .replaced, .closed, .safety] {
            var rule = backgrounded()
            XCTAssertFalse(rule.lost(loss, established: true, voiceRoom: true, duringInterruption: true, microphone: true, now: 10), "\(loss)")
            rule.returned(now: 20)
            XCTAssertNil(rule.take(audioUsable: true), "\(loss)")
        }
        // A kick replaces a rejoin that was already waiting.
        var rule = backgrounded()
        rule.lost(.connection, established: true, voiceRoom: true, duringInterruption: false, microphone: false, now: 10)
        rule.lost(.removed, established: false, voiceRoom: true, duringInterruption: false, microphone: false, now: 11)
        rule.returned(now: 20)
        XCTAssertNil(rule.take(audioUsable: true))
    }

    func testLeaveMoveOrCallBeforeTheReturnCancelsTheRejoin() {
        var rule = backgrounded()
        rule.lost(.connection, established: true, voiceRoom: true, duringInterruption: false, microphone: true, now: 10)
        rule.cancel()
        rule.returned(now: 20)
        XCTAssertNil(rule.take(audioUsable: true))
    }

    func testOnlyEstablishedVoiceRoomsComeBackFromTheBackground() {
        var rule = backgrounded()
        XCTAssertFalse(rule.lost(.connection, established: true, voiceRoom: false, duringInterruption: false, microphone: false, now: 10), "private calls end")
        rule = RoomRejoin(); rule.wentToBackground(established: false, now: 0)
        XCTAssertFalse(rule.lost(.connection, established: false, voiceRoom: true, duringInterruption: false, microphone: false, now: 10), "a join still in progress")
    }

    func testPhoneCallRejoinStillStartsWhenTheCallEndsEvenInTheBackground() {
        var rule = RoomRejoin(); rule.connected()
        XCTAssertTrue(rule.lost(.connection, established: false, voiceRoom: true, duringInterruption: true, microphone: true, now: 10))
        XCTAssertFalse(rule.waitsForReturn)
        XCTAssertNil(rule.take(audioUsable: false), "the call is still on")
        rule.wentToBackground(established: false, now: 11)
        XCTAssertEqual(rule.take(audioUsable: true), .on)
        XCTAssertNil(rule.take(audioUsable: true))
    }

    // MARK: Long absence

    private func lostInBackground(leftAt: TimeInterval, lostAt: TimeInterval, microphone: Bool) -> RoomRejoin {
        var rule = RoomRejoin(); rule.connected(); rule.wentToBackground(established: true, now: leftAt)
        rule.lost(.connection, established: true, voiceRoom: true, duringInterruption: false, microphone: microphone, now: lostAt)
        return rule
    }

    func testAwayJustUnderTenMinutesKeepsTheMicrophone() {
        var rule = lostInBackground(leftAt: 1000, lostAt: 1001, microphone: true)
        rule.returned(now: 1000 + RoomRejoin.longAbsence - 0.5)
        XCTAssertEqual(rule.take(audioUsable: true), .on)
    }

    func testAwayTenMinutesOrLongerStartsTheMicrophoneOff() {
        for away: TimeInterval in [RoomRejoin.longAbsence, RoomRejoin.longAbsence + 1, 3 * 3600] {
            var rule = lostInBackground(leftAt: 1000, lostAt: 1001, microphone: true)
            rule.returned(now: 1000 + away)
            XCTAssertEqual(rule.take(audioUsable: true), .offAfterLongAbsence, "\(away)")
        }
    }

    func testAbsenceRunsFromLeavingUntilTheReturnNotUntilTheLoss() {
        // Lost late in a long absence: the return decides.
        var rule = lostInBackground(leftAt: 0, lostAt: 590, microphone: true)
        rule.returned(now: 601)
        XCTAssertEqual(rule.take(audioUsable: true), .offAfterLongAbsence)
        // Lost early in a short absence.
        rule = lostInBackground(leftAt: 0, lostAt: 5, microphone: true)
        rule.returned(now: 599)
        XCTAssertEqual(rule.take(audioUsable: true), .on)
        // Noticed only well after a short absence: the time in the foreground does not count.
        rule = RoomRejoin(); rule.connected(); rule.wentToBackground(established: true, now: 0)
        rule.returned(now: 300)
        rule.reconnecting(now: 310)
        rule.lost(.connection, established: true, voiceRoom: true, duringInterruption: false, microphone: true, now: 900)
        XCTAssertEqual(rule.take(audioUsable: true), .on)
        // Only the latest absence counts.
        rule = RoomRejoin(); rule.connected()
        rule.wentToBackground(established: true, now: 0); rule.returned(now: 5000); rule.connected()
        rule.wentToBackground(established: true, now: 6000)
        rule.lost(.connection, established: true, voiceRoom: true, duringInterruption: false, microphone: true, now: 6010)
        rule.returned(now: 6100)
        XCTAssertEqual(rule.take(audioUsable: true), .on)
    }

    func testMicrophoneThatWasOffStaysOff() {
        for away: TimeInterval in [10, RoomRejoin.longAbsence + 10] {
            var rule = lostInBackground(leftAt: 0, lostAt: 1, microphone: false)
            rule.returned(now: away)
            XCTAssertEqual(rule.take(audioUsable: true), .off, "\(away)")
        }
    }

    func testPhoneCallOfTenMinutesOrLongerAlsoStartsTheMicrophoneOff() {
        var rule = RoomRejoin(); rule.connected()
        rule.interruptionBegan(now: 100)
        rule.lost(.connection, established: true, voiceRoom: true, duringInterruption: true, microphone: true, now: 110)
        rule.interruptionEnded(now: 100 + RoomRejoin.longAbsence - 1)
        XCTAssertEqual(rule.take(audioUsable: true), .on)

        rule = RoomRejoin(); rule.connected()
        rule.interruptionBegan(now: 100)
        rule.interruptionBegan(now: 300) // a nested interruption keeps the first start
        rule.lost(.connection, established: true, voiceRoom: true, duringInterruption: true, microphone: true, now: 110)
        rule.interruptionEnded(now: 100 + RoomRejoin.longAbsence)
        XCTAssertEqual(rule.take(audioUsable: true), .offAfterLongAbsence)
    }
}
