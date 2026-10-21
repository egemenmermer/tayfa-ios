import Foundation
import XCTest
@testable import RoomsCore

private final class ModerationResponses: @unchecked Sendable {
    static let shared = ModerationResponses()
    private let lock = NSLock()
    private var handler: @Sendable (URLRequest, Data) -> (Int, Data) = { _, _ in (503, Data()) }
    private var seen: [String] = []
    func set(_ handler: @escaping @Sendable (URLRequest, Data) -> (Int, Data)) { lock.lock(); self.handler = handler; seen = []; lock.unlock() }
    func reply(_ request: URLRequest, body: Data) -> (Int, Data) {
        lock.lock(); let handler = handler; seen.append("\(request.httpMethod ?? "") \(request.url?.path ?? "")"); lock.unlock()
        return handler(request, body)
    }
    var requests: [String] { lock.lock(); defer { lock.unlock() }; return seen }
}
private final class ModerationStub: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body = request.httpBody ?? request.httpBodyStream.map { stream -> Data in
            stream.open(); defer { stream.close() }; var data = Data(); var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: 1024); if n <= 0 { break }; data.append(contentsOf: buffer.prefix(n)) }; return data
        } ?? Data()
        let (status, data) = ModerationResponses.shared.reply(request, body: body)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class VoiceParityTests: XCTestCase {
    private func json(_ text: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) }
    private let move = 34_359_738_368.0
    private var server: String {
        // Members see, connect and speak; "mod" (rank 1) may move and kick; same-rank roles cancel ban.
        #"{"_id":"srv","owner":"own","default_permissions":3222274048,"roles":{"mod":{"name":"Mod","rank":1,"permissions":{"a":\#(Int(move) + 64),"d":0}},"#
            + #""allow":{"name":"A","rank":3,"permissions":{"a":128,"d":0}},"deny":{"name":"D","rank":3,"permissions":{"a":0,"d":128}}}}"#
    }
    private var channels: [JSONValue] {
        get throws {
            try [json(#"{"_id":"lobby","server":"srv","channel_type":"VoiceChannel"}"#),
                 json(#"{"_id":"quiet","server":"srv","channel_type":"VoiceChannel","role_permissions":{"mod":{"a":0,"d":\#(Int(move))}}}"#),
                 json(#"{"_id":"hidden","server":"srv","channel_type":"VoiceChannel","default_permissions":{"a":0,"d":1048576}}"#),
                 json(#"{"_id":"elsewhere","server":"other","channel_type":"VoiceChannel"}"#)]
        }
    }

    func testMoveSignalAcceptsOnlyTheServerShape() {
        XCTAssertEqual(MoveSignal.topic, "rooms-move-v1")
        XCTAssertEqual(MoveSignal.parse(Data(#"{"channelId":"room_2","by":"mod1"}"#.utf8)), .init(channelID: "room_2", by: "mod1"))
        XCTAssertEqual(MoveSignal.parse(Data(#"{"channelId":"room_2","by":"../x"}"#.utf8)), .init(channelID: "room_2", by: nil))
        XCTAssertNil(MoveSignal.parse(Data(#"{"channelId":"../etc"}"#.utf8)))
        XCTAssertNil(MoveSignal.parse(Data(#"{"channelId":42}"#.utf8)))
        XCTAssertNil(MoveSignal.parse(Data("not json".utf8)))
        XCTAssertNil(MoveSignal.parse(Data((#"{"channelId":"a","pad":""# + String(repeating: "x", count: 520) + #""}"#).utf8)))
    }
    func testViewerSummaryMatchesDesktop() {
        XCTAssertEqual(ScreenViewers.summary([]), "Henüz izleyen yok")
        XCTAssertEqual(ScreenViewers.summary(["Sen", "Ece"]), "2 kişi izliyor")
        XCTAssertEqual(ScreenViewers.summary(["Sen", "Ece"], named: true), "İzleyenler: Sen, Ece")
    }
    func testModerationRightsFollowChannelOverridesAndServerRoles() throws {
        let member = try json(#"{"_id":{"server":"srv","user":"me"},"roles":["mod","allow","deny"]}"#)
        let rights = try VoiceModerationPolicy.rights(userID: "me", privileged: false, server: json(server), member: member, channels: channels)
        XCTAssertEqual(rights.moveRooms, ["lobby"])
        XCTAssertTrue(rights.kick); XCTAssertFalse(rights.ban, "a same-rank denial wins")
        let rooms = [VoiceRoom(id: "lobby", name: "Lobi", community: "S"), VoiceRoom(id: "quiet", name: "Sessiz", community: "S")]
        XCTAssertEqual(rights.moveTargets(from: "quiet", among: rooms), [], "no MoveMembers in the source room")
        XCTAssertFalse(rights.applies(to: "own", me: "me")); XCTAssertFalse(rights.applies(to: "me", me: "me")); XCTAssertTrue(rights.applies(to: "ece", me: "me"))
        let owner = try VoiceModerationPolicy.rights(userID: "own", privileged: false, server: json(server), member: nil, channels: channels)
        XCTAssertEqual(owner.moveRooms, ["lobby", "quiet", "hidden"]); XCTAssertTrue(owner.ban)
        XCTAssertEqual(owner.moveTargets(from: "lobby", among: rooms).map(\.id), ["quiet"])
    }
    func testTimedOutMembersAndStrangersGetNothing() throws {
        let timedOut = try json(#"{"_id":{"server":"srv","user":"me"},"roles":["mod"],"timeout":"2999-01-01T00:00:00Z"}"#)
        let rights = try VoiceModerationPolicy.rights(userID: "me", privileged: false, server: json(server), member: timedOut, channels: channels)
        XCTAssertFalse(rights.any)
        XCTAssertFalse(try VoiceModerationPolicy.rights(userID: "me", privileged: false, server: json(server), member: nil, channels: channels).any)
        // Text access keeps its previous answers after the shared refactor.
        let access = try TextPermissionPolicy.evaluate(userID: "me", privileged: false, server: json(server), channel: channels[2], member: timedOut)
        XCTAssertEqual(access, .denied)
    }
    func testModerationCallsUseTheDesktopRoutes() async throws {
        ModerationResponses.shared.set { request, body in
            let path = request.url?.path ?? ""
            switch (request.httpMethod ?? "", path) {
            case ("GET", "/api/users/@me"): return (200, Data(#"{"_id":"me","username":"me"}"#.utf8))
            case ("GET", "/api/servers/srv"): return (200, Data(#"{"_id":"srv","owner":"own","default_permissions":3222274048,"roles":{"mod":{"name":"Mod","rank":1,"permissions":{"a":34359738432,"d":0}}}}"#.utf8))
            case ("GET", "/api/servers/srv/members/me"): return (200, Data(#"{"_id":{"server":"srv","user":"me"},"roles":["mod"]}"#.utf8))
            case ("GET", "/api/channels/lobby"): return (200, Data(#"{"_id":"lobby","server":"srv","channel_type":"VoiceChannel"}"#.utf8))
            case ("GET", "/api/channels/secret"): return (403, Data(#"{"type":"MissingPermission"}"#.utf8))
            case ("POST", "/rooms-access/v1/media/moderate"):
                guard request.value(forHTTPHeaderField: "Authorization") == "Bearer test-session",
                      let value = try? JSONSerialization.jsonObject(with: body) as? [String: String] else { return (400, Data()) }
                if value == ["channelId": "lobby", "userId": "ece", "action": "move", "targetChannelId": "games"] { return (200, Data(#"{"moved":true}"#.utf8)) }
                return (404, Data(#"{"error":"MEMBER_NOT_IN_ROOM"}"#.utf8))
            case ("DELETE", "/api/servers/srv/members/ece"):
                return request.value(forHTTPHeaderField: "x-session-token") == "test-session" ? (204, Data()) : (401, Data())
            case ("PUT", "/api/servers/srv/bans/ece"): return (403, Data(#"{"type":"NotElevated"}"#.utf8))
            default: return (500, Data())
            }
        }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ModerationStub.self]
        let api = APIClient(origin: try EndpointPolicy.origin("https://rooms.test"), token: "test-session", session: URLSession(configuration: config))
        let rights = try await api.voiceModerationRights(serverID: "srv", userID: "me", channelIDs: ["lobby", "secret"])
        XCTAssertEqual(rights.moveRooms, ["lobby"]); XCTAssertTrue(rights.kick); XCTAssertFalse(rights.ban)
        try await api.moderateVoice(channelID: "lobby", userID: "ece", action: .move(to: "games"))
        do { try await api.moderateVoice(channelID: "lobby", userID: "ece", action: .disconnect); XCTFail("expected a refusal") }
        catch let error as VoiceModerationError { XCTAssertEqual(error.localizedDescription, "Bu kişi artık bu odada değil.") }
        try await api.removeMember(serverID: "srv", userID: "ece")
        do { try await api.banMember(serverID: "srv", userID: "ece"); XCTFail("expected a refusal") }
        catch let error as VoiceModerationError { XCTAssertEqual(error.code, "NotElevated") }
        XCTAssertTrue(ModerationResponses.shared.requests.contains("PUT /api/servers/srv/bans/ece"))
    }
    @MainActor func testMicrophoneMemoryPersistsAndDefaultsMuted() throws {
        XCTAssertFalse(AudioPreferences().microphoneOn, "a first-ever join starts muted")
        let legacy = try JSONDecoder().decode(AudioPreferences.self, from: Data(#"{"noiseSuppression":true}"#.utf8))
        XCTAssertFalse(legacy.microphoneOn)
        let suite = "rooms-mic-tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let origin = try XCTUnwrap(URL(string: "https://rooms.test"))
        var prefs = AudioPreferences(); prefs.microphoneOn = true
        AudioPreferenceStore(defaults: defaults).save(prefs, origin: origin, userID: "me")
        XCTAssertTrue(AudioPreferenceStore(defaults: defaults).load(origin: origin, userID: "me").microphoneOn)
        XCTAssertFalse(AudioPreferenceStore(defaults: defaults).load(origin: origin, userID: "other").microphoneOn)
    }
}
