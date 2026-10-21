import XCTest
@testable import RoomsCore

private let all = TextAccess(view: true, send: true, history: true)
private let dm = TextChannel(id: "dm", serverID: "", name: "Peer", community: "Özel mesajlar", access: all, isDirect: true, recipients: ["self", "peer"], lastMessageID: "m3")
private let roomChat = TextChannel(id: "room", serverID: "server", name: "Room", community: "Friends", access: all, lastMessageID: "m3")
private func packet(_ text: String) -> JSONValue { try! JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) }

final class ReadLedgerTests: XCTestCase {
    func testUnknownReadStateIsNotAdvertisedAsRead() {
        var ledger = ReadLedger(); ledger.observeLatest(channelID: "room", messageID: "m3")
        XCTAssertNil(ledger.unread("room")); ledger.merge([]); XCTAssertEqual(ledger.unread("room"), true)
    }
    func testStaleSyncCannotRegressNewerMarkerOrLoseNewIncoming() {
        var ledger = ReadLedger(); ledger.observeLatest(channelID: "room", messageID: "m3")
        ledger.merge([.init(channelID: "room", lastReadID: "m1")]); ledger.acknowledge(channelID: "room", messageID: "m2")
        ledger.merge([.init(channelID: "room", lastReadID: "m1")]); XCTAssertEqual(ledger.states["room"]?.lastReadID, "m2")
        XCTAssertEqual(ledger.unread("room"), true)
        ledger.observeLatest(channelID: "room", messageID: "m1"); XCTAssertEqual(ledger.latest["room"], "m3")
    }
    func testReadingVisibleCursorDoesNotClearNewerMention() {
        var ledger = ReadLedger(); ledger.observeLatest(channelID: "room", messageID: "m3")
        ledger.merge([.init(channelID: "room", lastReadID: "m1", mentions: ["m2", "m3"])]); ledger.acknowledge(channelID: "room", messageID: "m2")
        XCTAssertEqual(ledger.states["room"]?.mentions, ["m3"])
        ledger.observeMention(channelID: "room", messageID: "m1"); XCTAssertEqual(ledger.states["room"]?.mentions, ["m3"])
    }
    func testSyncDropsOldMentionsButKeepsMentionsReceivedDuringRequest() {
        var ledger = ReadLedger(); ledger.merge([.init(channelID: "room", lastReadID: "m1", mentions: ["m2"])])
        let baseline = ledger.states; ledger.observeMention(channelID: "room", messageID: "m3")
        ledger.merge([.init(channelID: "room", lastReadID: "m1", mentions: [])], baseline: baseline)
        XCTAssertEqual(ledger.states["room"]?.mentions, ["m3"])
    }
    func testDeletedLatestDoesNotLeaveStuckUnreadOrResurrectMention() {
        var ledger = ReadLedger(); ledger.merge([.init(channelID: "room", lastReadID: "m1", mentions: ["m3"])])
        ledger.observeLatest(channelID: "room", messageID: "m3")
        ledger.removeMessage(channelID: "room", messageID: "m3", fallback: nil)
        XCTAssertNil(ledger.unread("room")); ledger.observeLatest(channelID: "room", messageID: "m3")
        XCTAssertNil(ledger.unread("room"))
        ledger.merge([.init(channelID: "room", lastReadID: "m1", mentions: ["m3"])])
        XCTAssertEqual(ledger.states["room"]?.mentions, [])
        ledger.observeLatest(channelID: "room", messageID: "m4"); XCTAssertEqual(ledger.unread("room"), true)
    }
    func testRemoteAckIsMonotonicAndRevocationRemovesMetadata() {
        var ledger = ReadLedger(); ledger.merge([]); ledger.observeLatest(channelID: "room", messageID: "m3")
        ledger.acknowledge(channelID: "room", messageID: "m3"); ledger.acknowledge(channelID: "room", messageID: "m1")
        XCTAssertEqual(ledger.unread("room"), false); ledger.remove("room")
        XCTAssertNil(ledger.states["room"]); XCTAssertNil(ledger.latest["room"])
    }
}

private actor SocialStub: SocialChatTransport {
    var acknowledgments: [(String, String)] = []
    var typing: [(String, Bool)] = []
    var slowDM = false
    var slowText = false
    func setup(slowDM: Bool = false, slowText: Bool = false) { self.slowDM = slowDM; self.slowText = slowText }
    func visibleTextChannels(_ packet: JSONValue, userID: String) async throws -> [TextChannel] {
        if slowText { try? await Task.sleep(for: .milliseconds(80)) }; return [roomChat]
    }
    func textAccess(channelID: String, userID: String) async throws -> TextAccess { all }
    func messages(channelID: String, before: String?) async throws -> MessagePage {
        MessagePage(messages: ["m1", "m2", "m3"].map { ChatMessage(id: $0, channelID: channelID, authorID: "peer", authorName: "Peer", content: $0, nonce: nil) }, hasMore: false)
    }
    func sendMessage(channelID: String, content: String, nonce: String) async throws -> ChatMessage {
        ChatMessage(id: "m4", channelID: channelID, authorID: "self", authorName: "Me", content: content, nonce: nonce)
    }
    func directMessages(userID: String) async throws -> [TextChannel] { [dm] }
    func createDirectMessage(peerID: String, userID: String) async throws -> TextChannel {
        if slowDM { try? await Task.sleep(for: .milliseconds(80)) }; return dm
    }
    func readStates(userID: String) async throws -> [ChannelReadState] { [.init(channelID: "room", lastReadID: "m1"), .init(channelID: "dm", lastReadID: "m1")] }
    func acknowledge(channelID: String, messageID: String) async throws { acknowledgments.append((channelID, messageID)) }
    func recordTyping(channel: String, active: Bool) -> Bool { typing.append((channel, active)); return true }
    func acks() -> [(String, String)] { acknowledgments }
    func typingLog() -> [(String, Bool)] { typing }
}

@MainActor final class SocialChatControllerTests: XCTestCase {
    private func waitFor(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !predicate() && Date() < deadline { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertTrue(predicate())
    }
    private func prepared(_ api: SocialStub, typingLifetime: TimeInterval = 10) async throws -> ChatController {
        let chat = ChatController(typingLifetime: typingLifetime)
        chat.configure(transport: api, userID: "self", userName: "Me")
        chat.sendTyping = { channel, active in await api.recordTyping(channel: channel, active: active) }
        chat.process(packet(#"{"type":"Ready","channels":[],"users":[{"_id":"peer","username":"Peer"}]}"#))
        try await waitFor { chat.channels.count == 2 && chat.ledger.available }; return chat
    }
    func testOpeningDoesNotAcknowledgeUntilMessageActuallyVisible() async throws {
        let api = SocialStub(); let chat = try await prepared(api)
        chat.open(dm); chat.setConversationVisible(true); try await waitFor { !chat.loading }
        try await Task.sleep(for: .milliseconds(350)); let empty = await api.acks(); XCTAssertTrue(empty.isEmpty)
        chat.markVisible(messageID: "m2"); try await waitFor { chat.ledger.states["dm"]?.lastReadID == "m2" }
        let acks = await api.acks(); XCTAssertEqual(acks.last?.1, "m2"); XCTAssertEqual(chat.unread("dm"), true)
        chat.reset()
    }
    func testCoalescedVisibilityMarksNewestVisibleNotUnseenLatest() async throws {
        let api = SocialStub(); let chat = try await prepared(api); chat.open(roomChat); chat.setConversationVisible(true)
        try await waitFor { !chat.loading }; chat.markVisible(messageID: "m1"); chat.markVisible(messageID: "m2")
        try await waitFor { chat.ledger.states["room"]?.lastReadID == "m2" }
        let acks = await api.acks(); XCTAssertEqual(acks.count, 1); XCTAssertEqual(acks.first?.1, "m2")
        chat.reset()
    }
    func testBackgroundCancelsPendingAckAndTyping() async throws {
        let api = SocialStub(); let chat = try await prepared(api); chat.open(dm); chat.setConversationVisible(true)
        try await waitFor { !chat.loading }; chat.setComposing(true); chat.setDraft("hello"); chat.markVisible(messageID: "m3")
        chat.setForeground(false); try await Task.sleep(for: .milliseconds(350))
        let acks = await api.acks(); XCTAssertTrue(acks.isEmpty)
        let typing = await api.typingLog(); XCTAssertEqual(typing.map(\.1), [true, false]); XCTAssertTrue(chat.typingNames.isEmpty)
        chat.reset()
    }
    func testRemoteAckIgnoresOtherAccountsAndPreservesNewUnreadMessage() async throws {
        let api = SocialStub(); let chat = try await prepared(api)
        chat.process(packet(#"{"type":"ChannelAck","id":"dm","user":"other","message_id":"m3"}"#))
        XCTAssertEqual(chat.ledger.states["dm"]?.lastReadID, "m1")
        chat.process(packet(#"{"type":"ChannelAck","id":"dm","user":"self","message_id":"m3"}"#))
        XCTAssertEqual(chat.unread("dm"), false)
        chat.process(packet(#"{"type":"Message","_id":"m4","channel":"dm","author":"peer","content":"hi","mentions":["self"]}"#))
        XCTAssertEqual(chat.unread("dm"), true); XCTAssertEqual(chat.mentionCount("dm"), 1)
        XCTAssertTrue(chat.timeline.messages.isEmpty); chat.reset()
    }
    func testTypingThrottlesAndStopsOnChannelSwitch() async throws {
        let api = SocialStub(); let chat = try await prepared(api); chat.open(dm); chat.setConversationVisible(true)
        try await waitFor { !chat.loading }; chat.setComposing(true)
        for text in ["h", "he", "hel", "hello"] { chat.setDraft(text) }
        chat.open(roomChat); try await Task.sleep(for: .milliseconds(20))
        let typing = await api.typingLog(); XCTAssertEqual(typing.map(\.1), [true, false]); XCTAssertEqual(typing.first?.0, "dm")
        chat.reset()
    }
    func testRemoteTypingExpiresAndDoesNotLeakAcrossConversations() async throws {
        let api = SocialStub(); let chat = try await prepared(api, typingLifetime: 0.03)
        chat.open(dm); chat.setConversationVisible(true); try await waitFor { !chat.loading }
        chat.process(packet(#"{"type":"ChannelStartTyping","id":"dm","user":"peer"}"#)); XCTAssertEqual(chat.typingNames, ["Peer"])
        try await waitFor { chat.typingNames.isEmpty }
        chat.process(packet(#"{"type":"ChannelStartTyping","id":"dm","user":"self"}"#)); XCTAssertTrue(chat.typingNames.isEmpty)
        chat.reset()
    }
    func testLateDMCreationCannotReopenAfterLogout() async throws {
        let api = SocialStub(); await api.setup(slowDM: true); let chat = try await prepared(api)
        chat.createDirectMessage(peerID: "peer"); chat.reset(); try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(chat.openedDirectID); XCTAssertNil(chat.selected); XCTAssertTrue(chat.channels.isEmpty); XCTAssertTrue(chat.ledger.states.isEmpty)
    }
    func testIndependentCatalogRequestsDoNotEraseOtherConversationDraft() async throws {
        let api = SocialStub(); let chat = try await prepared(api)
        chat.open(roomChat); try await waitFor { !chat.loading }; chat.setDraft("room draft")
        chat.open(dm); try await waitFor { !chat.loading }; chat.setDraft("dm draft")
        await api.setup(slowText: true); chat.retryCatalog()
        try await waitFor { !chat.catalogLoading && !chat.directLoading }
        XCTAssertEqual(chat.drafts["room"], "room draft"); XCTAssertEqual(chat.drafts["dm"], "dm draft")
        chat.reset()
    }
}
