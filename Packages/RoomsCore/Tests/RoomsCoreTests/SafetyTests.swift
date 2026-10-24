import Foundation
import XCTest
@testable import RoomsCore

private struct SeenRequest: Sendable { let method: String; let path: String; let token: String?; let body: Data }
private final class SafetyResponses: @unchecked Sendable {
    static let shared = SafetyResponses()
    private let lock = NSLock()
    private var handler: @Sendable (SeenRequest) -> (Int, Data) = { _ in (503, Data()) }
    private var seen: [SeenRequest] = []
    func set(_ handler: @escaping @Sendable (SeenRequest) -> (Int, Data)) { lock.lock(); self.handler = handler; seen = []; lock.unlock() }
    func reply(_ request: SeenRequest) -> (Int, Data) { lock.lock(); let handler = handler; seen.append(request); lock.unlock(); return handler(request) }
    var requests: [SeenRequest] { lock.lock(); defer { lock.unlock() }; return seen }
}
private final class SafetyStub: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body = request.httpBody ?? request.httpBodyStream.map { stream -> Data in
            stream.open(); defer { stream.close() }; var data = Data(); var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: 1024); if n <= 0 { break }; data.append(contentsOf: buffer.prefix(n)) }; return data
        } ?? Data()
        let seen = SeenRequest(method: request.httpMethod ?? "", path: request.url?.path ?? "", token: request.value(forHTTPHeaderField: "x-session-token"), body: body)
        let (status, data) = SafetyResponses.shared.reply(seen)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class SafetyTests: XCTestCase {
    private func api() -> APIClient {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [SafetyStub.self]
        return APIClient(origin: URL(string: "https://example.test")!, token: "tok", session: URLSession(configuration: config))
    }
    private func json(_ text: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) }
    private func body(_ request: SeenRequest) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: request.body) }

    func testBlockUsesStoatEndpointWithSessionToken() async throws {
        SafetyResponses.shared.set { _ in (204, Data()) }
        try await api().block(id: "01PEER")
        let sent = try XCTUnwrap(SafetyResponses.shared.requests.first)
        XCTAssertEqual(sent.method, "PUT"); XCTAssertEqual(sent.path, "/api/users/01PEER/block"); XCTAssertEqual(sent.token, "tok")
        try await api().unblock(id: "01PEER")
        XCTAssertEqual(SafetyResponses.shared.requests.last?.method, "DELETE")
        XCTAssertEqual(SafetyResponses.shared.requests.last?.path, "/api/users/01PEER/block")
    }
    func testIDsAreValidatedBeforeAnyRequest() async {
        SafetyResponses.shared.set { _ in (204, Data()) }
        do { try await api().block(id: "../etc"); XCTFail("accepted a bad id") } catch {}
        do { try await api().reportMessage(id: "a/b", reason: .spam); XCTFail("accepted a bad id") } catch {}
        do { try await api().reportUser(id: "", reason: .spam); XCTFail("accepted a bad id") } catch {}
        XCTAssertTrue(SafetyResponses.shared.requests.isEmpty)
    }
    func testReportMessageBodyMatchesStoatSafetyReport() async throws {
        SafetyResponses.shared.set { _ in (204, Data()) }
        try await api().reportMessage(id: "01MSG", reason: .harassment, context: "  tekrar tekrar yazıyor \n")
        let sent = try XCTUnwrap(SafetyResponses.shared.requests.first)
        XCTAssertEqual(sent.method, "POST"); XCTAssertEqual(sent.path, "/api/safety/report")
        XCTAssertEqual(try body(sent), try json(#"{"content":{"type":"Message","id":"01MSG","report_reason":"Harassment"},"additional_context":"tekrar tekrar yazıyor"}"#))
    }
    func testReportWithoutNoteOmitsContextAndCapsLongNotes() async throws {
        SafetyResponses.shared.set { _ in (204, Data()) }
        try await api().reportMessage(id: "01MSG", reason: .other)
        XCTAssertEqual(try body(XCTUnwrap(SafetyResponses.shared.requests.first)), try json(#"{"content":{"type":"Message","id":"01MSG","report_reason":"NoneSpecified"}}"#))
        try await api().reportMessage(id: "01MSG", reason: .spam, context: String(repeating: "a", count: 1500))
        XCTAssertEqual(try body(XCTUnwrap(SafetyResponses.shared.requests.last))["additional_context"].string?.count, 1000)
    }
    func testReportUserMapsToStoatUserReasonsAndKeepsTheChosenOneInTheNote() async throws {
        SafetyResponses.shared.set { _ in (204, Data()) }
        try await api().reportUser(id: "01PEER", reason: .spam)
        XCTAssertEqual(try body(XCTUnwrap(SafetyResponses.shared.requests.last)), try json(#"{"content":{"type":"User","id":"01PEER","report_reason":"UnsolicitedSpam"}}"#))
        try await api().reportUser(id: "01PEER", reason: .harassment, context: "DM'den yazdı")
        XCTAssertEqual(try body(XCTUnwrap(SafetyResponses.shared.requests.last)), try json(#"{"content":{"type":"User","id":"01PEER","report_reason":"NoneSpecified"},"additional_context":"[Harassment] DM'den yazdı"}"#))
        for reason in SafetyReportReason.allCases {
            XCTAssertTrue(["UnsolicitedSpam", "SpamAbuse", "NoneSpecified"].contains(reason.userValue), "\(reason) has no Stoat user reason")
        }
    }
    func testReportFailureSurfacesTheServerRefusal() async {
        SafetyResponses.shared.set { _ in (403, Data()) }
        do { try await api().reportMessage(id: "01MSG", reason: .spam); XCTFail("403 swallowed") } catch { XCTAssertEqual(error as? RoomsError, .denied) }
        SafetyResponses.shared.set { _ in (429, Data()) }
        do { try await api().reportMessage(id: "01MSG", reason: .spam); XCTFail("429 swallowed") } catch { XCTAssertEqual(error as? RoomsError, .rateLimited) }
    }
    func testBlockedIDsKeepOnlyWhatThisAccountBlocked() async throws {
        SafetyResponses.shared.set { _ in (200, Data(#"{"_id":"me","relations":[{"_id":"a","status":"Blocked"},{"_id":"b","status":"BlockedOther"},{"_id":"c","status":"Friend"},{"_id":"../x","status":"Blocked"}]}"#.utf8)) }
        let ids = try await api().blockedUserIDs()
        XCTAssertEqual(ids, ["a"])
        XCTAssertEqual(SafetyResponses.shared.requests.first?.path, "/api/users/@me")
    }

    // MARK: ManageMessages (desktop `moderates`)
    private func serve(channel: String, member: String? = nil, privileged: Bool = false, roleBits: Int = 8_388_608) {
        SafetyResponses.shared.set { request in
            switch request.path {
            case "/api/channels/ch": return (200, Data(channel.utf8))
            case "/api/users/@me": return (200, Data(#"{"_id":"me","privileged":\#(privileged)}"#.utf8))
            case "/api/servers/srv": return (200, Data(#"{"_id":"srv","owner":"own","default_permissions":3222274048,"roles":{"mod":{"name":"Mod","rank":1,"permissions":{"a":\#(roleBits),"d":0}}}}"#.utf8))
            case "/api/servers/srv/members/me": return member.map { (200, Data($0.utf8)) } ?? (404, Data())
            default: return (404, Data())
            }
        }
    }
    func testModeratorRoleWithManageMessagesMayDeleteOthers() async throws {
        let ch = #"{"_id":"ch","server":"srv","channel_type":"TextChannel"}"#
        serve(channel: ch, member: #"{"_id":{"server":"srv","user":"me"},"roles":["mod"]}"#)
        let allowed = try await api().canManageMessages(channelID: "ch", userID: "me")
        XCTAssertTrue(allowed)
        serve(channel: ch, member: #"{"_id":{"server":"srv","user":"me"},"roles":[]}"#)
        let plain = try await api().canManageMessages(channelID: "ch", userID: "me")
        XCTAssertFalse(plain, "default member permissions do not include ManageMessages")
    }
    func testChannelOverrideCanRevokeManageMessages() async throws {
        let ch = #"{"_id":"ch","server":"srv","channel_type":"TextChannel","role_permissions":{"mod":{"a":0,"d":8388608}}}"#
        serve(channel: ch, member: #"{"_id":{"server":"srv","user":"me"},"roles":["mod"]}"#)
        let allowed = try await api().canManageMessages(channelID: "ch", userID: "me")
        XCTAssertFalse(allowed)
    }
    func testOwnerAndPrivilegedAccountsModerateWithoutMembership() async throws {
        let ch = #"{"_id":"ch","server":"srv","channel_type":"TextChannel"}"#
        serve(channel: ch, privileged: true)
        let privileged = try await api().canManageMessages(channelID: "ch", userID: "me")
        XCTAssertTrue(privileged)
        SafetyResponses.shared.set { request in
            switch request.path {
            case "/api/channels/ch": return (200, Data(ch.utf8))
            case "/api/users/@me": return (200, Data(#"{"_id":"own"}"#.utf8))
            case "/api/servers/srv": return (200, Data(#"{"_id":"srv","owner":"own","default_permissions":0,"roles":{}}"#.utf8))
            default: return (404, Data())
            }
        }
        let owner = try await api().canManageMessages(channelID: "ch", userID: "own")
        XCTAssertTrue(owner)
    }
    func testDirectMessagesNeverGrantModeration() async throws {
        serve(channel: #"{"_id":"ch","channel_type":"DirectMessage","recipients":["me","you"]}"#)
        let allowed = try await api().canManageMessages(channelID: "ch", userID: "me")
        XCTAssertFalse(allowed)
        XCTAssertEqual(SafetyResponses.shared.requests.map(\.path), ["/api/channels/ch"], "no permission lookups for a DM")
    }
    func testMismatchedChannelOrUserIsRejected() async {
        serve(channel: #"{"_id":"other","server":"srv","channel_type":"TextChannel"}"#)
        do { _ = try await api().canManageMessages(channelID: "ch", userID: "me"); XCTFail("accepted another channel") } catch { XCTAssertEqual(error as? RoomsError, .invalidResponse) }
    }

    // MARK: SafetyCenter
    @MainActor func testCenterHidesAfterBlockAndForgetsOnAccountSwitch() async throws {
        let client = api()
        SafetyResponses.shared.set { request in
            switch (request.method, request.path) {
            case ("GET", "/api/users/@me"): return (200, Data(#"{"_id":"me","relations":[{"_id":"old","status":"Blocked"}]}"#.utf8))
            case ("PUT", "/api/users/new/block"): return (204, Data())
            default: return (404, Data())
            }
        }
        let center = SafetyCenter(); center.attach { client }
        await center.ensureLoaded()
        XCTAssertTrue(center.isBlocked("old")); XCTAssertFalse(center.isBlocked("new"))
        try await center.block("new")
        XCTAssertTrue(center.isBlocked("new"))
        center.use(userID: "someone-else")
        XCTAssertFalse(center.isBlocked("old"), "another account starts with nothing cached")
    }
    @MainActor func testCenterKeepsStateWhenTheServerRefusesTheBlock() async {
        let client = api()
        SafetyResponses.shared.set { _ in (403, Data()) }
        let center = SafetyCenter(); center.attach { client }
        do { try await center.block("x"); XCTFail("403 swallowed") } catch {}
        XCTAssertFalse(center.isBlocked("x"))
    }
}
