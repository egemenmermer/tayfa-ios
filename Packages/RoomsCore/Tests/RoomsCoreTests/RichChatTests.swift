import XCTest
@testable import RoomsCore

private func decode(_ text: String) -> JSONValue { try! JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) }
private let richAccess = TextAccess(view: true, send: true, history: true, files: true, react: true)
private let richChannel = TextChannel(id: "c", serverID: "s", name: "Chat", community: "Friends", access: richAccess)
private func richMessage(id: String = "m", content: String = "before", editedAt: Date? = nil, reactions: [String: [String]] = [:]) -> ChatMessage {
    ChatMessage(id: id, channelID: "c", authorID: "self", authorName: "Me", content: content, nonce: nil, edited: editedAt != nil, reactions: reactions, editedAt: editedAt)
}

final class RichChatModelTests: XCTestCase {
    func testFileOriginRejectsCrossOriginCredentialsAndQuery() throws {
        let trusted = URL(string: "https://rooms.test")!
        for value in ["http://rooms.test/autumn", "https://other.test/autumn", "https://u:p@rooms.test/autumn", "https://rooms.test/autumn?token=x"] { XCTAssertThrowsError(try FilePolicy.origin(value, trusted: trusted)) }
        XCTAssertEqual(try FilePolicy.origin("https://rooms.test:443/autumn", trusted: trusted).host, "rooms.test")
    }
    func testSafeNamesAndMultipartKeepOnlyStagedData() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("photo.txt"); try Data("abc".utf8).write(to: input)
        let staged = try FileStager.stage(source: input, mime: "text/plain"); defer { FileStager.remove(staged.url) }
        let body = try FileStager.multipart(staged, boundary: "test-boundary"); defer { FileStager.remove(body) }
        let text = try String(contentsOf: body, encoding: .utf8)
        XCTAssertTrue(text.contains("name=\"file\"; filename=\"photo.txt\"")); XCTAssertTrue(text.contains("\r\nabc\r\n--test-boundary--"))
        XCTAssertFalse(FilePolicy.safeName("a\r\n\"/b").contains("\r")); XCTAssertFalse(FilePolicy.safeName("a\"b").contains("\""))
        FileStager.remove(input); XCTAssertTrue(FileManager.default.fileExists(atPath: input.path), "Never remove arbitrary user files")
    }
    func testOversizedAndHeaderInjectionFilesRejected() throws {
        let input = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: input.path, contents: nil); defer { try? FileManager.default.removeItem(at: input) }
        let handle = try FileHandle(forWritingTo: input); try handle.truncate(atOffset: UInt64(FilePolicy.maxBytes + 1)); try handle.close()
        XCTAssertThrowsError(try FileStager.stage(source: input, mime: "application/octet-stream")) { XCTAssertEqual($0 as? RoomsError, .fileTooLarge) }
        XCTAssertThrowsError(try FilePolicy.mime("image/jpeg\r\nx: y"))
        XCTAssertThrowsError(try FilePolicy.assetURL(base: URL(string: "https://rooms.test")!, category: "attachments", id: "../secret"))
    }
    func testLiveEditAndReactionWinOverOlderMutationResponse() {
        let original = richMessage(), currentDate = Date(timeIntervalSince1970: 30)
        var timeline = MessageTimeline(); timeline.merge(original)
        timeline.applyPatch("m", data: decode(#"{"content":"new live","edited":"1970-01-01T00:00:30Z"}"#))
        timeline.applyReaction(id: "m", emoji: "1f44d", user: "peer", remove: false)
        timeline.applyAuthoritative(richMessage(content: "old rest", editedAt: Date(timeIntervalSince1970: 20)), baseline: original)
        XCTAssertEqual(timeline.message("m")?.content, "new live"); XCTAssertEqual(timeline.message("m")?.editedAt, currentDate)
        XCTAssertEqual(timeline.message("m")?.reactions["1f44d"], ["peer"])
        timeline.delete("m"); timeline.applyAuthoritative(original, baseline: original); XCTAssertTrue(timeline.messages.isEmpty)
    }
    func testBoundedHistoryRetainsOldestWindowAndPendingSends() {
        var timeline = MessageTimeline()
        for number in 0..<600 { timeline.merge(ChatMessage(id: String(format: "%04d", number), channelID: "c", authorID: "peer", authorName: "Peer", content: "hi", nonce: nil, created: Date(timeIntervalSince1970: Double(number)))) }
        timeline.insertPending(ChatMessage(id: "pending", channelID: "c", authorID: "self", authorName: "Me", content: "retry", nonce: "n", delivery: .failed))
        timeline.trim(limit: 500, keepOldest: true)
        XCTAssertEqual(timeline.messages.count, 501); XCTAssertEqual(timeline.oldestServerID, "0000")
        XCTAssertNotNil(timeline.message("pending")); XCTAssertNil(timeline.message("0599"))
        timeline.evictDelivered(); XCTAssertEqual(timeline.messages.map(\.id), ["pending"])
    }
    func testReactionEventsBeforeHistoryRetainGatewayOrder() {
        var timeline = MessageTimeline()
        timeline.applyReaction(id: "m", emoji: "1f44d", user: "early", remove: false)
        timeline.applyPatch("m", data: decode(#"{"reactions":{"1f44d":["replacement"]}}"#))
        timeline.applyReaction(id: "m", emoji: "1f44d", user: "late", remove: false)
        timeline.merge(richMessage())
        XCTAssertEqual(timeline.message("m")?.reactions["1f44d"], ["late", "replacement"])
    }
    func testReactionsDeduplicateAndRemoveOwnReaction() {
        var timeline = MessageTimeline(); timeline.merge(richMessage())
        timeline.applyReaction(id: "m", emoji: "1f44d", user: "self", remove: false); timeline.applyReaction(id: "m", emoji: "1f44d", user: "self", remove: false)
        XCTAssertEqual(timeline.message("m")?.reactions["1f44d"]?.count, 1)
        timeline.applyReaction(id: "m", emoji: "1f44d", user: "self", remove: true); XCTAssertNil(timeline.message("m")?.reactions["1f44d"])
    }
}

private actor RichStub: RichChatTransport {
    var slow = false
    var failFirst = false
    var sends: [(String, [String], String?)] = []
    var actions: [String] = []
    func setup(slow: Bool = false, failFirst: Bool = false) { self.slow = slow; self.failFirst = failFirst }
    func visibleTextChannels(_ packet: JSONValue, userID: String) async throws -> [TextChannel] { [richChannel] }
    func textAccess(channelID: String, userID: String) async throws -> TextAccess { richAccess }
    func messages(channelID: String, before: String?) async throws -> MessagePage { .init(messages: [richMessage()], hasMore: false) }
    func sendMessage(channelID: String, content: String, nonce: String) async throws -> ChatMessage { try await sendRichMessage(channelID: channelID, content: content, nonce: nonce, attachments: [], replyID: nil) }
    func directMessages(userID: String) async throws -> [TextChannel] { [] }
    func createDirectMessage(peerID: String, userID: String) async throws -> TextChannel { throw RoomsError.denied }
    func readStates(userID: String) async throws -> [ChannelReadState] { [] }
    func acknowledge(channelID: String, messageID: String) async throws {}
    func sendRichMessage(channelID: String, content: String, nonce: String, attachments: [String], replyID: String?) async throws -> ChatMessage {
        sends.append((nonce, attachments, replyID)); if failFirst && sends.count == 1 { throw RoomsError.unavailable }
        return ChatMessage(id: "sent", channelID: channelID, authorID: "self", authorName: "Me", content: content, nonce: nonce)
    }
    func editMessage(channelID: String, messageID: String, content: String) async throws -> ChatMessage { actions.append("edit"); if slow { try? await Task.sleep(for: .milliseconds(80)) }; return richMessage(content: content, editedAt: Date(timeIntervalSince1970: 20)) }
    func deleteMessage(channelID: String, messageID: String) async throws { actions.append("delete") }
    func react(channelID: String, messageID: String, emoji: String, remove: Bool) async throws -> ChatMessage { actions.append("react"); return richMessage(reactions: remove ? [:] : [emoji: ["self"]]) }
    func message(channelID: String, messageID: String) async throws -> ChatMessage { richMessage() }
    func uploadAttachment(_ file: LocalAttachment, progress: @escaping @Sendable (Double) -> Void) async throws -> ChatAttachment {
        progress(0.5); if slow { try? await Task.sleep(for: .milliseconds(80)) }; return ChatAttachment(id: "file", name: file.name, size: file.size, mime: file.mime)
    }
    func downloadAttachment(_ attachment: ChatAttachment, channelID: String, messageID: String, userID: String) async throws -> URL { throw RoomsError.unavailable }
    var previews = 0, inFlight = 0, peakInFlight = 0
    func imagePreview(_ attachment: ChatAttachment) async throws -> URL {
        previews += 1; inFlight += 1; peakInFlight = max(peakInFlight, inFlight)
        try? await Task.sleep(for: .milliseconds(30)); inFlight -= 1
        let input = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        try Data([1, 2, 3]).write(to: input); defer { try? FileManager.default.removeItem(at: input) }
        return try FileStager.stage(source: input, mime: "image/png").url
    }
    func previewStats() -> (Int, Int) { (previews, peakInFlight) }
    func profile(userID: String) async throws -> UserProfile { if slow { try? await Task.sleep(for: .milliseconds(80)) }; return .init(id: userID, name: "Peer", username: "peer", bio: "bio") }
    func avatar(_ profile: UserProfile) async throws -> URL? { nil }
    func sendLog() -> [(String, [String], String?)] { sends }
    func actionLog() -> [String] { actions }
}

@MainActor final class RichChatControllerTests: XCTestCase {
    private func waitFor(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !condition() && Date() < deadline { try await Task.sleep(for: .milliseconds(1)) }; XCTAssertTrue(condition())
    }
    private func prepared(_ api: RichStub) async throws -> ChatController {
        let chat = ChatController(); chat.configure(transport: api, userID: "self", userName: "Me")
        chat.process(decode(#"{"type":"Ready","channels":[],"users":[]}"#)); try await waitFor { !chat.channels.isEmpty }
        chat.open(richChannel); try await waitFor { !chat.loading }; return chat
    }
    private func file() throws -> LocalAttachment {
        let input = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        try Data("hello".utf8).write(to: input); defer { try? FileManager.default.removeItem(at: input) }; return try FileStager.stage(source: input, mime: "text/plain")
    }
    func testAttachmentReplyRetryKeepsSameNonceAndFileIDs() async throws {
        let api = RichStub(); await api.setup(failFirst: true); let chat = try await prepared(api)
        let file = try file(); chat.addAttachment(file, channelID: "c", expectedSession: chat.sessionGeneration)
        try await waitFor { chat.currentAttachments.first?.state == .ready }; chat.setReply("m"); chat.send()
        try await waitFor { chat.timeline.messages.contains { $0.delivery == .failed } }
        let failed = try XCTUnwrap(chat.timeline.messages.first { $0.delivery == .failed }); chat.retrySend(failed.id)
        try await waitFor { chat.timeline.messages.contains { $0.id == "sent" } }
        let log = await api.sendLog(); XCTAssertEqual(log.count, 2); XCTAssertEqual(log[0].0, log[1].0); XCTAssertEqual(log[0].1, ["file"]); XCTAssertEqual(log[0].2, "m"); chat.reset()
    }
    func testInlinePhotosDownloadAFewAtOnceAndAreReused() async throws {
        let api = RichStub(); let chat = try await prepared(api)
        let message = richMessage()
        let photos = (0..<6).map { ChatAttachment(id: "p\($0)", name: "p\($0).png", size: 3, mime: "image/png") }
        let tasks = photos.map { photo in Task { @MainActor in try await chat.preview(photo, message: message) } }
        var urls: [URL] = []
        for task in tasks { urls.append(try await task.value) }
        XCTAssertEqual(urls.count, 6)
        let (count, peak) = await api.previewStats(); XCTAssertEqual(count, 6); XCTAssertLessThanOrEqual(peak, 3)
        let again = try await chat.preview(photos[0], message: message)
        XCTAssertEqual(again, chat.cachedPreview("p0")); let (after, _) = await api.previewStats(); XCTAssertEqual(after, 6)
        do { _ = try await chat.preview(ChatAttachment(id: "doc", name: "a.pdf", size: 1, mime: "application/pdf"), message: message); XCTFail("Only photos preview inline") } catch {}
        chat.reset(); XCTAssertFalse(FileManager.default.fileExists(atPath: again.path)); XCTAssertNil(chat.cachedPreview("p0"))
    }
    func testCancelUploadIgnoresLateCompletionAndRemovesOwnStagedFile() async throws {
        let api = RichStub(); await api.setup(slow: true); let chat = try await prepared(api)
        let file = try file(); chat.addAttachment(file, channelID: "c", expectedSession: chat.sessionGeneration); await Task.yield(); chat.cancelAttachment(file.id)
        try await Task.sleep(for: .milliseconds(100)); XCTAssertTrue(chat.currentAttachments.isEmpty); XCTAssertFalse(FileManager.default.fileExists(atPath: file.url.path)); chat.reset()
    }
    func testLateFilePickerResultCannotCrossAccount() async throws {
        let api = RichStub(); let chat = try await prepared(api); let old = chat.sessionGeneration; chat.reset()
        let file = try file(); chat.addAttachment(file, channelID: "c", expectedSession: old)
        XCTAssertTrue(chat.attachmentDrafts.isEmpty); XCTAssertFalse(FileManager.default.fileExists(atPath: file.url.path))
    }
    func testGatewayEditWinsWhileOwnEditIsInFlight() async throws {
        let api = RichStub(); await api.setup(slow: true); let chat = try await prepared(api)
        let edit = Task { await chat.perform(.edit(id: "m", content: "old rest")) }
        try await waitFor { chat.actionBusy.contains("m") }
        chat.process(decode(#"{"type":"MessageUpdate","channel":"c","id":"m","data":{"content":"new live","edited":"1970-01-01T00:00:30Z"}}"#))
        _ = await edit.value; XCTAssertEqual(chat.timeline.message("m")?.content, "new live"); chat.reset()
    }
    func testOwnDeleteDoesNotChangeSelectedChannelAndProfileLogoutRejectsLateResult() async throws {
        let api = RichStub(); let chat = try await prepared(api)
        let deleted = await chat.perform(.delete(id: "m")); XCTAssertTrue(deleted); XCTAssertEqual(chat.selected?.id, "c"); XCTAssertNil(chat.timeline.message("m"))
        await api.setup(slow: true); let task = Task { try? await chat.fetchProfile("peer") }; await Task.yield(); chat.reset(); _ = await task.value
        XCTAssertTrue(chat.profileCache.isEmpty); XCTAssertTrue(chat.avatarFiles.isEmpty)
    }
    func testReplyDraftSurvivesNavigationAndLogoutClearsIt() async throws {
        let api = RichStub(); let chat = try await prepared(api); chat.setReply("m"); chat.setDraft("reply")
        chat.close(); chat.open(richChannel); XCTAssertEqual(chat.replyTarget, "m"); XCTAssertEqual(chat.draft, "reply")
        chat.reset(); XCTAssertTrue(chat.replyTargets.isEmpty)
    }
}
