import Foundation
import XCTest
@testable import RoomsCore

private final class LoginResponses: @unchecked Sendable {
    static let shared = LoginResponses()
    private let lock = NSLock()
    private var handler: @Sendable (URLRequest, Data) -> (Int, String) = { _, _ in (503, "") }
    private var seen: [(URLRequest, Data)] = []
    func set(_ handler: @escaping @Sendable (URLRequest, Data) -> (Int, String)) { lock.lock(); self.handler = handler; seen = []; lock.unlock() }
    func reply(_ request: URLRequest, body: Data) -> (Int, String) { lock.lock(); seen.append((request, body)); let handler = handler; lock.unlock(); return handler(request, body) }
    var requests: [(URLRequest, Data)] { lock.lock(); defer { lock.unlock() }; return seen }
}
private final class LoginStub: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body = request.httpBody ?? request.httpBodyStream.map { stream -> Data in
            stream.open(); defer { stream.close() }; var data = Data(); var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: 1024); if n <= 0 { break }; data.append(contentsOf: buffer.prefix(n)) }; return data
        } ?? Data()
        let (status, text) = LoginResponses.shared.reply(request, body: body)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class LoginTests: XCTestCase {
    private let origin = URL(string: "https://rooms.test")!
    private let hex = String(repeating: "ab", count: 32)

    private var stubbed: URLSession { let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [LoginStub.self]; return URLSession(configuration: config) }
    private func json(_ data: Data) -> JSONValue { (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .null }

    func testPasswordStepSuccessSendsCredentialsAndReturnsToken() async throws {
        LoginResponses.shared.set { _, _ in (200, #"{"result":"Success","_id":"s1","user_id":"u1","token":"tok-1","name":"ROOMS iPhone"}"#) }
        let step = try await APIClient.loginStep(origin: origin, email: "a@b.c", password: "pw", session: stubbed)
        XCTAssertEqual(step, .success(token: "tok-1"))
        let sent = try XCTUnwrap(LoginResponses.shared.requests.first)
        XCTAssertEqual(sent.0.url?.path, "/api/auth/session/login"); XCTAssertEqual(sent.0.httpMethod, "POST")
        XCTAssertEqual(json(sent.1)["email"].string, "a@b.c"); XCTAssertEqual(json(sent.1)["password"].string, "pw")
        XCTAssertNil(sent.0.value(forHTTPHeaderField: "x-session-token"))
    }

    func testPasswordStepReturnsMFATicketWithMethods() async throws {
        LoginResponses.shared.set { _, _ in (200, #"{"result":"MFA","ticket":"tk","allowed_methods":["Totp","Recovery","Unknown"]}"#) }
        let step = try await APIClient.loginStep(origin: origin, email: "a@b.c", password: "pw", session: stubbed)
        XCTAssertEqual(step, .mfa(ticket: "tk", methods: [.totp, .recovery]))
    }

    func testMFAWithOnlyPasswordMethodIsUnsupported() async {
        LoginResponses.shared.set { _, _ in (200, #"{"result":"MFA","ticket":"tk","allowed_methods":["Password"]}"#) }
        do { _ = try await APIClient.loginStep(origin: origin, email: "a@b.c", password: "pw", session: stubbed); XCTFail("expected error") }
        catch { XCTAssertEqual(error as? LoginError, .mfaUnsupported) }
    }

    func testDisabledAccountAndMalformedReplies() async {
        LoginResponses.shared.set { _, _ in (200, #"{"result":"Disabled","user_id":"u1"}"#) }
        do { _ = try await APIClient.loginStep(origin: origin, email: "a@b.c", password: "pw", session: stubbed); XCTFail("expected error") }
        catch { XCTAssertEqual(error as? LoginError, .accountDisabled) }
        LoginResponses.shared.set { _, _ in (200, #"{"result":"MFA"}"#) }
        do { _ = try await APIClient.loginStep(origin: origin, email: "a@b.c", password: "pw", session: stubbed); XCTFail("expected error") }
        catch { XCTAssertEqual(error as? LoginError, .invalidResponse) }
    }

    func testPasswordStepErrorMapping() async {
        let cases: [(Int, String, LoginError)] = [
            (401, #"{"type":"InvalidCredentials"}"#, .invalidCredentials),
            (401, #"{"type":"UnverifiedAccount"}"#, .unverifiedAccount),
            (403, #"{"type":"LockedOut"}"#, .refused),
            (403, #"{"type":"Disabled"}"#, .accountDisabled),
            (429, "{}", .rateLimited),
            (502, "", .unavailable),
        ]
        for (status, body, expected) in cases {
            LoginResponses.shared.set { _, _ in (status, body) }
            do { _ = try await APIClient.loginStep(origin: origin, email: "a@b.c", password: "pw", session: stubbed); XCTFail("expected error for \(status)") }
            catch { XCTAssertEqual(error as? LoginError, expected, "status \(status) \(body)") }
        }
    }

    func testTOTPSecondStepSendsTicketAndNormalizedCode() async throws {
        LoginResponses.shared.set { _, _ in (200, #"{"result":"Success","token":"tok-2"}"#) }
        let token = try await APIClient.completeMFA(origin: origin, ticket: "tk", response: .totp("123 456"), session: stubbed)
        XCTAssertEqual(token, "tok-2")
        let body = json(try XCTUnwrap(LoginResponses.shared.requests.first).1)
        XCTAssertEqual(body["mfa_ticket"].string, "tk"); XCTAssertEqual(body["mfa_response"]["totp_code"].string, "123456")
        XCTAssertNil(body["email"].string); XCTAssertNil(body["password"].string)
    }

    func testRecoveryCodeSecondStep() async throws {
        LoginResponses.shared.set { _, _ in (200, #"{"result":"Success","token":"tok-3"}"#) }
        let token = try await APIClient.completeMFA(origin: origin, ticket: "tk", response: .recovery("  abcd-1234  "), session: stubbed)
        XCTAssertEqual(token, "tok-3")
        XCTAssertEqual(json(try XCTUnwrap(LoginResponses.shared.requests.first).1)["mfa_response"]["recovery_code"].string, "abcd-1234")
    }

    func testSecondStepRejectsBadFormatWithoutCallingServerAndMapsWrongCode() async {
        LoginResponses.shared.set { _, _ in (200, #"{"token":"x"}"#) }
        for response in [MFAResponse.totp("12"), .totp("12345a"), .totp(""), .recovery("   ")] {
            do { _ = try await APIClient.completeMFA(origin: origin, ticket: "tk", response: response, session: stubbed); XCTFail("expected error") }
            catch { XCTAssertEqual(error as? LoginError, .invalidCodeFormat) }
        }
        XCTAssertTrue(LoginResponses.shared.requests.isEmpty)
        LoginResponses.shared.set { _, _ in (401, #"{"type":"InvalidToken"}"#) }
        do { _ = try await APIClient.completeMFA(origin: origin, ticket: "tk", response: .totp("123456"), session: stubbed); XCTFail("expected error") }
        catch { XCTAssertEqual(error as? LoginError, .invalidMFACode) }
    }

    func testSecondStepWithoutTokenIsInvalidResponse() async {
        LoginResponses.shared.set { _, _ in (200, #"{"result":"MFA","ticket":"again","allowed_methods":["Totp"]}"#) }
        do { _ = try await APIClient.completeMFA(origin: origin, ticket: "tk", response: .totp("123456"), session: stubbed); XCTFail("expected error") }
        catch { XCTAssertEqual(error as? LoginError, .invalidResponse) }
    }

    // MARK: invites

    func testInviteInputAcceptsDesktopForms() throws {
        XCTAssertEqual(try InviteInput.code(from: hex, origin: origin), hex)
        XCTAssertEqual(try InviteInput.code(from: "  AbC_12-x \n", origin: origin), "AbC_12-x")
        XCTAssertEqual(try InviteInput.code(from: "https://rooms.test/davet/\(hex)", origin: origin), hex)
        XCTAssertEqual(try InviteInput.code(from: "<https://ROOMS.test/davet/\(hex)/?utm=1#x>", origin: origin), hex)
        XCTAssertEqual(try InviteInput.code(from: "rooms://invite?server=https%3A%2F%2Frooms.test&code=\(hex)", origin: origin), hex)
    }

    func testInviteInputRejectsForeignAndMalformedInput() {
        func fails(_ raw: String, _ expected: InviteError, line: UInt = #line) {
            XCTAssertThrowsError(try InviteInput.code(from: raw, origin: origin), line: line) { XCTAssertEqual($0 as? InviteError, expected, line: line) }
        }
        fails("https://evil.test/davet/\(hex)", .otherServer)
        fails("rooms://invite?server=https%3A%2F%2Fevil.test&code=\(hex)", .otherServer)
        fails("https://rooms.test/davet/short", .invalidLink)
        fails("https://rooms.test/other/\(hex)", .invalidLink)
        fails("https://user:pw@rooms.test/davet/\(hex)", .invalidLink)
        fails("ftp://rooms.test/davet/\(hex)", .invalidLink)
        fails("rooms://invite?server=https%3A%2F%2Frooms.test", .invalidLink)
        fails("two words", .invalidLink)
        fails("", .invalidLink)
        fails("x", .invalidLink)
    }

    private func api() throws -> APIClient {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [LoginStub.self]
        return APIClient(origin: origin, token: "sess", session: URLSession(configuration: config))
    }

    func testBrokerInviteJoinUsesBearerAndReadsCommunityName() async throws {
        LoginResponses.shared.set { _, _ in (200, #"{"code":"c","space":{"id":"s1","name":"Tayfa Evi"},"channel":null,"expiresAt":"2026-11-01T00:00:00Z"}"#) }
        let result = try await api().redeemInvite(code: hex)
        XCTAssertEqual(result.communityName, "Tayfa Evi")
        let sent = try XCTUnwrap(LoginResponses.shared.requests.first).0
        XCTAssertEqual(sent.url?.path, "/rooms-access/v1/auth/invites/\(hex)/join"); XCTAssertEqual(sent.httpMethod, "POST")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Bearer sess")
    }

    func testUpstreamShortCodeUsesStoatEndpointAndSessionHeader() async throws {
        LoginResponses.shared.set { _, _ in (200, #"{"type":"Server","server":{"_id":"s1","name":"Eski Topluluk"},"channels":[]}"#) }
        let result = try await api().redeemInvite(code: "AbCdEf")
        XCTAssertEqual(result.communityName, "Eski Topluluk")
        let sent = try XCTUnwrap(LoginResponses.shared.requests.first).0
        XCTAssertEqual(sent.url?.path, "/api/invites/AbCdEf"); XCTAssertEqual(sent.value(forHTTPHeaderField: "x-session-token"), "sess")
        XCTAssertNil(sent.value(forHTTPHeaderField: "Authorization"))
    }

    func testInviteErrorMapping() async throws {
        let cases: [(Int, String, InviteError)] = [
            (404, #"{"error":"INVITE_NOT_FOUND"}"#, .notFound), (404, #"{"error":"INVITE_EXPIRED"}"#, .expired),
            (404, #"{"error":"INVITE_REVOKED"}"#, .revoked), (409, #"{"error":"INVITE_ALREADY_CLAIMED"}"#, .full),
            (403, #"{"error":"INVITE_UNAVAILABLE"}"#, .refused), (403, #"{"type":"Banned"}"#, .refused),
            (401, "{}", .sessionExpired), (429, "{}", .rateLimited), (500, "", .unavailable),
        ]
        for (status, body, expected) in cases {
            LoginResponses.shared.set { _, _ in (status, body) }
            do { _ = try await api().redeemInvite(code: hex); XCTFail("expected error for \(status) \(body)") }
            catch { XCTAssertEqual(error as? InviteError, expected, "status \(status) \(body)") }
        }
    }

    func testAlreadyInServerCountsAsSuccessAndSignedOutClientRefuses() async throws {
        LoginResponses.shared.set { _, _ in (409, #"{"type":"AlreadyInServer"}"#) }
        let result = try await api().redeemInvite(code: "AbCdEf")
        XCTAssertNil(result.communityName)
        let anonymous = APIClient(origin: origin)
        do { _ = try await anonymous.redeemInvite(code: hex); XCTFail("expected error") }
        catch { XCTAssertEqual(error as? InviteError, .sessionExpired) }
        do { _ = try await api().redeemInvite(code: "../x"); XCTFail("expected error") }
        catch { XCTAssertEqual(error as? InviteError, .invalidLink) }
    }
}
