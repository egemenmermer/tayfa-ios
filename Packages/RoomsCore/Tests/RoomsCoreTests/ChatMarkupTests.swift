import Foundation
import XCTest
@testable import RoomsCore

private final class ParityResponses: @unchecked Sendable {
    static let shared = ParityResponses()
    private let lock = NSLock()
    private var handler: @Sendable (URLRequest) -> (Int, Data) = { _ in (503, Data()) }
    func set(_ handler: @escaping @Sendable (URLRequest) -> (Int, Data)) { lock.lock(); self.handler = handler; lock.unlock() }
    func reply(_ request: URLRequest) -> (Int, Data) { lock.lock(); let handler = handler; lock.unlock(); return handler(request) }
}
private final class ParityURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, data) = ParityResponses.shared.reply(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
private func parityAPI() throws -> APIClient {
    let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ParityURLProtocol.self]
    return APIClient(origin: try EndpointPolicy.origin("https://rooms.test"), token: "test-session", session: URLSession(configuration: config))
}
private func runs<K: AttributedStringKey>(_ text: AttributedString, _ key: K.Type) -> [(String, K.Value)] where K.Value: Sendable {
    text.runs[key].compactMap { value, range in value.map { (String(text[range].characters), $0) } }
}

final class ChatMarkupTests: XCTestCase {
    func testKlipyGifMessagesMatchDesktop() {
        XCTAssertEqual(MessageMarkup.gifURL("  https://static.klipy.com/ii/abc/de.gif \n")?.absoluteString, "https://static.klipy.com/ii/abc/de.gif")
        XCTAssertNotNil(MessageMarkup.gifURL("https://static.klipy.com/x/y.WEBP"))
        XCTAssertNil(MessageMarkup.gifURL("https://evil.example/x.gif"))
        XCTAssertNil(MessageMarkup.gifURL("bak https://static.klipy.com/x/y.gif"))
        XCTAssertNil(MessageMarkup.gifURL("https://static.klipy.com/x/y.png"))
        XCTAssertNil(MessageMarkup.gifURL("http://static.klipy.com/x/y.gif"))
    }
    func testLinksDropTrailingPunctuationLikeDesktop() {
        let text = "bak: https://rooms.test/a?b=1). ve http://x.test/y!"
        XCTAssertEqual(MessageMarkup.links(in: text).map(\.url.absoluteString), ["https://rooms.test/a?b=1", "http://x.test/y"])
        XCTAssertTrue(MessageMarkup.links(in: "ftp://x.test www.x.test").isEmpty)
    }
    func testInlineMarkdownMentionsAndLinks() {
        let rendered = MessageMarkup.render("**selam** <@U1> _bak_ https://rooms.test/a_b_c **x** `kod <@U1>`", name: { $0 == "U1" ? "Ece" : "Katılımcı" })
        XCTAssertEqual(String(rendered.characters), "selam @Ece bak https://rooms.test/a_b_c x kod @Ece")
        XCTAssertEqual(rendered.runs.compactMap(\.link).map(\.absoluteString), ["https://rooms.test/a_b_c"])
        XCTAssertEqual(runs(rendered, MentionAttribute.self).map(\.1), ["U1", "U1"])
        let intents = rendered.runs.compactMap { run -> (String, InlinePresentationIntent)? in run.inlinePresentationIntent.map { (String(rendered[run.range].characters), $0) } }
        XCTAssertTrue(intents.contains { $0.0 == "selam" && $0.1.contains(.stronglyEmphasized) })
        XCTAssertTrue(intents.contains { $0.0 == "bak" && $0.1.contains(.emphasized) })
        XCTAssertTrue(intents.contains { $0.0.hasPrefix("kod") && $0.1.contains(.code) })
    }
    func testMarkdownNeverCreatesLinksImagesOrEntities() {
        let rendered = MessageMarkup.render("[tıkla](https://evil.test) ![x](https://evil.test/i.png) www.evil.test &amp; `&amp; [y](z)`", name: { _ in "" })
        XCTAssertEqual(String(rendered.characters), "[tıkla](https://evil.test) ![x](https://evil.test/i.png) www.evil.test &amp; &amp; [y](z)")
        // Only the visible desktop-style links remain tappable.
        XCTAssertEqual(rendered.runs.compactMap(\.link).map(\.absoluteString), ["https://evil.test", "https://evil.test/i.png"])
        XCTAssertTrue(rendered.runs.allSatisfy { $0.imageURL == nil })
    }
    func testTypedMentionsAndCustomEmojiRuns() {
        let rendered = MessageMarkup.render("@herkes bak :01HZX3K8Q2W6V1M4N7P9R2T5Y8: https://x.test/@ali", name: { _ in "" })
        XCTAssertEqual(runs(rendered, MentionAttribute.self).map(\.0), ["@herkes"])
        XCTAssertEqual(runs(rendered, CustomEmojiAttribute.self).map(\.1), ["01HZX3K8Q2W6V1M4N7P9R2T5Y8"])
        XCTAssertEqual(String(MessageMarkup.render("2*3*4 snake_case_name", name: { _ in "" }).characters), "234 snake_case_name")
        XCTAssertEqual(String(MessageMarkup.render("satır 1\nsatır 2", name: { _ in "" }).characters), "satır 1\nsatır 2")
        // A typed placeholder never pulls in another token.
        let forged = MessageMarkup.render("https://x.test \u{E000}0\u{E001}", name: { _ in "" })
        XCTAssertEqual(forged.runs.compactMap(\.link).count, 1); XCTAssertEqual(String(forged.characters), "https://x.test \u{FFFD}0\u{FFFD}")
    }
    func testCodeSpansStayVerbatimWhenEscaping() {
        XCTAssertEqual(MessageMarkup.escapedMarkdown("a [b] & `c [d] &` ``e`f``"), "a \\[b] \\& `c [d] &` ``e`f``")
        XCTAssertEqual(MessageMarkup.escapedMarkdown("`açık kalan [x"), "`açık kalan \\[x")
    }
    func testReactionKeysFollowStoatAndDesktop() throws {
        XCTAssertEqual(ReactionKey.upstream("1f44d"), "👍")
        XCTAssertEqual(ReactionKey.upstream("2764-fe0f"), "❤️")
        XCTAssertEqual(ReactionKey.upstream("❤️"), "❤️")
        XCTAssertTrue(ReactionKey.same("2764", "❤️")); XCTAssertTrue(ReactionKey.same("❤", "2764-fe0f")); XCTAssertFalse(ReactionKey.same("👍", "❤️"))
        XCTAssertTrue(ReactionKey.isCustom("01HZX3K8Q2W6V1M4N7P9R2T5Y8")); XCTAssertNil(ReactionKey.symbol("01HZX3K8Q2W6V1M4N7P9R2T5Y8"))
        XCTAssertEqual(ReactionKey.symbol("1f602"), "😂"); XCTAssertNil(ReactionKey.symbol("heart"))
        XCTAssertTrue(ReactionKey.valid("👍🏽")); XCTAssertTrue(ReactionKey.valid("🇹🇷")); XCTAssertFalse(ReactionKey.valid("abc")); XCTAssertFalse(ReactionKey.valid("a👍"))
        XCTAssertEqual(try ReactionKey.pathComponent("1f44d"), "%F0%9F%91%8D")
        XCTAssertEqual(try ReactionKey.pathComponent("01HZX3K8Q2W6V1M4N7P9R2T5Y8"), "01HZX3K8Q2W6V1M4N7P9R2T5Y8")
        XCTAssertThrowsError(try ReactionKey.pathComponent("../x"))
    }
    func testGifSearchUsesAccessAndKeepsOnlyKlipyMedia() async throws {
        ParityResponses.shared.set { request in
            guard request.url?.path == "/rooms-access/v1/gifs", request.value(forHTTPHeaderField: "Authorization") == "Bearer test-session" else { return (403, Data()) }
            guard request.url?.query == "q=kedi%20%C3%A7%C4%B1lg%C4%B1n&page=2" else { return (400, Data()) }
            return (200, Data(#"""
            {"items":[{"id":"1","title":"Kedi","preview":{"url":"https://static.klipy.com/a/p.webp","width":120,"height":90},"gif":{"url":"https://static.klipy.com/a/g.gif","width":320,"height":240}},
                      {"id":"2","title":"Kötü","preview":{"url":"https://evil.test/p.gif","width":1,"height":1},"gif":{"url":"https://static.klipy.com/b.gif","width":1,"height":1}}],"more":true}
            """#.utf8))
        }
        let page = try await parityAPI().gifs(query: " kedi çılgın ", page: 2)
        XCTAssertEqual(page.items.map(\.id), ["1"]); XCTAssertTrue(page.more)
        ParityResponses.shared.set { _ in (503, Data(#"{"error":"GIFS_NOT_CONFIGURED","message":"x"}"#.utf8)) }
        do { _ = try await parityAPI().gifs(query: "", page: 1); XCTFail("expected a refusal") }
        catch let error as GifError { XCTAssertEqual(error.localizedDescription, "GIF araması kapalı. Sunucuya KLIPY anahtarı eklenmeli.") }
        ParityResponses.shared.set { request in request.url?.query == "page=1" ? (429, Data()) : (400, Data()) }
        do { _ = try await parityAPI().gifs(query: "  ", page: 0); XCTFail("expected a refusal") }
        catch let error as GifError { XCTAssertEqual(error.code, "RATE_LIMITED") }
    }
    func testCommunityEmojiListKeepsOnlyThisServersEmoji() async throws {
        ParityResponses.shared.set { request in
            guard request.url?.path == "/api/servers/S1/emojis", request.value(forHTTPHeaderField: "x-session-token") == "test-session" else { return (404, Data()) }
            return (200, Data(#"[{"_id":"01HZX3K8Q2W6V1M4N7P9R2T5Y8","parent":{"type":"Server","id":"S1"},"name":"parti","animated":true},{"_id":"01HZX3K8Q2W6V1M4N7P9R2T5Y9","parent":{"type":"Server","id":"S2"},"name":"x"},{"_id":"bad","parent":{"type":"Server","id":"S1"},"name":"y"}]"#.utf8))
        }
        let list = try await parityAPI().communityEmojis(serverID: "S1")
        XCTAssertEqual(list, [CustomEmoji(id: "01HZX3K8Q2W6V1M4N7P9R2T5Y8", name: "parti", animated: true)])
    }
}

private let parityChannel = TextChannel(id: "c", serverID: "s", name: "genel", community: "Topluluk", access: TextAccess(view: true, send: true, history: true, files: true, react: true))
private actor ParityStub: RichChatTransport {
    var sent: [String] = []
    func visibleTextChannels(_ packet: JSONValue, userID: String) async throws -> [TextChannel] { [parityChannel] }
    func textAccess(channelID: String, userID: String) async throws -> TextAccess { parityChannel.access }
    func messages(channelID: String, before: String?) async throws -> MessagePage {
        .init(messages: [ChatMessage(id: "m", channelID: "c", authorID: "peer", authorName: "Ece", content: "selam", nonce: nil, reactions: ["❤": ["self"], "👍": ["peer"]])], hasMore: false)
    }
    func sendMessage(channelID: String, content: String, nonce: String) async throws -> ChatMessage { try await sendRichMessage(channelID: channelID, content: content, nonce: nonce, attachments: [], replyID: nil) }
    func directMessages(userID: String) async throws -> [TextChannel] { [] }
    func createDirectMessage(peerID: String, userID: String) async throws -> TextChannel { throw RoomsError.denied }
    func readStates(userID: String) async throws -> [ChannelReadState] { [] }
    func acknowledge(channelID: String, messageID: String) async throws {}
    func sendRichMessage(channelID: String, content: String, nonce: String, attachments: [String], replyID: String?) async throws -> ChatMessage {
        sent.append(content); return ChatMessage(id: "sent", channelID: channelID, authorID: "self", authorName: "Me", content: content, nonce: nonce)
    }
    func editMessage(channelID: String, messageID: String, content: String) async throws -> ChatMessage { throw RoomsError.unavailable }
    func deleteMessage(channelID: String, messageID: String) async throws {}
    func react(channelID: String, messageID: String, emoji: String, remove: Bool) async throws -> ChatMessage { throw RoomsError.unavailable }
    func message(channelID: String, messageID: String) async throws -> ChatMessage { throw RoomsError.unavailable }
    func uploadAttachment(_ file: LocalAttachment, progress: @escaping @Sendable (Double) -> Void) async throws -> ChatAttachment { throw RoomsError.unavailable }
    func downloadAttachment(_ attachment: ChatAttachment, channelID: String, messageID: String, userID: String) async throws -> URL { throw RoomsError.unavailable }
    func imagePreview(_ attachment: ChatAttachment) async throws -> URL { throw RoomsError.unavailable }
    func profile(userID: String) async throws -> UserProfile { .init(id: userID, name: "Ece", username: "ece") }
    func avatar(_ profile: UserProfile) async throws -> URL? { nil }
    func sentLog() -> [String] { sent }
}

@MainActor final class ChatParityControllerTests: XCTestCase {
    private func waitFor(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !condition() && Date() < deadline { try await Task.sleep(for: .milliseconds(1)) }; XCTAssertTrue(condition())
    }
    func testGifIsSentAsTheKlipyURLAndReactionsMatchEveryForm() async throws {
        let api = ParityStub(), chat = ChatController(); chat.configure(transport: api, userID: "self", userName: "Me")
        chat.process(try JSONDecoder().decode(JSONValue.self, from: Data(#"{"type":"Ready","channels":[],"users":[]}"#.utf8)))
        try await waitFor { !chat.channels.isEmpty }
        chat.open(parityChannel); try await waitFor { !chat.loading && !chat.timeline.messages.isEmpty }
        let message = try XCTUnwrap(chat.timeline.message("m"))
        XCTAssertTrue(chat.reactionSelected(message, emoji: "2764-fe0f")); XCTAssertFalse(chat.reactionSelected(message, emoji: "1f44d"))
        XCTAssertEqual(chat.reactionKey(message, for: "2764-fe0f"), "❤"); XCTAssertEqual(chat.reactionKey(message, for: "1f389"), "🎉")
        chat.setDraft("taslak")
        chat.sendGif(URL(string: "https://evil.test/a.gif")!)
        chat.sendGif(URL(string: "https://static.klipy.com/a/g.gif")!)
        try await waitFor { chat.timeline.messages.contains { $0.id == "sent" } }
        let log = await api.sentLog()
        XCTAssertEqual(log, ["https://static.klipy.com/a/g.gif"]); XCTAssertEqual(chat.draft, "taslak")
        chat.reset()
    }
}
