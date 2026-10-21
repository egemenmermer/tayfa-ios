import XCTest
@testable import RoomsCore

@MainActor private final class CameraStub: RoomCameraTransport {
    var allowed = true
    var isFront = true
    var startFails = false
    var permission = true
    var holdPermission = false
    var holdEnable = false
    var requested = 0
    var enabled: [Bool] = []
    var permissionGate: CheckedContinuation<Bool, Never>?
    var enableGate: CheckedContinuation<Void, Never>?
    var stopFails = false
    func requestPermission() async -> Bool { requested += 1; if holdPermission { return await withCheckedContinuation { permissionGate = $0 } }; return permission }
    func setEnabled(_ value: Bool) async throws {
        enabled.append(value)
        if value && holdEnable { await withCheckedContinuation { enableGate = $0 } }
        if value && startFails { throw RoomsError.invalidResponse }
        if !value && stopFails { throw RoomsError.invalidResponse }
    }
    func switchPosition() async throws -> Bool { isFront.toggle(); return isFront }
}
@MainActor final class RoomCameraTests: XCTestCase {
    private func until(_ condition: () -> Bool) async {
        for _ in 0..<3000 { if condition() { return }; await Task.yield() }
        XCTFail("Expected camera operation did not reach its checkpoint")
    }
    func testNeverRequestsCameraUntilExplicitActionAndPermissionDenialStaysOff() async {
        let stub = CameraStub(); stub.permission = false; let session = RoomCameraSession(transport: stub)
        XCTAssertEqual(stub.requested, 0); XCTAssertEqual(session.snapshot.phase, .off)
        await session.toggle(); XCTAssertEqual(stub.requested, 1); XCTAssertFalse(session.snapshot.isOn); XCTAssertNotNil(session.snapshot.error); XCTAssertFalse(stub.enabled.contains(true))
        await session.shutdown()
    }
    func testLatePermissionAfterRoomShutdownCannotPublish() async {
        let stub = CameraStub(); stub.holdPermission = true; let session = RoomCameraSession(transport: stub)
        let opening = Task { await session.toggle() }; await until { stub.permissionGate != nil }
        await session.shutdown(); stub.permissionGate?.resume(returning: true); await opening.value
        XCTAssertFalse(stub.enabled.contains(true)); XCTAssertFalse(session.snapshot.isOn)
    }
    func testLateCameraStartAfterBackgroundStopsBeforeAnyNextMutation() async {
        let stub = CameraStub(); stub.holdEnable = true; let session = RoomCameraSession(transport: stub)
        let opening = Task { await session.toggle() }; await until { stub.enableGate != nil }
        let background = Task { await session.setForeground(false) }; await until { session.snapshot.phase == .stopping }
        stub.enableGate?.resume(); await opening.value; await background.value
        XCTAssertEqual(stub.enabled.first, true); XCTAssertEqual(stub.enabled.last, false); XCTAssertFalse(session.snapshot.isOn)
        let count = stub.enabled.filter { $0 }.count
        await session.setForeground(true); XCTAssertEqual(stub.enabled.filter { $0 }.count, count)
        await session.shutdown()
    }
    func testPictureInPictureBackgroundKeepsCameraUntilItEnds() async {
        let stub = CameraStub(); let session = RoomCameraSession(transport: stub)
        await session.toggle(); XCTAssertTrue(session.snapshot.isOn)
        await session.setForeground(false, keepRunning: true)
        XCTAssertTrue(session.snapshot.isOn); XCTAssertEqual(stub.enabled, [true])
        await session.switchPosition(); XCTAssertEqual(stub.enabled, [true])
        await session.setForeground(false)
        XCTAssertFalse(session.snapshot.isOn); XCTAssertEqual(stub.enabled.last, false)
        await session.shutdown()
    }
    func testPermissionChangeDuringPromptPreventsPublishing() async {
        let stub = CameraStub(); stub.holdPermission = true; let session = RoomCameraSession(transport: stub)
        let opening = Task { await session.toggle() }; await until { stub.permissionGate != nil }
        stub.allowed = false; stub.permissionGate?.resume(returning: true); await opening.value
        XCTAssertFalse(stub.enabled.contains(true)); XCTAssertNotNil(session.snapshot.error)
        await session.shutdown()
    }
    func testCameraSwitchAndExplicitCloseAreSeparateFromVoice() async {
        let stub = CameraStub(); let session = RoomCameraSession(transport: stub)
        await session.toggle(); XCTAssertTrue(session.snapshot.isOn)
        await session.switchPosition(); XCTAssertFalse(session.snapshot.front)
        await session.toggle(); XCTAssertEqual(session.snapshot.phase, .off); XCTAssertEqual(stub.enabled, [true, false])
        await session.shutdown()
    }
    func testRevocationStopsPublicationAndDoesNotAutoResume() async {
        let stub = CameraStub(); let session = RoomCameraSession(transport: stub)
        await session.toggle(); stub.allowed = false; await session.revoke()
        XCTAssertFalse(session.snapshot.isOn); XCTAssertEqual(stub.enabled.last, false)
        stub.allowed = true; XCTAssertFalse(session.snapshot.isOn)
        await session.shutdown()
    }
    func testUnsafeStopSignalsRoomOwner() async {
        let stub = CameraStub(); let session = RoomCameraSession(transport: stub); var notified = false
        session.onUnsafeStop = { notified = true }; await session.toggle(); stub.stopFails = true; await session.stop()
        XCTAssertTrue(notified); XCTAssertFalse(session.snapshot.isOn)
    }
    func testPartialPublishFailureStopsCapturer() async {
        let stub = CameraStub(); stub.startFails = true; let session = RoomCameraSession(transport: stub)
        await session.toggle()
        XCTAssertEqual(stub.enabled, [true, false]); XCTAssertEqual(session.snapshot.phase, .off); XCTAssertNotNil(session.snapshot.error)
        await session.shutdown()
    }
    func testTimedOutPermissionCannotPublishWhenItEventuallyReturns() async {
        let stub = CameraStub(); stub.holdPermission = true
        let session = RoomCameraSession(transport: stub, timeout: .milliseconds(10))
        let opening = Task { await session.toggle() }; await until { stub.permissionGate != nil }
        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(session.snapshot.phase, .off); XCTAssertNotNil(session.snapshot.error)
        stub.permissionGate?.resume(returning: true); await opening.value
        XCTAssertFalse(stub.enabled.contains(true)); await session.shutdown()
    }
    func testCameraSubscriptionOnlyIncludesVisibleForegroundPeers() {
        XCTAssertTrue(CameraSubscriptionPolicy.wants(participantID: "a", visible: ["a", "b"], foreground: true))
        XCTAssertFalse(CameraSubscriptionPolicy.wants(participantID: "c", visible: ["a", "b"], foreground: true))
        XCTAssertFalse(CameraSubscriptionPolicy.wants(participantID: "a", visible: ["a"], foreground: false))
        XCTAssertTrue(CameraSubscriptionPolicy.canPublish(enabled: true, sources: []))
        XCTAssertFalse(CameraSubscriptionPolicy.canPublish(enabled: true, sources: ["microphone"]))
        XCTAssertFalse(CameraSubscriptionPolicy.canPublish(enabled: false, sources: ["camera"]))
    }
}
