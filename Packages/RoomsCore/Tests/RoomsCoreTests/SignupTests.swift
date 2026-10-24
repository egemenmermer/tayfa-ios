import Foundation
import XCTest
@testable import RoomsCore

private final class SignupResponses: @unchecked Sendable {
    static let shared = SignupResponses()
    private let lock = NSLock()
    private var handler: @Sendable (URLRequest, Data) -> (Int, String) = { _, _ in (503, "") }
    private var seen: [(URLRequest, Data)] = []
    func set(_ handler: @escaping @Sendable (URLRequest, Data) -> (Int, String)) { lock.lock(); self.handler = handler; seen = []; lock.unlock() }
    func reply(_ request: URLRequest, body: Data) -> (Int, String) { lock.lock(); seen.append((request, body)); let handler = handler; lock.unlock(); return handler(request, body) }
    var requests: [(URLRequest, Data)] { lock.lock(); defer { lock.unlock() }; return seen }
}
private final class SignupStub: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body = request.httpBody ?? request.httpBodyStream.map { stream -> Data in
            stream.open(); defer { stream.close() }; var data = Data(); var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: 1024); if n <= 0 { break }; data.append(contentsOf: buffer.prefix(n)) }; return data
        } ?? Data()
        let (status, text) = SignupResponses.shared.reply(request, body: body)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private let requestId = String(repeating: "a1", count: 16)
private let pollSecret = String(repeating: "S", count: 43)
private let approvalCode = String(repeating: "c0", count: 32)

final class SignupAPITests: XCTestCase {
    private let origin = URL(string: "https://rooms.test")!
    private var api: APIClient { let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [SignupStub.self]; return APIClient(origin: origin, session: URLSession(configuration: config)) }
    private func json(_ data: Data) -> JSONValue { (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .null }

    func testRequestSendsExactlyEmailAndUsernameWithoutAuthorization() async throws {
        SignupResponses.shared.set { _, _ in (200, #"{"requestId":"\#(requestId)","pollSecret":"\#(pollSecret)","status":"pending"}"#) }
        let ticket = try await api.requestSignup(email: "a@b.co", username: "ayşe.k")
        XCTAssertEqual(ticket, SignupTicket(requestId: requestId, pollSecret: pollSecret))
        let sent = try XCTUnwrap(SignupResponses.shared.requests.first)
        XCTAssertEqual(sent.0.url?.path, "/rooms-access/v1/auth/signup-requests"); XCTAssertEqual(sent.0.httpMethod, "POST")
        // The service refuses unknown keys (`.strict()`).
        XCTAssertEqual(Set(json(sent.1).object.map { Array($0.keys) } ?? []), ["email", "username"])
        XCTAssertEqual(json(sent.1)["username"].string, "ayşe.k")
        XCTAssertNil(sent.0.value(forHTTPHeaderField: "Authorization"))
    }

    func testRequestErrorsAndMalformedReply() async {
        let cases: [(Int, String, SignupError)] = [
            (404, "{}", .notOffered), // service from before approved sign-up
            (501, #"{"error":"SIGNUP_UNAVAILABLE"}"#, .notOffered),
            (409, #"{"error":"SIGNUP_ALREADY_REQUESTED"}"#, .alreadyRequested),
            (429, #"{"error":"SIGNUP_BUSY"}"#, .busy),
            (429, #"{"error":"RATE_LIMITED"}"#, .rateLimited),
            (503, #"{"error":"SIGNUP_QUEUE_FULL"}"#, .queueFull),
            (400, #"{"error":"INVALID_INPUT"}"#, .invalidInput),
            (200, #"{"requestId":"short","pollSecret":"\#(pollSecret)"}"#, .invalidResponse),
        ]
        for (status, body, expected) in cases {
            SignupResponses.shared.set { _, _ in (status, body) }
            do { _ = try await api.requestSignup(email: "a@b.co", username: "ayse"); XCTFail("expected \(expected)") }
            catch { XCTAssertEqual(error as? SignupError, expected, "\(status) \(body)") }
        }
    }

    func testPollSendsBearerSecretAndParsesStatuses() async throws {
        SignupResponses.shared.set { _, _ in (200, #"{"status":"approved","inviteCode":"\#(approvalCode)","createdAt":"2026-10-24T08:00:00Z","expiresAt":"2026-10-31T08:00:00Z"}"#) }
        let poll = try await api.signupStatus(requestId: requestId, pollSecret: pollSecret)
        XCTAssertEqual(poll, SignupPoll(status: .approved, inviteCode: approvalCode, createdAt: "2026-10-24T08:00:00Z", expiresAt: "2026-10-31T08:00:00Z"))
        let sent = try XCTUnwrap(SignupResponses.shared.requests.first)
        XCTAssertEqual(sent.0.url?.path, "/rooms-access/v1/auth/signup-requests/\(requestId)"); XCTAssertEqual(sent.0.httpMethod, "GET")
        XCTAssertEqual(sent.0.value(forHTTPHeaderField: "Authorization"), "Bearer \(pollSecret)")

        // After the code was used (or fetched once on an older service) the poll says `issued` with a null code.
        SignupResponses.shared.set { _, _ in (200, #"{"status":"issued","inviteCode":null,"createdAt":"2026-10-24T08:00:00Z","expiresAt":null}"#) }
        let issued = try await api.signupStatus(requestId: requestId, pollSecret: pollSecret)
        XCTAssertEqual(issued.status, .issued); XCTAssertNil(issued.inviteCode)
        for status in ["pending", "rejected", "expired"] {
            SignupResponses.shared.set { _, _ in (200, #"{"status":"\#(status)","inviteCode":"\#(approvalCode)"}"#) }
            let poll = try await api.signupStatus(requestId: requestId, pollSecret: pollSecret)
            XCTAssertEqual(poll.status.rawValue, status); XCTAssertNil(poll.inviteCode, "a code only counts with approved")
        }
    }

    func testPollRejectsBadRepliesAndMapsNotFound() async {
        let cases: [(Int, String, SignupError)] = [
            (200, #"{"status":"approved","inviteCode":null}"#, .invalidResponse),
            (200, #"{"status":"approved","inviteCode":"XYZ"}"#, .invalidResponse),
            (200, #"{"status":"weird"}"#, .invalidResponse),
            (404, #"{"error":"SIGNUP_REQUEST_NOT_FOUND"}"#, .requestNotFound),
            (404, "", .requestNotFound),
            (502, "", .unavailable),
        ]
        for (status, body, expected) in cases {
            SignupResponses.shared.set { _, _ in (status, body) }
            do { _ = try await api.signupStatus(requestId: requestId, pollSecret: pollSecret); XCTFail("expected \(expected)") }
            catch { XCTAssertEqual(error as? SignupError, expected, "\(status) \(body)") }
        }
        // Malformed ids never reach the network.
        SignupResponses.shared.set { _, _ in (200, "{}") }
        do { _ = try await api.signupStatus(requestId: "../x", pollSecret: pollSecret); XCTFail("expected error") }
        catch { XCTAssertEqual(error as? SignupError, .requestNotFound) }
        XCTAssertTrue(SignupResponses.shared.requests.isEmpty)
    }

    func testCancelDeletesWithBearer() async throws {
        SignupResponses.shared.set { _, _ in (200, #"{"cancelled":true}"#) }
        try await api.cancelSignup(requestId: requestId, pollSecret: pollSecret)
        let sent = try XCTUnwrap(SignupResponses.shared.requests.first)
        XCTAssertEqual(sent.0.httpMethod, "DELETE"); XCTAssertEqual(sent.0.url?.path, "/rooms-access/v1/auth/signup-requests/\(requestId)")
        XCTAssertEqual(sent.0.value(forHTTPHeaderField: "Authorization"), "Bearer \(pollSecret)")
    }

    func testRegisterSendsExactBodyAndReturnsToken() async throws {
        SignupResponses.shared.set { _, _ in (200, #"{"token":"session-1"}"#) }
        let token = try await api.register(email: "a@b.co", password: "secret-pass", username: "ayse", inviteCode: approvalCode)
        XCTAssertEqual(token, "session-1")
        let sent = try XCTUnwrap(SignupResponses.shared.requests.first)
        XCTAssertEqual(sent.0.url?.path, "/rooms-access/v1/auth/register"); XCTAssertEqual(sent.0.httpMethod, "POST")
        XCTAssertEqual(Set(json(sent.1).object.map { Array($0.keys) } ?? []), ["email", "password", "username", "inviteCode"])
        XCTAssertEqual(json(sent.1)["inviteCode"].string, approvalCode); XCTAssertEqual(json(sent.1)["password"].string, "secret-pass")
        XCTAssertNil(sent.0.value(forHTTPHeaderField: "Authorization"))
    }

    func testRegisterErrorMapping() async {
        let cases: [(Int, String, SignupError)] = [
            (409, #"{"error":"OperationFailed"}"#, .emailTaken),
            (404, #"{"error":"INVITE_NOT_FOUND"}"#, .invite(.notFound)),
            (410, #"{"error":"INVITE_EXPIRED"}"#, .invite(.expired)),
            (409, #"{"error":"INVITE_ALREADY_CLAIMED"}"#, .uncertain),
            (400, #"{"error":"CompromisedPassword"}"#, .weakPassword),
            (501, #"{"error":"INVITE_PROVISIONING_UNAVAILABLE"}"#, .provisioningUnavailable),
            (429, "{}", .rateLimited),
            (200, "{}", .invalidResponse),
        ]
        for (status, body, expected) in cases {
            SignupResponses.shared.set { _, _ in (status, body) }
            do { _ = try await api.register(email: "a@b.co", password: "secret-pass", username: "ayse", inviteCode: approvalCode); XCTFail("expected \(expected)") }
            catch { XCTAssertEqual(error as? SignupError, expected, "\(status) \(body)") }
        }
    }

    func testSignupAvailableOnOldAndNewServices() async throws {
        SignupResponses.shared.set { _, _ in (200, #"{"enabled":true}"#) }
        let open = try await api.signupAvailable()
        XCTAssertTrue(open)
        XCTAssertEqual(SignupResponses.shared.requests.first?.0.url?.path, "/rooms-access/v1/auth/signup")
        SignupResponses.shared.set { _, _ in (200, #"{"enabled":false}"#) }
        let closed = try await api.signupAvailable()
        XCTAssertFalse(closed)
        SignupResponses.shared.set { _, _ in (404, "") }
        let old = try await api.signupAvailable()
        XCTAssertFalse(old)
    }

    func testInputChecksMatchTheService() {
        XCTAssertEqual(SignupInput.email("  a@b.co "), "a@b.co")
        XCTAssertNil(SignupInput.email("not-an-email"))
        XCTAssertEqual(SignupInput.username(" Ayşe_1.k-2 "), "Ayşe_1.k-2")
        XCTAssertNil(SignupInput.username("a")); XCTAssertNil(SignupInput.username("with space")); XCTAssertNil(SignupInput.username(String(repeating: "x", count: 33)))
        XCTAssertFalse(SignupInput.password("1234567")); XCTAssertTrue(SignupInput.password("12345678"))
    }
}

// MARK: State machine

private final class MemoryStore: SignupRecordStore, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    var failSaves = false
    init(_ data: Data? = nil) { self.data = data }
    var stored: Data? { lock.lock(); defer { lock.unlock() }; return data }
    func load() throws -> Data? { lock.lock(); defer { lock.unlock() }; return data }
    func save(_ data: Data) throws { lock.lock(); defer { lock.unlock() }; if failSaves { throw SignupError.unavailable }; self.data = data }
    func clear() { lock.lock(); defer { lock.unlock() }; data = nil }
}

private final class FakeService: SignupService, @unchecked Sendable {
    private let lock = NSLock()
    var requestResults: [Result<SignupTicket, SignupError>] = []
    var polls: [Result<SignupPoll, SignupError>] = []
    var registerResult: Result<String, SignupError> = .success("token-1")
    private(set) var calls: [String] = []
    private func log(_ call: String) { lock.lock(); calls.append(call); lock.unlock() }
    func requestSignup(email: String, username: String) async throws -> SignupTicket { log("request \(email)"); return try requestResults.removeFirst().get() }
    func signupStatus(requestId: String, pollSecret: String) async throws -> SignupPoll { log("poll \(requestId)"); return try polls.removeFirst().get() }
    func cancelSignup(requestId: String, pollSecret: String) async throws { log("cancel \(requestId)") }
    func register(email: String, password: String, username: String, inviteCode: String) async throws -> String {
        log("register \(email) \(password) \(username) \(inviteCode)"); return try registerResult.get()
    }
}

final class PendingSignupTests: XCTestCase {
    private let origin = URL(string: "https://rooms.test")!
    private let ticket = SignupTicket(requestId: requestId, pollSecret: pollSecret)
    private let other = SignupTicket(requestId: String(repeating: "b2", count: 16), pollSecret: String(repeating: "T", count: 43))
    private func poll(_ status: SignupStatus, code: String? = nil) -> Result<SignupPoll, SignupError> {
        .success(SignupPoll(status: status, inviteCode: code, createdAt: "2026-10-24T08:00:00Z", expiresAt: nil))
    }
    private func waiting(_ progress: SignupProgress) -> PendingSignupSnapshot? { if case .waiting(let s) = progress { s } else { nil } }

    func testPendingThenApprovedRegistersAutomaticallyAndForgetsEverything() async throws {
        let store = MemoryStore(), service = FakeService()
        service.requestResults = [.success(ticket)]; service.polls = [poll(.pending), poll(.approved, code: approvalCode)]
        let broker = PendingSignupBroker(origin: origin, store: store, service: service)
        let sent = try await broker.request(email: "a@b.co", password: "secret-pass", username: "ayse")
        XCTAssertEqual(sent.phase, .pending); XCTAssertTrue(sent.persisted); XCTAssertTrue(sent.passwordKnown)
        let stored = String(decoding: try XCTUnwrap(store.stored), as: UTF8.self)
        XCTAssertTrue(stored.contains(pollSecret)); XCTAssertFalse(stored.contains("secret-pass"), "the password never reaches the Keychain")

        let first = await broker.check()
        XCTAssertEqual(waiting(first)?.phase, .pending)
        let second = await broker.check()
        XCTAssertEqual(second, .registered(token: "token-1", email: "a@b.co"))
        XCTAssertTrue(service.calls.contains("register a@b.co secret-pass ayse \(approvalCode)"))
        XCTAssertNil(store.stored)
        let left = await broker.snapshot()
        XCTAssertNil(left)
    }

    func testOldServerCodeIsStoredOnFirstApprovalAndNeverPolledAgain() async throws {
        let store = MemoryStore(), service = FakeService()
        service.requestResults = [.success(ticket)]; service.polls = [poll(.approved, code: approvalCode)]
        let first = PendingSignupBroker(origin: origin, store: store, service: service)
        _ = try await first.request(email: "a@b.co", password: "secret-pass", username: "ayse")
        // Registration fails once (network); the code stays on the phone, the password is dropped.
        service.registerResult = .failure(.unavailable)
        let failed = waiting(await first.check())
        XCTAssertEqual(failed?.ready, true); XCTAssertEqual(failed?.passwordKnown, false); XCTAssertNotNil(failed?.error)
        XCTAssertTrue(String(decoding: try XCTUnwrap(store.stored), as: UTF8.self).contains(approvalCode))

        // App restart: an older service would now answer `issued`, so it must not be asked at all.
        let polls = service.calls.filter { $0.hasPrefix("poll") }.count
        let restarted = PendingSignupBroker(origin: origin, store: store, service: service)
        let shown = waiting(await restarted.check())
        XCTAssertEqual(shown?.phase, .approved); XCTAssertEqual(shown?.ready, true); XCTAssertEqual(shown?.passwordKnown, false)
        XCTAssertEqual(service.calls.filter { $0.hasPrefix("poll") }.count, polls)

        service.registerResult = .success("token-2")
        let done = try await restarted.complete(email: nil, password: "secret-pass")
        XCTAssertEqual(done, .registered(token: "token-2", email: "a@b.co"))
        XCTAssertNil(store.stored)
    }

    func testThreeNotFoundInARowCloseTheRequestAndOneAnswerResetsTheCount() async throws {
        let service = FakeService()
        service.requestResults = [.success(ticket)]
        service.polls = [.failure(.requestNotFound), .failure(.requestNotFound), poll(.pending), .failure(.requestNotFound), .failure(.requestNotFound), .failure(.requestNotFound)]
        let broker = PendingSignupBroker(origin: origin, store: MemoryStore(), service: service)
        _ = try await broker.request(email: "a@b.co", password: "secret-pass", username: "ayse")
        var phases: [SignupPhase] = []
        for _ in 0..<6 { phases.append(waiting(await broker.check())?.phase ?? .unknown) }
        XCTAssertEqual(phases, [.unknown, .unknown, .pending, .unknown, .unknown, .closed])
        // Closed is final: no more polls.
        _ = await broker.check()
        XCTAssertEqual(service.calls.filter { $0.hasPrefix("poll") }.count, 6)
    }

    func testRejectedExpiredAndIssuedStopWaiting() async throws {
        for status in [SignupStatus.rejected, .expired, .issued] {
            let service = FakeService()
            service.requestResults = [.success(ticket)]; service.polls = [poll(status)]
            let broker = PendingSignupBroker(origin: origin, store: MemoryStore(), service: service)
            _ = try await broker.request(email: "a@b.co", password: "secret-pass", username: "ayse")
            let shown = waiting(await broker.check())
            XCTAssertEqual(shown?.phase.rawValue, status.rawValue); XCTAssertEqual(shown?.phase.waiting, false); XCTAssertEqual(shown?.ready, false)
        }
    }

    func testNewRequestWithdrawsTheOldOneAndSameEmailConflictRetriesOnce() async throws {
        let service = FakeService()
        service.requestResults = [.success(ticket), .success(other)]
        let broker = PendingSignupBroker(origin: origin, store: MemoryStore(), service: service)
        _ = try await broker.request(email: "a@b.co", password: "secret-pass", username: "ayse")
        _ = try await broker.request(email: "c@d.co", password: "secret-pass", username: "ayse")
        XCTAssertEqual(service.calls, ["request a@b.co", "request c@d.co", "cancel \(requestId)"])

        // Same address again: the service answers 409 while the old request is open.
        let retry = FakeService()
        retry.requestResults = [.success(ticket), .failure(.alreadyRequested), .success(other)]
        let again = PendingSignupBroker(origin: origin, store: MemoryStore(), service: retry)
        _ = try await again.request(email: "a@b.co", password: "secret-pass", username: "ayse")
        let replaced = try await again.request(email: "A@b.co", password: "secret-pass", username: "ayse2")
        XCTAssertEqual(retry.calls, ["request a@b.co", "request A@b.co", "cancel \(requestId)", "request A@b.co"])
        XCTAssertEqual(replaced.username, "ayse2")

        // A different address with a 409 is not retried (it belongs to someone else's open request).
        let foreign = FakeService()
        foreign.requestResults = [.failure(.alreadyRequested)]
        let third = PendingSignupBroker(origin: origin, store: MemoryStore(), service: foreign)
        do { _ = try await third.request(email: "x@y.co", password: "secret-pass", username: "ayse"); XCTFail("expected 409") }
        catch { XCTAssertEqual(error as? SignupError, .alreadyRequested) }
        XCTAssertEqual(foreign.calls, ["request x@y.co"])
    }

    func testCancelWithdrawsAndForgets() async throws {
        let store = MemoryStore(), service = FakeService()
        service.requestResults = [.success(ticket)]
        let broker = PendingSignupBroker(origin: origin, store: store, service: service)
        _ = try await broker.request(email: "a@b.co", password: "secret-pass", username: "ayse")
        await broker.cancel()
        XCTAssertEqual(service.calls.last, "cancel \(requestId)")
        XCTAssertNil(store.stored)
        let progress = await broker.check()
        XCTAssertEqual(progress, .none)
    }

    func testKeychainFailureIsReportedAndForeignOrBrokenRecordsAreDropped() async throws {
        let failing = MemoryStore(); failing.failSaves = true
        let service = FakeService(); service.requestResults = [.success(ticket)]
        let broker = PendingSignupBroker(origin: origin, store: failing, service: service)
        let sent = try await broker.request(email: "a@b.co", password: "secret-pass", username: "ayse")
        XCTAssertFalse(sent.persisted)

        let record = SignupRecord(origin: "https://other.test", requestId: requestId, pollSecret: pollSecret, email: "a@b.co", username: "ayse", createdAt: nil, inviteCode: nil)
        let foreign = MemoryStore(try JSONEncoder().encode(record))
        let snapshot = await PendingSignupBroker(origin: origin, store: foreign, service: FakeService()).snapshot()
        XCTAssertNil(snapshot); XCTAssertNil(foreign.stored)
        let broken = MemoryStore(Data("{\"version\":1}".utf8))
        let none = await PendingSignupBroker(origin: origin, store: broken, service: FakeService()).snapshot()
        XCTAssertNil(none); XCTAssertNil(broken.stored)
    }

    func testCompleteWithoutApprovalIsRefused() async throws {
        let service = FakeService(); service.requestResults = [.success(ticket)]
        let broker = PendingSignupBroker(origin: origin, store: MemoryStore(), service: service)
        _ = try await broker.request(email: "a@b.co", password: "secret-pass", username: "ayse")
        do { _ = try await broker.complete(email: nil, password: "secret-pass"); XCTFail("expected error") }
        catch { XCTAssertEqual(error as? SignupError, .requestNotFound) }
        XCTAssertFalse(service.calls.contains { $0.hasPrefix("register") })
    }

    func testPollBackoff() {
        XCTAssertEqual(SignupPollSchedule.delay(afterFailures: 0), 30)
        XCTAssertEqual(SignupPollSchedule.delay(afterFailures: 1), 60)
        XCTAssertEqual(SignupPollSchedule.delay(afterFailures: 2), 120)
        XCTAssertEqual(SignupPollSchedule.delay(afterFailures: 9), 300)
    }
}
