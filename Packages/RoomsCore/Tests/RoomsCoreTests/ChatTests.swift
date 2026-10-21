import XCTest
@testable import RoomsCore

private func json(_ text: String) -> JSONValue { try! JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) }
private let fullAccess = TextAccess(view: true, send: true, history: true)
private func channel(_ id: String) -> TextChannel { TextChannel(id: id, serverID: "server", name: id, community: "Friends", access: fullAccess) }
private func message(_ id: String, channelID: String = "a", nonce: String? = nil, content: String = "hello", delivery: ChatMessage.Delivery = .sent) -> ChatMessage {
    ChatMessage(id: id, channelID: channelID, authorID: "self", authorName: "Me", content: content, nonce: nonce, created: Date(timeIntervalSince1970: 100), delivery: delivery)
}

final class ChatModelTests: XCTestCase {
    func testRESTAndGatewayAcknowledgmentsDeduplicateInBothOrders() {
        for gatewayFirst in [true, false] {
            var timeline = MessageTimeline()
            timeline.insertPending(message("pending", nonce: "nonce", delivery: .sending))
            let received = message("server-id", nonce: "nonce")
            if gatewayFirst { timeline.merge(received); timeline.merge(received, acknowledging: "nonce") }
            else { timeline.merge(received, acknowledging: "nonce"); timeline.merge(received) }
            XCTAssertEqual(timeline.messages.count, 1)
            XCTAssertEqual(timeline.messages.first?.delivery, .sent)
        }
    }
    func testNonceCannotRemoveAnotherAuthorsPendingMessage() {
        var timeline = MessageTimeline(); timeline.insertPending(message("pending", nonce: "nonce", delivery: .sending))
        let remote = ChatMessage(id: "remote", channelID: "a", authorID: "other", authorName: "Other", content: "hi", nonce: "nonce")
        timeline.merge(remote); XCTAssertEqual(timeline.messages.count, 2)
    }
    func testLiveEditsAndDeletesWinOverDelayedRESTPages() {
        var timeline = MessageTimeline()
        timeline.applyPatch("edited", data: json(#"{"content":"new","edited":"2026-10-14T10:00:00Z"}"#))
        timeline.delete("deleted")
        timeline.merge(message("edited", content: "old"), history: true)
        timeline.merge(message("deleted"), history: true)
        timeline.merge(message("edited", content: "older"), history: true)
        XCTAssertEqual(timeline.messages.map(\.content), ["new"])
        XCTAssertEqual(timeline.messages.first?.edited, true)
    }
    func testFailedSendKeepsNonceAndDoesNotOverwriteDeliveredMessage() {
        var timeline = MessageTimeline(); timeline.insertPending(message("pending", nonce: "same", delivery: .sending))
        timeline.fail("pending"); timeline.retry("pending")
        XCTAssertEqual(timeline.message("pending")?.nonce, "same")
        timeline.merge(message("delivered"), acknowledging: "same"); timeline.fail("pending")
        XCTAssertEqual(timeline.messages.count, 1); XCTAssertEqual(timeline.messages.first?.delivery, .sent)
    }
    func testWrongChannelPayloadRejectedAndTimestampDecoded() throws {
        let raw = json(#"{"_id":"01ARZ3NDEKTSV4RRFFQ69G5FAV","channel":"a","author":"self","content":"hello"}"#)
        XCTAssertThrowsError(try ChatMessage.parse(raw, channelID: "b"))
        let parsed = try ChatMessage.parse(raw, channelID: "a", users: ["self": "Me"])
        XCTAssertEqual(parsed.created.timeIntervalSince1970, 1469922850.259, accuracy: 0.001)
        XCTAssertEqual(parsed.authorName, "Me")
    }
    func testChannelDefaultsPrecedeServerRoleAndRankedChannelOverrides() throws {
        let server = json(#"{"owner":"owner","default_permissions":3145728,"roles":{"role":{"rank":10,"permissions":{"a":4194304,"d":0}}}}"#)
        let raw = json(#"{"default_permissions":{"a":0,"d":4194304},"role_permissions":{"role":{"a":0,"d":2097152}}}"#)
        let member = json(#"{"roles":["role"]}"#)
        let access = try TextPermissionPolicy.evaluate(userID: "self", privileged: false, server: server, channel: raw, member: member)
        XCTAssertTrue(access.view); XCTAssertTrue(access.send); XCTAssertFalse(access.history)
    }
    func testMissingMembershipDeniedOwnerAllowedAndTimeoutRemovesSend() throws {
        let server = json(#"{"owner":"owner","default_permissions":7340032}"#)
        XCTAssertEqual(try TextPermissionPolicy.evaluate(userID: "self", privileged: false, server: server, channel: .null, member: nil), .denied)
        XCTAssertEqual(try TextPermissionPolicy.evaluate(userID: "owner", privileged: false, server: server, channel: .null, member: nil), TextAccess(view: true, send: true, history: true, files: true, react: true))
        let member = json(#"{"roles":[],"timeout":"2099-01-01T00:00:00Z"}"#)
        let access = try TextPermissionPolicy.evaluate(userID: "self", privileged: false, server: server, channel: .null, member: member)
        XCTAssertTrue(access.view); XCTAssertTrue(access.history); XCTAssertFalse(access.send)
    }
    func testEqualRankDenyWinsAndMalformedPermissionsFailClosed() throws {
        let server = json(#"{"owner":"owner","default_permissions":7340032,"roles":{"one":{"rank":1,"permissions":{"a":4194304,"d":0}},"two":{"rank":1,"permissions":{"a":0,"d":4194304}}}}"#)
        let member = json(#"{"roles":["one","two"]}"#)
        XCTAssertFalse(try TextPermissionPolicy.evaluate(userID: "self", privileged: false, server: server, channel: .null, member: member).send)
        XCTAssertThrowsError(try TextPermissionPolicy.evaluate(userID: "self", privileged: false, server: json(#"{"default_permissions":1.5}"#), channel: .null, member: member))
    }
}

private actor MockChatTransport: ChatTransport {
    var denied: Set<String> = []
    var slow = false
    var failFirstSend = false
    var nonces: [String] = []
    var requested: [(String, String?)] = []
    func setup(slow: Bool = false, failFirstSend: Bool = false) { self.slow = slow; self.failFirstSend = failFirstSend }
    func deny(_ id: String) { denied.insert(id) }
    func visibleTextChannels(_ packet: JSONValue, userID: String) async throws -> [TextChannel] { [channel("a"), channel("b")].filter { !denied.contains($0.id) } }
    func textAccess(channelID: String, userID: String) async throws -> TextAccess { denied.contains(channelID) ? .denied : fullAccess }
    func messages(channelID: String, before: String?) async throws -> MessagePage {
        requested.append((channelID, before))
        if slow { try? await Task.sleep(for: .milliseconds(40)) }
        return MessagePage(messages: [message(before == nil ? "new-" + channelID : "old-" + channelID, channelID: channelID)], hasMore: before == nil)
    }
    func sendMessage(channelID: String, content: String, nonce: String) async throws -> ChatMessage {
        nonces.append(nonce)
        if slow { try? await Task.sleep(for: .milliseconds(40)) }
        if failFirstSend && nonces.count == 1 { throw RoomsError.unavailable }
        return message("sent-" + nonce, channelID: channelID, nonce: nonce, content: content)
    }
    func nonceLog() -> [String] { nonces }
    func requestLog() -> [(String, String?)] { requested }
}

@MainActor final class ChatControllerTests: XCTestCase {
    private func waitFor(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !condition() && Date() < deadline { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertTrue(condition(), "State did not settle")
    }
    private func prepared(_ api: MockChatTransport) async throws -> ChatController {
        let chat = ChatController(); chat.configure(transport: api, userID: "self", userName: "Me")
        chat.process(json(#"{"type":"Ready","channels":[],"users":[]}"#))
        try await waitFor { chat.channels.count == 2 }; return chat
    }
    func testSwitchingChannelInvalidatesLateHistoryAndKeepsDrafts() async throws {
        let api = MockChatTransport(); await api.setup(slow: true)
        let chat = try await prepared(api)
        chat.open(channel("a")); chat.setDraft("draft a")
        try await waitFor { chat.access.view }
        chat.open(channel("b")); try await waitFor { !chat.loading }
        XCTAssertEqual(chat.timeline.messages.map(\.channelID), ["b"])
        chat.open(channel("a")); XCTAssertEqual(chat.draft, "draft a")
        chat.reset()
    }
    func testLogoutClearsDataAndRejectsLateResponse() async throws {
        let api = MockChatTransport(); await api.setup(slow: true)
        let chat = try await prepared(api); chat.open(channel("a"))
        try await waitFor { chat.access.view }; chat.setDraft("private"); chat.reset()
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertTrue(chat.timeline.messages.isEmpty); XCTAssertTrue(chat.channels.isEmpty); XCTAssertTrue(chat.drafts.isEmpty); XCTAssertNil(chat.selected)
    }
    func testManualRetryReusesOriginalNonce() async throws {
        let api = MockChatTransport(); await api.setup(failFirstSend: true)
        let chat = try await prepared(api); chat.open(channel("a")); try await waitFor { !chat.loading }
        chat.setDraft("hello"); chat.send()
        try await waitFor { chat.timeline.messages.contains { $0.delivery == .failed } }
        let failed = try XCTUnwrap(chat.timeline.messages.first { $0.delivery == .failed })
        chat.retrySend(failed.id); try await waitFor { !chat.timeline.messages.contains { $0.delivery != .sent } }
        let nonces = await api.nonceLog(); XCTAssertEqual(nonces.count, 2); XCTAssertEqual(nonces.first, nonces.last)
        chat.reset()
    }
    func testLiveMessageEditDeleteDuringHistoryRequest() async throws {
        let api = MockChatTransport(); await api.setup(slow: true)
        let chat = try await prepared(api); chat.open(channel("a")); try await waitFor { chat.access.view }
        chat.process(json(#"{"type":"Message","_id":"live","channel":"a","author":"peer","content":"live"}"#))
        chat.process(json(#"{"type":"MessageUpdate","id":"new-a","channel":"a","data":{"content":"edited"}}"#))
        chat.process(json(#"{"type":"MessageDelete","id":"live","channel":"a"}"#))
        try await waitFor { !chat.loading }
        XCTAssertEqual(chat.timeline.messages.map(\.content), ["edited"]); chat.reset()
    }
    func testPermissionRevocationPurgesHistoryAndRejectsLaterEvents() async throws {
        let api = MockChatTransport(); let chat = try await prepared(api)
        chat.open(channel("a")); try await waitFor { !chat.loading }; chat.setDraft("secret")
        await api.deny("a")
        chat.process(json(#"{"type":"ChannelUpdate","id":"a","data":{"default_permissions":{"a":0,"d":1048576}}}"#))
        try await waitFor { !chat.catalogLoading }
        chat.process(json(#"{"type":"Message","_id":"late","channel":"a","author":"peer","content":"secret"}"#))
        XCTAssertTrue(chat.timeline.messages.isEmpty); XCTAssertFalse(chat.access.view); XCTAssertNil(chat.drafts["a"])
        chat.reset()
    }
    func testMessagePointerDoesNotReloadHistoryOrDiscardDraft() async throws {
        let api = MockChatTransport(); let chat = try await prepared(api)
        chat.open(channel("a")); try await waitFor { !chat.loading }; chat.setDraft("keep")
        let before = await api.requestLog().count
        chat.process(json(#"{"type":"ChannelUpdate","id":"a","data":{"last_message_id":"new"}}"#))
        await Task.yield()
        XCTAssertEqual(chat.draft, "keep"); let after = await api.requestLog().count; XCTAssertEqual(before, after)
        XCTAssertTrue(chat.access.send); chat.reset()
    }
    func testPaginationUsesOldestServerCursor() async throws {
        let api = MockChatTransport(); let chat = try await prepared(api)
        chat.open(channel("a")); try await waitFor { !chat.loading }; chat.loadOlder(); try await waitFor { !chat.loadingOlder }
        let calls = await api.requestLog(); XCTAssertEqual(calls.last?.1, "new-a")
        XCTAssertEqual(chat.timeline.messages.count, 2); XCTAssertFalse(chat.hasMore); chat.reset()
    }
}
