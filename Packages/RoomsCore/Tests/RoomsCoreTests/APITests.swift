import Foundation
import XCTest
@testable import RoomsCore

private final class Responses: @unchecked Sendable {
    static let shared = Responses()
    private let lock = NSLock()
    private var handler: @Sendable (URLRequest) -> (Int, Data) = { _ in (503, Data()) }
    func set(_ handler: @escaping @Sendable (URLRequest) -> (Int, Data)) { lock.lock(); self.handler = handler; lock.unlock() }
    func reply(_ request: URLRequest) -> (Int, Data) { lock.lock(); let handler = handler; lock.unlock(); return handler(request) }
}
private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, data) = Responses.shared.reply(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
private final class Seen: @unchecked Sendable {
    private let lock = NSLock(); private var items: [String] = []
    func add(_ value: String) { lock.lock(); items.append(value); lock.unlock() }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return items }
}
@MainActor final class APITests: XCTestCase {
    private func api() throws -> APIClient {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubURLProtocol.self]
        return APIClient(origin: try EndpointPolicy.origin("https://rooms.test"), token: "test-session", session: URLSession(configuration: config))
    }
    func testUserUsesExistingSessionHeader() async throws {
        Responses.shared.set { request in
            if request.url?.path == "/api/users/@me" && request.value(forHTTPHeaderField: "x-session-token") == "test-session" && request.value(forHTTPHeaderField: "Authorization") == nil {
                return (200, Data(#"{"_id":"user","username":"Friend","display_name":"Alex"}"#.utf8))
            }; return (403, Data())
        }
        let user = try await api().user(); XCTAssertEqual(user.name, "Alex")
    }
    func testGrantUsesBearerAndExistingChannelBody() async throws {
        Responses.shared.set { request in
            let body = request.httpBody ?? request.httpBodyStream.flatMap { stream -> Data? in
                stream.open(); defer { stream.close() }; var data = Data(); var buffer = [UInt8](repeating: 0, count: 1024)
                while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: 1024); if n <= 0 { break }; data.append(contentsOf: buffer.prefix(n)) }; return data
            } ?? Data()
            if request.url?.path == "/rooms-access/v1/media/grant" && request.value(forHTTPHeaderField: "Authorization") == "Bearer test-session" && String(data: body, encoding: .utf8)?.contains("channelId") == true {
                return (200, Data(#"{"roomName":"stoat-channel-c","serverUrl":"wss://rooms.test/livekit","token":"short-lived","expiresAt":"2026-10-13T18:00:00Z"}"#.utf8))
            }; return (403, Data())
        }
        let grant = try await api().grant(channel: "c"); XCTAssertEqual(grant.roomName, "stoat-channel-c")
    }
    func testProfileEditPatchesOwnAccountAndAvatarUsesTheAvatarsTag() async throws {
        let seen = Seen()
        Responses.shared.set { request in
            let path = request.url?.path ?? ""
            seen.add("\(request.httpMethod ?? "") \(request.url?.host ?? "")\(path)")
            if path == "/api" { return (200, Data(#"{"features":{"autumn":{"enabled":true,"url":"https://rooms.test/autumn"}}}"#.utf8)) }
            if path == "/autumn/avatars" { return (200, Data(#"{"id":"avatar1"}"#.utf8)) }
            if path == "/api/users/@me" { return (200, Data(#"{"_id":"me","username":"ob","display_name":"Osman"}"#.utf8)) }
            return (404, Data())
        }
        let client = try api()
        let user = try await client.updateProfile(OwnProfile(displayName: "Osman", username: "ob"))
        XCTAssertEqual(user.name, "Osman")
        _ = try await client.uploadAvatar(Data([1, 2, 3]), mime: "image/png")
        XCTAssertEqual(seen.values, ["PATCH rooms.test/api/users/@me", "GET rooms.test/api", "POST rooms.test/autumn/avatars", "PATCH rooms.test/api/users/@me"])
    }
    func testV2MissingFallsBackToV1WithoutInventingPresence() async throws {
        Responses.shared.set { request in
            if request.url?.path.contains("/v2/") == true { return (404, Data()) }
            return (200, Data(#"{"rooms":[{"channelId":"c","participants":[]}]}"#.utf8))
        }
        let directory = try await api().directory(ids: ["c"]); XCTAssertEqual(directory.rooms.count, 1); XCTAssertTrue(directory.rooms[0].participants.isEmpty)
    }
    func testDirectory403DoesNotFallBackOrAdvertiseRooms() async throws {
        Responses.shared.set { _ in (403, Data()) }
        do { _ = try await api().directory(ids: ["hidden"]); XCTFail("Expected denial") } catch { XCTAssertEqual(error as? RoomsError, .denied) }
    }
    func testExpiredSessionReturnsExplicitError() async throws {
        Responses.shared.set { _ in (401, Data()) }
        do { _ = try await api().user(); XCTFail("Expected expiration") } catch { XCTAssertEqual(error as? RoomsError, .expired) }
    }
    func testMalformedResponseIsRejected() async throws {
        Responses.shared.set { _ in (200, Data("not json".utf8)) }
        do { _ = try await api().user(); XCTFail("Expected decode failure") } catch { XCTAssertTrue(error is DecodingError) }
    }
    func testDeadlineCancelsSlowOperation() async {
        do {
            let _: Int = try await withTimeout(seconds: 0.01) { try await Task.sleep(for: .seconds(5)); return 1 }
            XCTFail("Expected deadline")
        } catch { XCTAssertEqual(error as? RoomsError, .timeout) }
    }
    func testEmptyDirectoryDoesNotCallNetwork() async throws {
        Responses.shared.set { _ in (500, Data()) }
        let result = try await api().directory(ids: []); XCTAssertTrue(result.rooms.isEmpty)
    }
    private nonisolated static func body(_ request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }; var data = Data(); var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count)) }
        return data
    }
    func testMessageHistoryUsesSessionHeaderCursorAndIncludedAuthors() async throws {
        Responses.shared.set { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if request.url?.path == "/api/channels/chat/messages", request.value(forHTTPHeaderField: "x-session-token") == "test-session", request.value(forHTTPHeaderField: "Authorization") == nil,
               query.contains(URLQueryItem(name: "before", value: "cursor")), query.contains(URLQueryItem(name: "limit", value: "50")), query.contains(URLQueryItem(name: "include_users", value: "true")) {
                return (200, Data(#"{"messages":[{"_id":"m","channel":"chat","author":"peer","content":"hi"}],"users":[{"_id":"peer","username":"Peer","display_name":"Alex"}]}"#.utf8))
            }; return (403, Data())
        }
        let page = try await api().messages(channelID: "chat", before: "cursor")
        XCTAssertEqual(page.messages.first?.authorName, "Alex"); XCTAssertFalse(page.hasMore)
    }
    func testSendUsesHeaderOnlyBecauseLegacyNonceSharesServerCache() async throws {
        Responses.shared.set { request in
            let raw = try? JSONDecoder().decode(JSONValue.self, from: Self.body(request))
            if request.httpMethod == "POST", request.url?.path == "/api/channels/chat/messages", request.value(forHTTPHeaderField: "Idempotency-Key") == "stable-nonce", raw?["nonce"] == .null, raw?["content"].string == "hello" {
                return (200, Data(#"{"_id":"m","channel":"chat","author":"self","content":"hello","nonce":"stable-nonce"}"#.utf8))
            }; return (400, Data())
        }
        let message = try await api().sendMessage(channelID: "chat", content: "hello", nonce: "stable-nonce")
        XCTAssertEqual(message.nonce, "stable-nonce")
    }
    func testDuplicateSendReconcilesCommittedMessageWithoutAnotherPost() async throws {
        Responses.shared.set { request in
            if request.httpMethod == "POST" { return (409, Data(#"{"type":"DuplicateNonce"}"#.utf8)) }
            if request.url?.path == "/api/channels/chat/messages" {
                return (200, Data(#"[{"_id":"committed","channel":"chat","author":"self","content":"hello","nonce":"same-key"}]"#.utf8))
            }
            return (500, Data())
        }
        let message = try await api().sendMessage(channelID: "chat", content: "hello", nonce: "same-key")
        XCTAssertEqual(message.id, "committed"); XCTAssertEqual(message.nonce, "same-key")
    }
    func testConsumedKeyWithoutCommittedMessageDoesNotResendWithNewKey() async throws {
        Responses.shared.set { request in
            if request.httpMethod == "POST" { return (409, Data(#"{"type":"DuplicateNonce"}"#.utf8)) }
            return (200, Data("[]".utf8))
        }
        do { _ = try await api().sendRichMessage(channelID: "chat", content: "hello", nonce: "old-key", attachments: [], replyID: nil); XCTFail("Expected unresolved duplicate") }
        catch { XCTAssertEqual(error as? RoomsError, .duplicateMessage) }
    }
    func testInvalidIdempotencyKeyIsRejectedBeforeRequest() async throws {
        Responses.shared.set { _ in XCTFail("Must not send invalid key"); return (500, Data()) }
        do { _ = try await api().sendMessage(channelID: "chat", content: "hello", nonce: String(repeating: "a", count: 65)); XCTFail("Expected invalid key") }
        catch { XCTAssertEqual(error as? RoomsError, .invalidMessage) }
    }
    func testMessageHistoryRejectsCrossChannelAndMalformedEnvelopes() async throws {
        Responses.shared.set { _ in (200, Data(#"{"messages":[{"_id":"m","channel":"other","author":"peer"}]}"#.utf8)) }
        do { _ = try await api().messages(channelID: "chat"); XCTFail("Expected scope failure") } catch { XCTAssertEqual(error as? RoomsError, .invalidResponse) }
        Responses.shared.set { _ in (200, Data(#"{"unexpected":[]}"#.utf8)) }
        do { _ = try await api().messages(channelID: "chat"); XCTFail("Expected envelope failure") } catch { XCTAssertEqual(error as? RoomsError, .invalidResponse) }
    }
    func testReadonlyChannelPermissionsUseExistingServerAndMembership() async throws {
        Responses.shared.set { request in
            switch request.url?.path {
            case "/api/users/@me": return (200, Data(#"{"_id":"self","username":"Self"}"#.utf8))
            case "/api/channels/chat": return (200, Data(#"{"_id":"chat","server":"server","channel_type":"TextChannel","default_permissions":{"a":0,"d":4194304}}"#.utf8))
            case "/api/servers/server": return (200, Data(#"{"_id":"server","owner":"owner","name":"Friends","default_permissions":7340032,"roles":{}}"#.utf8))
            case "/api/servers/server/members/self": return (200, Data(#"{"_id":{"server":"server","user":"self"},"roles":[]}"#.utf8))
            default: return (403, Data())
            }
        }
        let access = try await api().textAccess(channelID: "chat", userID: "self")
        XCTAssertTrue(access.view); XCTAssertTrue(access.history); XCTAssertFalse(access.send)
    }
    func testCatalogHidesChannelsWithoutViewPermissionAndExcludesDMs() async throws {
        Responses.shared.set { request in
            switch request.url?.path {
            case "/api/users/@me": return (200, Data(#"{"_id":"self","username":"Self"}"#.utf8))
            case "/api/servers/server": return (200, Data(#"{"_id":"server","owner":"owner","name":"Friends","default_permissions":7340032,"roles":{}}"#.utf8))
            case "/api/servers/server/members/self": return (200, Data(#"{"_id":{"server":"server","user":"self"},"roles":[]}"#.utf8))
            default: return (403, Data())
            }
        }
        let packet = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"channels":[{"_id":"visible","server":"server","name":"Chat","channel_type":"TextChannel"},{"_id":"hidden","server":"server","channel_type":"TextChannel","default_permissions":{"a":0,"d":1048576}},{"_id":"dm","channel_type":"DirectMessage"}]}"#.utf8))
        let channels = try await api().visibleTextChannels(packet, userID: "self")
        XCTAssertEqual(channels.map(\.id), ["visible"])
    }
    func testForbiddenMessageSendDoesNotExpireSession() async throws {
        Responses.shared.set { _ in (403, Data()) }
        do { _ = try await api().sendMessage(channelID: "chat", content: "hi", nonce: "n"); XCTFail("Expected denial") }
        catch { XCTAssertEqual(error as? RoomsError, .denied) }
    }

    func testDMListRequiresCurrentUserMembershipAndResolvesPeerName() async throws {
        Responses.shared.set { request in
            switch request.url?.path {
            case "/api/users/@me": return (200, Data(#"{"_id":"self","relations":[]}"#.utf8))
            case "/api/users/dms": return (200, Data(#"[{"_id":"dm","channel_type":"DirectMessage","recipients":["self","peer"],"last_message_id":"m3"},{"_id":"hidden","channel_type":"DirectMessage","recipients":["other","peer"]},{"_id":"group","channel_type":"Group"}]"#.utf8))
            case "/api/users/peer": return (200, Data(#"{"_id":"peer","username":"Peer","display_name":"Alex"}"#.utf8))
            default: return (404, Data())
            }
        }
        let channels = try await api().directMessages(userID: "self")
        XCTAssertEqual(channels.map(\.id), ["dm"]); XCTAssertEqual(channels.first?.name, "Alex"); XCTAssertEqual(channels.first?.lastMessageID, "m3")
    }
    func testBlockedDMKeepsHistoryButDisablesComposer() async throws {
        Responses.shared.set { request in
            switch request.url?.path {
            case "/api/users/@me": return (200, Data(#"{"_id":"self","relations":[{"_id":"peer","status":"Blocked"}]}"#.utf8))
            case "/api/channels/dm": return (200, Data(#"{"_id":"dm","channel_type":"DirectMessage","recipients":["self","peer"]}"#.utf8))
            case "/api/users/peer": return (200, Data(#"{"_id":"peer","username":"Peer"}"#.utf8))
            default: return (404, Data())
            }
        }
        let access = try await api().textAccess(channelID: "dm", userID: "self")
        XCTAssertTrue(access.view); XCTAssertTrue(access.history); XCTAssertFalse(access.send)
    }
    func testCreateDMUsesExistingGETEndpointAndRejectsWrongPeer() async throws {
        Responses.shared.set { request in
            switch request.url?.path {
            case "/api/users/@me": return (200, Data(#"{"_id":"self"}"#.utf8))
            case "/api/users/peer/dm":
                guard request.httpMethod == "GET" else { return (400, Data()) }
                return (200, Data(#"{"_id":"dm","channel_type":"DirectMessage","recipients":["self","wrong"]}"#.utf8))
            case "/api/users/wrong": return (200, Data(#"{"_id":"wrong","username":"Wrong"}"#.utf8))
            default: return (404, Data())
            }
        }
        do { _ = try await api().createDirectMessage(peerID: "peer", userID: "self"); XCTFail("Wrong peer must be rejected") }
        catch { XCTAssertEqual(error as? RoomsError, .invalidResponse) }
    }
    func testReadStateFiltersOtherUsersAndUsesExistingAckRoute() async throws {
        Responses.shared.set { request in
            if request.url?.path == "/api/sync/unreads" { return (200, Data(#"[{"_id":{"user":"self","channel":"dm"},"last_id":"m1","mentions":["m2"]},{"_id":{"user":"other","channel":"hidden"},"last_id":"m9"}]"#.utf8)) }
            if request.url?.path == "/api/channels/dm/ack/m2", request.httpMethod == "PUT", request.value(forHTTPHeaderField: "x-session-token") == "test-session", request.value(forHTTPHeaderField: "Authorization") == nil { return (204, Data()) }
            return (403, Data())
        }
        let client = try api(); let records = try await client.readStates(userID: "self")
        XCTAssertEqual(records, [.init(channelID: "dm", lastReadID: "m1", mentions: ["m2"])])
        try await client.acknowledge(channelID: "dm", messageID: "m2")
    }

    func testRichSendCarriesReplyAttachmentsAndStableIdempotencyKey() async throws {
        Responses.shared.set { request in
            let body = try? JSONDecoder().decode(JSONValue.self, from: Self.body(request))
            if request.httpMethod == "POST", request.value(forHTTPHeaderField: "Idempotency-Key") == "n", body?["nonce"] == .null, body?["attachments"].array == [.string("file")], body?["replies"].array.first?["id"].string == "source", body?["replies"].array.first?["mention"] == .bool(false) {
                return (200, Data(#"{"_id":"m","channel":"c","author":"self","content":"reply","nonce":"n","replies":["source"],"attachments":[{"_id":"file","filename":"photo.jpg","size":3,"content_type":"image/jpeg"}]}"#.utf8))
            }; return (400, Data())
        }
        let message = try await api().sendRichMessage(channelID: "c", content: "reply", nonce: "n", attachments: ["file"], replyID: "source")
        XCTAssertEqual(message.replyIDs, ["source"]); XCTAssertEqual(message.attachments.first?.mime, "image/jpeg")
    }
    func testEditDeleteReactionUseExistingRoutesAndRejectScopeMismatch() async throws {
        Responses.shared.set { request in
            if request.httpMethod == "DELETE" { return (204, Data()) }
            // Stoat v0.15.5 rejects codepoint ids; the legacy key goes out as the emoji itself.
            if request.httpMethod == "PUT" && request.url?.path.contains("/reactions/") == true { return request.url?.path.hasSuffix("/reactions/👍") == true ? (204, Data()) : (400, Data()) }
            return (200, Data(#"{"_id":"m","channel":"c","author":"self","content":"edited","reactions":{"1f44d":["self"]},"edited":"2026-10-14T12:00:00Z"}"#.utf8))
        }
        let client = try api()
        let edited = try await client.editMessage(channelID: "c", messageID: "m", content: "edited"); XCTAssertTrue(edited.edited)
        let reaction = try await client.react(channelID: "c", messageID: "m", emoji: "1f44d", remove: false); XCTAssertEqual(reaction.reactions["1f44d"], ["self"])
        try await client.deleteMessage(channelID: "c", messageID: "m")
        Responses.shared.set { _ in (200, Data(#"{"_id":"other","channel":"c","author":"self"}"#.utf8)) }
        do { _ = try await client.message(channelID: "c", messageID: "m"); XCTFail("Must reject wrong message") } catch { XCTAssertEqual(error as? RoomsError, .invalidResponse) }
    }
    func testFilesAndReactPermissionsAreIndependentOfSend() async throws {
        Responses.shared.set { request in
            switch request.url?.path {
            case "/api/users/@me": return (200, Data(#"{"_id":"self"}"#.utf8))
            case "/api/channels/c": return (200, Data(#"{"_id":"c","server":"s","channel_type":"TextChannel"}"#.utf8))
            case "/api/servers/s": return (200, Data(#"{"_id":"s","owner":"owner","default_permissions":674234368,"roles":{}}"#.utf8))
            case "/api/servers/s/members/self": return (200, Data(#"{"_id":{"server":"s","user":"self"},"roles":[]}"#.utf8))
            default: return (404, Data())
            }
        }
        let access = try await api().textAccess(channelID: "c", userID: "self")
        XCTAssertTrue(access.view); XCTAssertFalse(access.send); XCTAssertTrue(access.files); XCTAssertTrue(access.react)
    }
    func testProfileRespectsDeniedBioWithoutInventingIt() async throws {
        Responses.shared.set { request in
            if request.url?.path == "/api/users/peer" { return (200, Data(#"{"_id":"peer","username":"peer","display_name":"Alex","avatar":{"_id":"avatar"},"status":{"text":"Here"}}"#.utf8)) }
            return (403, Data())
        }
        let profile = try await api().profile(userID: "peer")
        XCTAssertEqual(profile.name, "Alex"); XCTAssertEqual(profile.avatarID, "avatar"); XCTAssertNil(profile.bio)
    }

}
