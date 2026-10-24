import Foundation
import XCTest
@testable import RoomsCore

private final class LifecycleResponses: @unchecked Sendable {
    static let shared = LifecycleResponses()
    private let lock = NSLock()
    private var handler: @Sendable (URLRequest) -> Int = { _ in 503 }
    private var seen: [String] = []
    func set(_ handler: @escaping @Sendable (URLRequest) -> Int) { lock.lock(); self.handler = handler; seen = []; lock.unlock() }
    func reply(_ request: URLRequest) -> Int {
        lock.lock(); let handler = handler; seen.append((request.httpMethod ?? "") + " " + (request.url?.path ?? "")); lock.unlock()
        return handler(request)
    }
    var paths: [String] { lock.lock(); defer { lock.unlock() }; return seen }
}
private final class LifecycleStub: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let status = LifecycleResponses.shared.reply(request)
        if status == 0 { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data()); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class SessionLifecycleTests: XCTestCase {
    private func api() throws -> APIClient {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [LifecycleStub.self]
        return APIClient(origin: try EndpointPolicy.origin("https://rooms.test"), token: "old-session", session: URLSession(configuration: config))
    }

    func testGatewayBackoffGrowsThenStaysAtTheCapForever() {
        XCTAssertEqual((1...7).map { ReconnectBackoff.delay(failures: $0) }, [1, 2, 4, 8, 10, 10, 10])
        XCTAssertEqual(ReconnectBackoff.delay(failures: 0), 0)
        XCTAssertEqual(ReconnectBackoff.delay(failures: 10_000), 10)
        XCTAssertEqual(ReconnectBackoff.delay(failures: 6, cap: ReconnectBackoff.restoreCap), 30)
        XCTAssertEqual(ReconnectBackoff.delay(failures: 5, cap: ReconnectBackoff.restoreCap), 16)
    }
    func testJitterOnlyShortensTheDelayByAtMostAFifth() {
        XCTAssertEqual(ReconnectBackoff.delay(failures: 5, jitter: 1), 8, accuracy: 0.0001)
        XCTAssertEqual(ReconnectBackoff.delay(failures: 5, jitter: 5), 8, accuracy: 0.0001)
        XCTAssertEqual(ReconnectBackoff.delay(failures: 5, jitter: -1), 10, accuracy: 0.0001)
    }
    func testOnlyAnExpiredTokenSendsACachedSessionBackToTheLoginForm() {
        XCTAssertEqual(SessionRestoreOutcome(error: RoomsError.expired), .signedOut)
        for error: Error in [RoomsError.unavailable, RoomsError.timeout, RoomsError.rateLimited, RoomsError.invalidResponse, URLError(.notConnectedToInternet)] {
            XCTAssertEqual(SessionRestoreOutcome(error: error), .retry, "\(error)")
        }
    }
    func testPendingLogoutIsRetriedOnlyForTransientFailures() {
        XCTAssertTrue(PendingLogout.isFinished(after: RoomsError.expired))
        XCTAssertTrue(PendingLogout.isFinished(after: RoomsError.denied))
        XCTAssertTrue(PendingLogout.isFinished(after: RoomsError.invalidEndpoint))
        XCTAssertFalse(PendingLogout.isFinished(after: RoomsError.unavailable))
        XCTAssertFalse(PendingLogout.isFinished(after: RoomsError.timeout))
        XCTAssertFalse(PendingLogout.isFinished(after: RoomsError.rateLimited))
        XCTAssertFalse(PendingLogout.isFinished(after: CancellationError()))
    }
    func testPendingLogoutQueueDedupesCapsAndSurvivesTheKeychainRoundTrip() throws {
        var queue = PendingLogoutQueue()
        queue.add(PendingLogout(origin: "https://rooms.test", token: ""))
        XCTAssertTrue(queue.isEmpty)
        for index in 0..<7 { queue.add(PendingLogout(origin: "https://rooms.test", token: "t\(index)")) }
        XCTAssertEqual(queue.items.map(\.token), ["t2", "t3", "t4", "t5", "t6"])
        queue.add(PendingLogout(origin: "https://rooms.test", token: "t3"))
        XCTAssertEqual(queue.items.map(\.token), ["t2", "t4", "t5", "t6", "t3"])
        queue.remove(PendingLogout(origin: "https://rooms.test", token: "t5"))
        let decoded = try JSONDecoder().decode(PendingLogoutQueue.self, from: JSONEncoder().encode(queue))
        XCTAssertEqual(decoded, queue)
        XCTAssertEqual(decoded.items.map(\.token), ["t2", "t4", "t6", "t3"])
        XCTAssertEqual(PendingLogoutQueue(items: (0..<9).map { PendingLogout(origin: "o", token: "\($0)") }).items.count, PendingLogoutQueue.limit)
    }
    func testEndSessionUnsubscribesPushBeforeEndingTheSession() async throws {
        LifecycleResponses.shared.set { _ in 204 }
        try await api().endSession()
        XCTAssertEqual(LifecycleResponses.shared.paths, ["POST /api/push/unsubscribe", "POST /api/auth/session/logout"])
    }
    func testEndSessionReportsAnUnreachableServerSoTheTokenIsKept() async throws {
        LifecycleResponses.shared.set { _ in 0 }
        do { try await api().endSession(); XCTFail("must throw while offline") }
        catch { XCTAssertEqual(error as? RoomsError, .unavailable); XCTAssertFalse(PendingLogout.isFinished(after: error)) }
    }
    func testEndSessionTreatsAnAlreadyDeadSessionAsFinished() async throws {
        // A missing unsubscribe route must not block the logout itself.
        LifecycleResponses.shared.set { $0.url?.path == "/api/push/unsubscribe" ? 404 : 401 }
        do { try await api().endSession(); XCTFail("401 must surface") }
        catch { XCTAssertEqual(error as? RoomsError, .expired); XCTAssertTrue(PendingLogout.isFinished(after: error)) }
    }
}
