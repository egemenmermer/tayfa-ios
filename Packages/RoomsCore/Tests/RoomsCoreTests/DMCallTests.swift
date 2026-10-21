import Foundation
import XCTest
@testable import RoomsCore

private final class CallResponses: @unchecked Sendable {
    static let shared = CallResponses()
    private let lock = NSLock()
    private var handler: @Sendable (URLRequest, Data) -> (Int, Data) = { _, _ in (503, Data()) }
    func set(_ handler: @escaping @Sendable (URLRequest, Data) -> (Int, Data)) { lock.lock(); self.handler = handler; lock.unlock() }
    func reply(_ request: URLRequest, body: Data) -> (Int, Data) { lock.lock(); let handler = handler; lock.unlock(); return handler(request, body) }
}
private final class CallStub: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body = request.httpBody ?? request.httpBodyStream.map { stream -> Data in
            stream.open(); defer { stream.close() }; var data = Data(); var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: 1024); if n <= 0 { break }; data.append(contentsOf: buffer.prefix(n)) }; return data
        } ?? Data()
        let (status, data) = CallResponses.shared.reply(request, body: body)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class DMCallTests: XCTestCase {
    private let callID = "3f2b8c1e-5d6a-4b7c-9e0f-112233445566"
    private func session(state: String = "ringing", reason: String = "null", id: String? = nil) -> String {
        #"{"id":"\#(id ?? callID)","dmId":"dm1","callerId":"ece","calleeId":"me","callerName":"Ece","calleeName":"Ben","mode":"video","state":"\#(state)","reason":\#(reason),"createdAt":1000,"acceptedAt":null,"expiresAt":46000}"#
    }
    private func api() throws -> APIClient {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [CallStub.self]
        return APIClient(origin: try EndpointPolicy.origin("https://rooms.test"), token: "test-session", session: URLSession(configuration: config))
    }

    func testSessionShapeRolesAndEndMessages() throws {
        let call = try JSONDecoder().decode(DMCallSession.self, from: Data(session().utf8)).validated()
        XCTAssertTrue(call.incoming(for: "me")); XCTAssertFalse(call.incoming(for: "ece"))
        XCTAssertEqual(call.peer(for: "me").name, "Ece"); XCTAssertEqual(call.peer(for: "ece").name, "Ben")
        XCTAssertTrue(call.ringing && call.active)
        let ended = try JSONDecoder().decode(DMCallSession.self, from: Data(session(state: "ended", reason: #""access-lost""#).utf8))
        XCTAssertEqual(ended.reason, .accessLost); XCTAssertFalse(ended.active)
        XCTAssertThrowsError(try JSONDecoder().decode(DMCallSession.self, from: Data(session(id: "not-a-uuid").utf8)).validated())
        XCTAssertEqual(DMCallSession.endMessage(.rejected), "Arama reddedildi.")
        XCTAssertEqual(DMCallSession.endMessage(.missed), "Arama yanıtlanmadı.")
        XCTAssertEqual(DMCallSession.endMessage(nil), "Görüşme sona erdi.")
        XCTAssertEqual(DMCallError(code: "DM_CALL_BUSY").localizedDescription, "Bu kişi başka bir aramada. Daha sonra tekrar dene.")
    }
    func testPollingBackoffMatchesDesktop() {
        XCTAssertEqual([1, 2, 3, 4, 5, 9].map(DMCallPolling.backoff), [6, 12, 24, 48, 60, 60])
        XCTAssertEqual(DMCallPolling.interval, 3)
    }
    func testRingToneIsALoopableWav() {
        let wav = DMCallRingTone.wav()
        XCTAssertEqual(String(decoding: wav.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(wav.count, 44 + DMCallRingTone.samples().count * 2)
        XCTAssertEqual(DMCallRingTone.samples().last, 0, "the loop ends in silence")
    }
    func testSignalingUsesBearerAndValidatesGrants() async throws {
        let id = callID, accepted = session(state: "accepted")
        CallResponses.shared.set { request, body in
            guard request.httpMethod == "POST", request.value(forHTTPHeaderField: "Authorization") == "Bearer test-session" else { return (401, Data(#"{"error":"AUTH_REQUIRED"}"#.utf8)) }
            let value = (try? JSONSerialization.jsonObject(with: body) as? [String: String]) ?? [:]
            switch request.url?.path {
            case "/rooms-access/v1/calls/poll": return value.isEmpty ? (200, Data(#"{"call":null}"#.utf8)) : (400, Data())
            case "/rooms-access/v1/calls/start": return value == ["dmId": "dm1", "mode": "audio"] ? (409, Data(#"{"error":"DM_CALL_BUSY","message":"busy"}"#.utf8)) : (400, Data())
            case "/rooms-access/v1/calls/respond": return value == ["callId": id, "action": "accept"] ? (200, Data(accepted.utf8)) : (400, Data())
            case "/rooms-access/v1/calls/grant":
                return (200, Data(#"{"serverUrl":"wss://rooms.test/livekit","roomName":"rooms-dm-call-\#(id)","token":"jwt","expiresAt":"2026-10-18T10:00:00.000Z"}"#.utf8))
            default: return (404, Data())
            }
        }
        let api = try api()
        let none = try await api.dmCallPoll()
        XCTAssertNil(none)
        do { _ = try await api.dmCallStart(dmID: "dm1", mode: .audio); XCTFail("expected a refusal") }
        catch let error as DMCallError { XCTAssertEqual(error.code, "DM_CALL_BUSY") }
        let call = try await api.dmCallRespond(callID: id, action: .accept)
        XCTAssertEqual(call.state, .accepted)
        let grant = try await api.dmCallGrant(callID: id)
        XCTAssertEqual(grant.roomName, "rooms-dm-call-\(id)")
        do { _ = try await api.dmCallGrant(callID: "3f2b8c1e-5d6a-4b7c-9e0f-000000000000"); XCTFail("a grant for another room must be refused") }
        catch let error as DMCallError { XCTAssertEqual(error.code, "DM_CALL_GRANT_INVALID") }
    }
    func testMissingServiceAndPlainMediaURLsAreRefused() async throws {
        let id = callID
        CallResponses.shared.set { request, _ in
            request.url?.path == "/rooms-access/v1/calls/grant"
                ? (200, Data(#"{"serverUrl":"ws://rooms.test/livekit","roomName":"rooms-dm-call-\#(id)","token":"jwt","expiresAt":"x"}"#.utf8))
                : (404, Data())
        }
        let api = try api()
        do { _ = try await api.dmCallPoll(); XCTFail("expected a refusal") }
        catch let error as DMCallError { XCTAssertEqual(error.localizedDescription, "Bu sunucuda özel arama servisi etkin değil.") }
        do { _ = try await api.dmCallGrant(callID: id); XCTFail("expected a refusal") }
        catch let error as DMCallError { XCTAssertEqual(error.code, "DM_CALL_GRANT_INVALID") }
    }
}
