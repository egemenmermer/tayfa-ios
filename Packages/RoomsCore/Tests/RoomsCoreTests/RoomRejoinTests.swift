import XCTest
@testable import RoomsCore

final class RoomRejoinTests: XCTestCase {
    private func backgrounded() -> RoomRejoin {
        var rule = RoomRejoin(); rule.connected(); rule.wentToBackground(established: true); return rule
    }

    func testRoomLostInTheBackgroundComesBackOnceOnReturnWithItsMicrophone() {
        var rule = backgrounded()
        XCTAssertTrue(rule.lost(.connection, established: true, voiceRoom: true, duringInterruption: false, microphone: true, now: 100))
        XCTAssertTrue(rule.waitsForReturn)
        XCTAssertNil(rule.take(audioUsable: true), "nothing starts while the app is still in the background")
        // Hours later is still a return to a room the person never left.
        rule.returned(now: 100 + 3 * 3600)
        XCTAssertEqual(rule.take(audioUsable: true), true)
        XCTAssertNil(rule.take(audioUsable: true), "only one rejoin")
        XCTAssertFalse(rule.isPending)
    }

    func testPhoneCallStillInProgressHoldsTheRejoin() {
        var rule = backgrounded()
        rule.lost(.connection, established: true, voiceRoom: true, duringInterruption: false, microphone: false, now: 10)
        rule.returned(now: 20)
        XCTAssertNil(rule.take(audioUsable: false))
        XCTAssertEqual(rule.take(audioUsable: true), false)
    }

    func testSuspendedAppNoticingTheLossOnlyAfterReturnStillRejoins() {
        // The reconnect starts soon after the return; LiveKit and the 30 s deadline give up much later.
        var rule = backgrounded()
        rule.returned(now: 1000)
        rule.reconnecting(now: 1010)
        XCTAssertTrue(rule.lost(.connection, established: true, voiceRoom: true, duringInterruption: false, microphone: false, now: 1070))
        XCTAssertEqual(rule.take(audioUsable: true), false)

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
        rule.wentToBackground(established: false)
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
        rule = RoomRejoin(); rule.wentToBackground(established: false)
        XCTAssertFalse(rule.lost(.connection, established: false, voiceRoom: true, duringInterruption: false, microphone: false, now: 10), "a join still in progress")
    }

    func testPhoneCallRejoinStillStartsWhenTheCallEndsEvenInTheBackground() {
        var rule = RoomRejoin(); rule.connected()
        XCTAssertTrue(rule.lost(.connection, established: false, voiceRoom: true, duringInterruption: true, microphone: true, now: 10))
        XCTAssertFalse(rule.waitsForReturn)
        XCTAssertNil(rule.take(audioUsable: false), "the call is still on")
        rule.wentToBackground(established: false)
        XCTAssertEqual(rule.take(audioUsable: true), true)
        XCTAssertNil(rule.take(audioUsable: true))
    }
}
