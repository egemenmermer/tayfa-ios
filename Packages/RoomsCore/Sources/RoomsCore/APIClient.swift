import Foundation

private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}
private enum MessageRequestError: Error { case duplicate }

public actor APIClient: MentionDirectoryTransport {
    public let origin: URL
    // Internal so per-feature `APIClient+<Area>.swift` extensions can build their own requests.
    let token: String?
    let session: URLSession
    let fileSession: URLSession
    let musicSession: URLSession
    private var fileRoot: URL?
    private var directoryVersion = 2
    public init(origin: URL, token: String? = nil, session: URLSession? = nil) {
        self.origin = origin; self.token = token
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 25
        self.session = session ?? URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
        let fileConfig = URLSessionConfiguration.ephemeral; fileConfig.timeoutIntervalForRequest = 60; fileConfig.timeoutIntervalForResource = 60
        self.fileSession = session ?? URLSession(configuration: fileConfig, delegate: NoRedirects(), delegateQueue: nil)
        // Adding a track can wait for the bot to fetch and match the source.
        let musicConfig = URLSessionConfiguration.ephemeral; musicConfig.timeoutIntervalForRequest = 165; musicConfig.timeoutIntervalForResource = 170
        self.musicSession = session ?? URLSession(configuration: musicConfig, delegate: NoRedirects(), delegateQueue: nil)
    }
    public static func login(origin: URL, email: String, password: String) async throws -> String {
        let api = APIClient(origin: origin)
        let data: Data
        do { data = try await api.request(path: "/api/auth/session/login", method: "POST", body: .object(["email": .string(email), "password": .string(password), "friendly_name": .string("ROOMS iPhone")])) }
        catch RoomsError.expired { throw RoomsError.invalidCredentials }
        let response = try JSONDecoder().decode(JSONValue.self, from: data)
        guard let token = response["token"].string, !token.isEmpty else { throw RoomsError.additionalAuthentication }; return token
    }
    public func user() async throws -> RoomsUser { try JSONDecoder().decode(RoomsUser.self, from: await request(path: "/api/users/@me")) }
    public func gatewayURL() async throws -> URL {
        let value = try JSONDecoder().decode(JSONValue.self, from: await request(path: "/api"))
        guard let ws = value["ws"].string else { throw RoomsError.invalidResponse }
        return try EndpointPolicy.gateway(ws, origin: origin)
    }
    public func grant(channel: String) async throws -> MediaGrant {
        try JSONDecoder().decode(MediaGrant.self, from: await request(path: "/rooms-access/v1/media/grant", method: "POST", body: .object(["channelId": .string(try EndpointPolicy.id(channel))]), broker: true))
    }
    /// Shares deafen with the room through the access service; false when the server lacks support.
    public func deafen(channel: String, deafened: Bool) async throws -> Bool {
        do {
            _ = try await request(path: "/rooms-access/v1/media/deafen", method: "POST", body: .object(["channelId": .string(try EndpointPolicy.id(channel)), "deafened": .bool(deafened)]), broker: true, allowMissing: true)
            return true
        } catch MissingEndpoint.missing { return false }
    }
    /// Screen-share permission for this room, granted and revoked by the access service as on desktop.
    public func screenLease(channel: String, acquire: Bool) async throws {
        _ = try await request(path: "/rooms-access/v1/media/screens/\(acquire ? "acquire" : "release")", method: "POST", body: .object(["channelId": .string(try EndpointPolicy.id(channel))]), broker: true)
    }
    /// A ROOMS invitation for the community of `channel`, from the access service (as desktop).
    public func createInvite(channel: String) async throws -> (code: String, expiresAt: String?) {
        let raw = try JSONDecoder().decode(JSONValue.self, from: await request(path: "/rooms-access/v1/invites", method: "POST", body: .object(["channelId": .string(try EndpointPolicy.id(channel))]), broker: true))
        guard let code = raw["code"].string, code.count <= 256, code.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { throw RoomsError.invalidResponse }
        return (code, raw["expiresAt"].string)
    }
    public func leave(channel: String) async throws {
        _ = try await request(path: "/rooms-access/v1/media/leave", method: "POST", body: .object(["channelId": .string(try EndpointPolicy.id(channel))]), broker: true)
    }
    public func directory(ids: [String]) async throws -> Directory {
        if ids.isEmpty { return try JSONDecoder().decode(Directory.self, from: Data("{\"rooms\":[]}".utf8)) }
        let checked = try ids.map(EndpointPolicy.id)
        var rooms: [Directory.Entry] = []
        for start in stride(from: 0, to: checked.count, by: 32) {
            let chunk = Array(checked[start..<min(start + 32, checked.count)])
            let body = JSONValue.object(["channelIds": .array(chunk.map(JSONValue.string))])
            var data: Data
            do { data = try await request(path: "/rooms-access/v\(directoryVersion)/media/directory", method: "POST", body: body, broker: true, allowMissing: directoryVersion == 2) }
            catch MissingEndpoint.missing {
                directoryVersion = 1
                data = try await request(path: "/rooms-access/v1/media/directory", method: "POST", body: body, broker: true)
            }
            rooms += try JSONDecoder().decode(Directory.self, from: data).rooms
        }
        return Directory(rooms: rooms)
    }
    public func channel(_ id: String) async throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: await request(path: "/api/channels/\(EndpointPolicy.id(id))"))
    }
    private func rawUser() async throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: await request(path: "/api/users/@me")) }
    private func authority(serverID: String, user: JSONValue, userID: String) async throws -> (JSONValue, JSONValue?) {
        let server = try JSONDecoder().decode(JSONValue.self, from: await request(path: "/api/servers/\(EndpointPolicy.id(serverID))"))
        guard server["_id"].string == serverID, server["owner"].string != nil else { throw RoomsError.invalidResponse }
        if server["owner"].string == userID || user["privileged"] == .bool(true) { return (server, nil) }
        let member = try JSONDecoder().decode(JSONValue.self, from: await request(path: "/api/servers/\(EndpointPolicy.id(serverID))/members/\(EndpointPolicy.id(userID))"))
        guard member["_id"]["server"].string == serverID, member["_id"]["user"].string == userID else { throw RoomsError.invalidResponse }
        return (server, member)
    }
    public func visibleTextChannels(_ packet: JSONValue, userID: String) async throws -> [TextChannel] {
        let user = try await rawUser()
        guard user["_id"].string == userID else { throw RoomsError.invalidResponse }
        let rawChannels = packet["channels"].array.filter { $0["channel_type"].string == "TextChannel" && $0["server"].string != nil }
        let groups = Dictionary(grouping: rawChannels, by: { $0["server"].string! })
        var result: [TextChannel] = []
        for serverID in groups.keys.sorted() {
            do {
                let (server, member) = try await authority(serverID: serverID, user: user, userID: userID)
                for raw in groups[serverID] ?? [] {
                    let access = try TextPermissionPolicy.evaluate(userID: userID, privileged: user["privileged"] == .bool(true), server: server, channel: raw, member: member)
                    if access.view { result.append(try TextChannel.parse(raw, community: server["name"].string ?? "Topluluk", access: access)) }
                }
            } catch RoomsError.denied { continue }
        }
        return result.sorted { ($0.community, $0.serverID, $0.name, $0.id) < ($1.community, $1.serverID, $1.name, $1.id) }
    }
    public func textAccess(channelID: String, userID: String) async throws -> TextAccess {
        let channel = try await channel(channelID)
        guard channel["_id"].string == channelID else { throw RoomsError.invalidResponse }
        if channel["channel_type"].string == "DirectMessage" {
            let user = try await rawUser()
            guard user["_id"].string == userID else { throw RoomsError.invalidResponse }
            return try await directChannel(channel, user: user, userID: userID).access
        }
        guard channel["_id"].string == channelID, channel["channel_type"].string == "TextChannel", let serverID = channel["server"].string else { throw RoomsError.invalidResponse }
        let user = try await rawUser()
        guard user["_id"].string == userID else { throw RoomsError.invalidResponse }
        let (server, member) = try await authority(serverID: serverID, user: user, userID: userID)
        return try TextPermissionPolicy.evaluate(userID: userID, privileged: user["privileged"] == .bool(true), server: server, channel: channel, member: member)
    }
    public func messages(channelID: String, before: String? = nil) async throws -> MessagePage {
        let channel = try EndpointPolicy.id(channelID)
        let cursor = try before.map(EndpointPolicy.id)
        let raw = try JSONDecoder().decode(JSONValue.self, from: await request(path: "/api/channels/\(channel)/messages?limit=50&include_users=true" + (cursor.map { "&before=\($0)" } ?? "")))
        let values: [JSONValue]
        if case .array(let array) = raw { values = array }
        else { guard case .array(let array) = raw["messages"] else { throw RoomsError.invalidResponse }; values = array }
        guard values.count <= 50 else { throw RoomsError.invalidResponse }
        let users = Dictionary(raw["users"].array.compactMap { value -> (String, String)? in
            guard let id = value["_id"].string else { return nil }; return (id, value["display_name"].string ?? value["username"].string ?? "Katılımcı")
        }, uniquingKeysWith: { _, last in last })
        return MessagePage(messages: try values.map { try ChatMessage.parse($0, channelID: channelID, users: users) }, hasMore: values.count == 50)
    }
    public func sendMessage(channelID: String, content: String, nonce: String) async throws -> ChatMessage {
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, content.count <= 4000 else { throw RoomsError.invalidMessage }
        return try await postMessage(channelID: channelID, nonce: nonce, body: ["content": .string(content)])
    }
    /// Stoat 0.15.5 consumes the header and legacy body nonce from the same cache.
    /// Sending both makes the first request reject itself as a duplicate.
    private func postMessage(channelID: String, nonce: String, body: [String: JSONValue]) async throws -> ChatMessage {
        let channel = try EndpointPolicy.id(channelID), key = try EndpointPolicy.id(nonce)
        guard key.count <= 64 else { throw RoomsError.invalidMessage }
        do {
            let raw = try JSONDecoder().decode(JSONValue.self, from: await request(path: "/api/channels/\(channel)/messages", method: "POST", body: .object(body), idempotencyKey: key))
            return try ChatMessage.parse(raw, channelID: channel)
        } catch MessageRequestError.duplicate {
            // A lost POST response can still have committed. Reconcile using the same key;
            // never blindly generate another key and risk posting twice.
            let page = try await messages(channelID: channel)
            if let existing = page.messages.first(where: { $0.nonce == key }) { return existing }
            throw RoomsError.duplicateMessage
        }
    }

    private func directChannel(_ raw: JSONValue, user: JSONValue, userID: String) async throws -> TextChannel {
        guard raw["channel_type"].string == "DirectMessage", let id = raw["_id"].string,
              case .array(let values) = raw["recipients"], values.count == 2 else { throw RoomsError.denied }
        let recipients = values.compactMap(\.string)
        guard recipients.count == 2, Set(recipients).count == 2, recipients.contains(userID), let peer = recipients.first(where: { $0 != userID }) else { throw RoomsError.denied }
        _ = try recipients.map(EndpointPolicy.id)
        let rawPeer = try JSONDecoder().decode(JSONValue.self, from: await request(path: "/api/users/\(EndpointPolicy.id(peer))"))
        guard rawPeer["_id"].string == peer else { throw RoomsError.invalidResponse }
        let relationship = user["relations"].array.first { $0["_id"].string == peer }?["status"].string ?? rawPeer["relationship"].string
        let blocked = ["Blocked", "BlockedOther"].contains(relationship ?? "") || rawPeer["deleted"] == .bool(true)
        return TextChannel(id: try EndpointPolicy.id(id), serverID: "", name: rawPeer["display_name"].string ?? rawPeer["username"].string ?? "Katılımcı", community: "Özel mesajlar", access: TextAccess(view: true, send: !blocked, history: true, files: !blocked, react: !blocked), isDirect: true, recipients: recipients, lastMessageID: raw["last_message_id"].string)
    }
    public func directMessages(userID: String) async throws -> [TextChannel] {
        let user = try await rawUser()
        guard user["_id"].string == userID else { throw RoomsError.invalidResponse }
        let raw = try JSONDecoder().decode(JSONValue.self, from: await request(path: "/api/users/dms"))
        guard case .array(let values) = raw, values.count <= 1000 else { throw RoomsError.invalidResponse }
        let direct = values.filter { $0["channel_type"].string == "DirectMessage" }
        var result: [TextChannel] = []
        try await withThrowingTaskGroup(of: TextChannel?.self) { group in
            var next = 0
            func enqueue(_ raw: JSONValue) {
                group.addTask {
                    do { return try await self.directChannel(raw, user: user, userID: userID) }
                    catch RoomsError.denied { return nil }
                }
            }
            while next < min(4, direct.count) { enqueue(direct[next]); next += 1 }
            while let channel = try await group.next() {
                if let channel { result.append(channel) }
                if next < direct.count { enqueue(direct[next]); next += 1 }
            }
        }
        return Dictionary(result.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last }).values.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }
    public func createDirectMessage(peerID: String, userID: String) async throws -> TextChannel {
        guard peerID != userID else { throw RoomsError.denied }
        let user = try await rawUser()
        guard user["_id"].string == userID else { throw RoomsError.invalidResponse }
        let raw = try JSONDecoder().decode(JSONValue.self, from: await request(path: "/api/users/\(EndpointPolicy.id(peerID))/dm"))
        let channel = try await directChannel(raw, user: user, userID: userID)
        guard channel.recipients.contains(peerID) else { throw RoomsError.invalidResponse }
        return channel
    }
    public func readStates(userID: String) async throws -> [ChannelReadState] {
        let raw = try JSONDecoder().decode(JSONValue.self, from: await request(path: "/api/sync/unreads"))
        guard case .array(let records) = raw, records.count <= 10000 else { throw RoomsError.invalidResponse }
        return try records.filter { $0["_id"]["user"].string == userID }.map { record in
            guard let channel = record["_id"]["channel"].string else { throw RoomsError.invalidResponse }
            let last = record["last_id"]
            guard last == .null || last.string != nil else { throw RoomsError.invalidResponse }
            if let id = last.string { _ = try EndpointPolicy.id(id) }
            let mentions: [String]
            if record["mentions"] == .null { mentions = [] }
            else {
                guard case .array(let values) = record["mentions"], values.allSatisfy({ $0.string != nil }) else { throw RoomsError.invalidResponse }
                mentions = try values.compactMap(\.string).map(EndpointPolicy.id)
            }
            return ChannelReadState(channelID: try EndpointPolicy.id(channel), lastReadID: last.string, mentions: mentions)
        }
    }
    public func acknowledge(channelID: String, messageID: String) async throws {
        _ = try await request(path: "/api/channels/\(EndpointPolicy.id(channelID))/ack/\(EndpointPolicy.id(messageID))", method: "PUT")
    }
    public func sendRichMessage(channelID: String, content: String, nonce: String, attachments: [String], replyID: String?) async throws -> ChatMessage {
        guard content.count <= 4000, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty, attachments.count <= 5 else { throw RoomsError.invalidMessage }
        var body: [String: JSONValue] = ["content": .string(content)]
        if !attachments.isEmpty { body["attachments"] = .array(try attachments.map(EndpointPolicy.id).map(JSONValue.string)) }
        if let replyID { body["replies"] = .array([.object(["id": .string(try EndpointPolicy.id(replyID)), "mention": .bool(false)])]) }
        return try await postMessage(channelID: channelID, nonce: nonce, body: body)
    }

    public func message(channelID: String, messageID: String) async throws -> ChatMessage {
        let raw = try JSONDecoder().decode(JSONValue.self, from: await request(path: "/api/channels/\(EndpointPolicy.id(channelID))/messages/\(EndpointPolicy.id(messageID))"))
        let result = try ChatMessage.parse(raw, channelID: channelID)
        guard result.id == messageID else { throw RoomsError.invalidResponse }; return result
    }
    public func editMessage(channelID: String, messageID: String, content: String) async throws -> ChatMessage {
        guard content.count <= 4000 else { throw RoomsError.invalidMessage }
        let raw = try JSONDecoder().decode(JSONValue.self, from: await request(path: "/api/channels/\(EndpointPolicy.id(channelID))/messages/\(EndpointPolicy.id(messageID))", method: "PATCH", body: .object(["content": .string(content)])))
        let result = try ChatMessage.parse(raw, channelID: channelID)
        guard result.id == messageID else { throw RoomsError.invalidResponse }; return result
    }
    public func deleteMessage(channelID: String, messageID: String) async throws { _ = try await request(path: "/api/channels/\(EndpointPolicy.id(channelID))/messages/\(EndpointPolicy.id(messageID))", method: "DELETE") }
    public func react(channelID: String, messageID: String, emoji: String, remove: Bool) async throws -> ChatMessage {
        // Stoat takes the emoji itself (or a custom emoji id), never a codepoint id such as `1f44d`.
        _ = try await request(path: "/api/channels/\(EndpointPolicy.id(channelID))/messages/\(EndpointPolicy.id(messageID))/reactions/\(ReactionKey.pathComponent(emoji))", method: remove ? "DELETE" : "PUT")
        return try await message(channelID: channelID, messageID: messageID)
    }
    func files() async throws -> URL {
        if let fileRoot { return fileRoot }
        let root = try JSONDecoder().decode(JSONValue.self, from: await request(path: "/api"))
        guard root["features"]["autumn"]["enabled"] == .bool(true), let raw = root["features"]["autumn"]["url"].string else { throw RoomsError.filesUnavailable }
        let base = try FilePolicy.origin(raw, trusted: origin); fileRoot = base; return base
    }
    func checkStatus(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else { throw RoomsError.invalidResponse }
        switch response.statusCode {
        case 200..<300: return
        case 401: throw RoomsError.expired
        case 403, 404: throw RoomsError.denied
        case 413: throw RoomsError.fileTooLarge
        case 429: throw RoomsError.rateLimited
        default: throw RoomsError.unavailable
        }
    }
    public func uploadAttachment(_ file: LocalAttachment, progress: @escaping @Sendable (Double) -> Void) async throws -> ChatAttachment {
        let base = try await files(), boundary = "Rooms-" + UUID().uuidString
        let worker = Task.detached { try FileStager.multipart(file, boundary: boundary) }
        let body = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
        defer { FileStager.remove(body) }; try Task.checkCancellation()
        var request = URLRequest(url: base.appendingPathComponent("attachments")); request.httpMethod = "POST"; request.timeoutInterval = 60
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue(token, forHTTPHeaderField: "x-session-token") }
        let (data, response) = try await fileSession.upload(for: request, fromFile: body, delegate: TransferObserver(limit: FilePolicy.maxBytes, progress: progress))
        try Task.checkCancellation(); try checkStatus(response)
        guard data.count <= 65536 else { throw RoomsError.invalidResponse }
        let raw = try JSONDecoder().decode(JSONValue.self, from: data)
        guard let id = raw["id"].string else { throw RoomsError.invalidResponse }
        return ChatAttachment(id: try EndpointPolicy.id(id), name: file.name, size: file.size, mime: file.mime)
    }
    func download(_ url: URL, name: String, limit: Int, imageOnly: Bool = false, videoOnly: Bool = false) async throws -> URL {
        var request = URLRequest(url: url); if let token { request.setValue(token, forHTTPHeaderField: "x-session-token") }
        let observer = TransferObserver(limit: limit)
        let (temporary, response): (URL, URLResponse)
        do { (temporary, response) = try await fileSession.download(for: request, delegate: observer) }
        catch { if observer.exceeded { throw RoomsError.fileTooLarge }; throw error }
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Task.checkCancellation(); try checkStatus(response)
        guard (try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? limit + 1) <= limit else { throw RoomsError.fileTooLarge }
        if imageOnly { guard response.mimeType?.hasPrefix("image/") == true else { throw RoomsError.invalidResponse } }
        if videoOnly { guard ["video/quicktime", "video/mp4"].contains(response.mimeType ?? "") else { throw RoomsError.invalidResponse } }
        let destination = try FileStager.directory().appendingPathComponent(FilePolicy.safeName(name))
        do { try FileManager.default.moveItem(at: temporary, to: destination); return destination }
        catch { FileStager.remove(destination); throw error }
    }
    public func downloadAttachment(_ attachment: ChatAttachment, channelID: String, messageID: String, userID: String) async throws -> URL {
        let access = try await textAccess(channelID: channelID, userID: userID)
        guard access.view, access.history else { throw RoomsError.denied }
        let message = try await message(channelID: channelID, messageID: messageID)
        guard let canonical = message.attachments.first(where: { $0.id == attachment.id }) else { throw RoomsError.denied }
        guard canonical.size <= FilePolicy.maxBytes else { throw RoomsError.fileTooLarge }
        let url = try FilePolicy.assetURL(base: await files(), category: "attachments", id: canonical.id, name: canonical.name)
        return try await download(url, name: canonical.name, limit: FilePolicy.maxBytes)
    }
    /// A photo from an already access-checked message list: one bounded, image-only download.
    public func imagePreview(_ attachment: ChatAttachment) async throws -> URL {
        guard attachment.mime.hasPrefix("image/"), attachment.size <= FilePolicy.maxBytes else { throw RoomsError.denied }
        let url = try FilePolicy.assetURL(base: await files(), category: "attachments", id: attachment.id, name: attachment.name)
        return try await download(url, name: attachment.name, limit: FilePolicy.maxBytes, imageOnly: true)
    }
    public func profile(userID: String) async throws -> UserProfile {
        let raw = try JSONDecoder().decode(JSONValue.self, from: await request(path: "/api/users/\(EndpointPolicy.id(userID))"))
        guard raw["_id"].string == userID else { throw RoomsError.invalidResponse }
        var bio: String?
        do {
            let profile = try JSONDecoder().decode(JSONValue.self, from: await request(path: "/api/users/\(EndpointPolicy.id(userID))/profile"))
            bio = profile["content"].string.map { String($0.prefix(5000)) }
        } catch RoomsError.denied { bio = nil }
        let avatar = raw["avatar"]["_id"].string
        if let avatar { _ = try EndpointPolicy.id(avatar) }
        return UserProfile(id: userID, name: raw["display_name"].string ?? raw["username"].string ?? "Katılımcı", username: raw["username"].string ?? "", discriminator: raw["discriminator"].string, status: raw["status"]["text"].string, bio: bio, avatarID: avatar)
    }
    /// The signed-in person's own profile, including the bio and presence the edit screen shows.
    public func ownProfile() async throws -> OwnProfile {
        let raw = try JSONDecoder().decode(JSONValue.self, from: await request(path: "/api/users/@me"))
        guard let id = raw["_id"].string else { throw RoomsError.invalidResponse }
        let profile = try await self.profile(userID: id)
        let presence = raw["status"]["presence"].string.flatMap(Presence.init(rawValue:)) ?? .online
        return OwnProfile(displayName: raw["display_name"].string ?? raw["username"].string ?? "", bio: profile.bio ?? "",
                          statusText: raw["status"]["text"].string ?? "", presence: presence,
                          username: raw["username"].string ?? "", avatarID: profile.avatarID)
    }
    public func updateProfile(_ profile: OwnProfile) async throws -> RoomsUser {
        try JSONDecoder().decode(RoomsUser.self, from: await request(path: "/api/users/@me", method: "PATCH", body: try profile.patchBody()))
    }
    /// Uploads to the file server's `avatars` tag, then points the account at it (as desktop does).
    public func uploadAvatar(_ image: Data, mime: String) async throws -> RoomsUser {
        let base = try await files(), boundary = "Rooms-" + UUID().uuidString
        var upload = URLRequest(url: base.appendingPathComponent("avatars")); upload.httpMethod = "POST"; upload.timeoutInterval = 30
        upload.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let token { upload.setValue(token, forHTTPHeaderField: "x-session-token") }
        let (data, response) = try await fileSession.upload(for: upload, from: try AvatarPolicy.multipart(image, mime: mime, boundary: boundary))
        try checkStatus(response)
        guard data.count <= 65536, let id = try JSONDecoder().decode(JSONValue.self, from: data)["id"].string else { throw RoomsError.invalidResponse }
        return try JSONDecoder().decode(RoomsUser.self, from: await request(path: "/api/users/@me", method: "PATCH", body: .object(["avatar": .string(try EndpointPolicy.id(id))])))
    }
    public func removeAvatar() async throws -> RoomsUser {
        try JSONDecoder().decode(RoomsUser.self, from: await request(path: "/api/users/@me", method: "PATCH", body: .object(["remove": .array([.string("Avatar")])])))
    }
    // MARK: Shared activities (Birlikte izle)
    private func activityPath(_ room: String) throws -> String { "/rooms-activities/v1/rooms/\(try EndpointPolicy.id(room))/activity" }
    /// With `after`, the service holds the request up to 20 s until the room changes.
    public func activitySnapshot(room: String, after revision: Int? = nil) async throws -> ActivityResponse {
        let query = revision.map { "?afterRevision=\(max(0, $0))&waitMs=20000" } ?? ""
        let (status, data) = try await rawRequest(path: try activityPath(room) + query, method: "GET", body: nil, timeout: 35)
        return try activityResult(status, data, room: room)
    }
    /// Retries only an explicit revision conflict, keeping the command id so the service deduplicates it.
    public func activityCommand(room: String, _ command: ActivityCommand, expectedRevision: Int) async throws -> ActivityResponse {
        let commandID = UUID()
        var revision = expectedRevision
        for attempt in 0..<3 {
            let (status, data) = try await rawRequest(path: try activityPath(room) + "/commands", method: "POST",
                                                      body: ActivityCommand.envelope(command, commandID: commandID, expectedRevision: revision), timeout: 30)
            if status == 409, attempt < 2, (try? JSONDecoder().decode(JSONValue.self, from: data))?["error"].string == "REVISION_CONFLICT" {
                revision = try await activitySnapshot(room: room).room.revision
                continue
            }
            return try activityResult(status, data, room: room)
        }
        throw ActivityError(code: "REVISION_CONFLICT")
    }
    /// The service's official-player page for one video, posting `rooms-youtube` events tagged with `nonce`.
    public func youtubePlayer(videoID: String) throws -> (url: URL, nonce: String) {
        guard YouTubeLink.valid(videoID), origin.scheme == "https" else { throw RoomsError.invalidEndpoint }
        let nonce = UUID().uuidString.lowercased()
        guard let url = URL(string: "/rooms-activities/player/youtube?videoId=\(videoID)&nonce=\(nonce)&chrome=minimal", relativeTo: origin)?.absoluteURL else { throw RoomsError.invalidEndpoint }
        return (url, nonce)
    }
    private func activityResult(_ status: Int, _ data: Data, room: String) throws -> ActivityResponse {
        switch status {
        case 200..<300:
            let value = try JSONDecoder().decode(ActivityResponse.self, from: data)
            guard value.protocolVersion == 1, value.room.roomId == room, value.room.revision >= 0 else { throw RoomsError.invalidResponse }
            return value
        case 401: throw RoomsError.expired
        default:
            let code = (try? JSONDecoder().decode(JSONValue.self, from: data))?["error"].string ?? ""
            throw ActivityError(code: code.range(of: "^[A-Z_]{1,64}$", options: .regularExpression) != nil ? code : "ACTIVITY_SERVICE_UNAVAILABLE")
        }
    }
    func rawRequest(path: String, method: String, body: JSONValue?, timeout: TimeInterval) async throws -> (Int, Data) {
        try Task.checkCancellation()
        guard let url = URL(string: path, relativeTo: origin)?.absoluteURL, url.host == origin.host else { throw RoomsError.invalidEndpoint }
        var request = URLRequest(url: url); request.httpMethod = method; request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body { request.httpBody = try JSONEncoder().encode(body) }
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch { if Task.isCancelled { throw CancellationError() }; throw ActivityError(code: "ACTIVITY_SERVICE_UNAVAILABLE") }
        guard let http = response as? HTTPURLResponse, data.count <= 2_097_152 else { throw RoomsError.invalidResponse }
        return (http.statusCode, data)
    }
    // MARK: Friends (same Stoat calls as desktop)
    public func friends() async throws -> [Friend] {
        let me = try JSONDecoder().decode(JSONValue.self, from: await request(path: "/api/users/@me"))
        let relations = Friend.relations(me)
        var result: [Friend] = []
        for batch in stride(from: 0, to: relations.count, by: 8).map({ Array(relations[$0..<min($0 + 8, relations.count)]) }) {
            try await withThrowingTaskGroup(of: Friend?.self) { group in
                for relation in batch {
                    group.addTask {
                        let user = try JSONDecoder().decode(JSONValue.self, from: await self.request(path: "/api/users/\(relation.id)"))
                        return try? Friend(user: user, relationship: relation.relationship)
                    }
                }
                for try await friend in group { if let friend { result.append(friend) } }
            }
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    /// Sends a request, or accepts one this person already sent.
    public func addFriend(handle: String) async throws {
        guard let handle = Friend.validHandle(handle) else { throw RoomsError.invalidMessage }
        _ = try await request(path: "/api/users/friend", method: "POST", body: .object(["username": .string(handle)]))
    }
    /// Declines, withdraws or ends a friendship.
    public func removeFriend(id: String) async throws { _ = try await request(path: "/api/users/\(try EndpointPolicy.id(id))/friend", method: "DELETE") }
    public func unblock(id: String) async throws { _ = try await request(path: "/api/users/\(try EndpointPolicy.id(id))/block", method: "DELETE") }
    public func communityMembers(serverID: String) async throws -> [MentionCandidate] {
        let raw = try JSONDecoder().decode(JSONValue.self, from: await request(path: "/api/servers/\(EndpointPolicy.id(serverID))/members?exclude_offline=false"))
        let members = raw["members"].array, people = raw["users"].array
        guard members.count <= 5000, people.count <= 5000 else { throw RoomsError.invalidResponse }
        var nicknames: [String: String] = [:]
        for member in members {
            guard member["_id"]["server"].string == serverID, let id = member["_id"]["user"].string else { throw RoomsError.invalidResponse }
            if let nickname = member["nickname"].string, !nickname.isEmpty { nicknames[id] = nickname }
        }
        let memberIDs = Set(members.compactMap { $0["_id"]["user"].string })
        return try people.prefix(1000).compactMap { person in
            guard let id = person["_id"].string, memberIDs.contains(id) else { return nil }
            _ = try EndpointPolicy.id(id)
            let name = nicknames[id] ?? person["display_name"].string ?? person["username"].string ?? "Katılımcı"
            return MentionCandidate(id: id, name: String(name.prefix(64)))
        }
    }
    public func avatar(_ profile: UserProfile) async throws -> URL? {
        guard let id = profile.avatarID else { return nil }
        let url = try FilePolicy.assetURL(base: await files(), category: "avatars", id: id)
        return try await download(url, name: "avatar", limit: 2_000_000, imageOnly: true)
    }
    public func communityIcon(serverID: String, iconID: String) async throws -> URL? {
        let server = try JSONDecoder().decode(JSONValue.self, from: await request(path: "/api/servers/\(EndpointPolicy.id(serverID))"))
        guard server["_id"].string == serverID, server["icon"]["_id"].string == iconID else { return nil }
        let url = try FilePolicy.assetURL(base: await files(), category: "icons", id: iconID)
        return try await download(url, name: "community-icon", limit: 2_000_000, imageOnly: true)
    }
    // MARK: Room DJ
    public func musicSnapshot(channel: String) async throws -> MusicSnapshot {
        try JSONDecoder().decode(MusicSnapshot.self, from: await musicRequest(channel: channel, suffix: "", body: nil, timeout: 15))
    }
    public func musicCommand(channel: String, _ command: MusicCommand) async throws -> MusicSnapshot {
        try JSONDecoder().decode(MusicSnapshot.self, from: await musicRequest(channel: channel, suffix: "", body: command.json, timeout: 160))
    }
    public func musicSearch(channel: String, query: String) async throws -> [MusicSearchResult] {
        guard case .search(let text) = MusicInput(query) else { throw MusicError(code: "MUSIC_SEARCH_UNAVAILABLE") }
        let results = try JSONDecoder().decode([MusicSearchResult].self, from: await musicRequest(channel: channel, suffix: "/search", body: .object(["query": .string(text)]), timeout: 60))
        return Array(results.prefix(5))
    }
    /// Community DJ name and poster from the server's public branding manifest.
    /// The DJ animation for iPhone. Desktop uses the manifest's WebM, which iOS cannot play, so the
    /// phone looks for a sibling `.mov`/`.mp4` (HEVC with alpha keeps the transparent background).
    public func musicAnimation() async -> URL? {
        guard let manifestURL = URL(string: "/rooms-branding/manifest.json", relativeTo: origin)?.absoluteURL,
              let (data, response) = try? await session.data(from: manifestURL), (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 8192,
              let path = (try? JSONDecoder().decode(JSONValue.self, from: data))?["music"]["animation"].string,
              path.hasPrefix("/rooms-branding/"), !path.contains("..") else { return nil }
        let base = (path as NSString).deletingPathExtension
        let candidates = path.hasSuffix(".webm") ? [base + ".mov", base + ".mp4"] : [path]
        for candidate in candidates {
            guard let url = URL(string: candidate, relativeTo: origin)?.absoluteURL, url.host == origin.host else { continue }
            if let file = try? await download(url, name: "dj-animation." + (candidate as NSString).pathExtension, limit: 8_000_000, videoOnly: true) { return file }
        }
        return nil
    }
    public func musicBranding() async throws -> (name: String, poster: URL?) {
        guard let manifestURL = URL(string: "/rooms-branding/manifest.json", relativeTo: origin)?.absoluteURL else { throw RoomsError.invalidEndpoint }
        let (data, response) = try await session.data(from: manifestURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 8192 else { throw RoomsError.unavailable }
        let manifest = try JSONDecoder().decode(JSONValue.self, from: data)
        let name = String((manifest["music"]["name"].string ?? "DJ").prefix(40))
        guard let path = manifest["music"]["poster"].string, path.hasPrefix("/rooms-branding/"),
              let posterURL = URL(string: path, relativeTo: origin)?.absoluteURL, posterURL.host == origin.host else { return (name, nil) }
        return (name, try await download(posterURL, name: "dj-poster", limit: 4_000_000, imageOnly: true))
    }
    func musicRequest(channel: String, suffix: String, body: JSONValue?, timeout: TimeInterval) async throws -> Data {
        guard let url = URL(string: "/rooms-access/v1/music/\(try EndpointPolicy.id(channel))\(suffix)", relativeTo: origin)?.absoluteURL, url.host == origin.host else { throw RoomsError.invalidEndpoint }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body { request.httpBody = try JSONEncoder().encode(body) }
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await musicSession.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch { throw RoomsError.unavailable }
        guard let http = response as? HTTPURLResponse, data.count <= 2_097_152 else { throw RoomsError.invalidResponse }
        if http.statusCode == 401 { throw RoomsError.expired }
        guard (200..<300).contains(http.statusCode) else {
            let code = (try? JSONDecoder().decode(JSONValue.self, from: data))?["error"].string ?? "MUSIC_UNAVAILABLE"
            throw MusicError(code: String(code.prefix(64)))
        }
        return data
    }
    public func logout() async { _ = try? await request(path: "/api/auth/session/logout", method: "POST") }
    /// Attaches this APNs device token to the current session. Stoat routes `apn` subscriptions to
    /// the ROOMS relay; signing out deletes the session and with it the subscription.
    public func subscribePush(deviceToken: String) async throws {
        guard deviceToken.count >= 64, deviceToken.count <= 200, deviceToken.allSatisfy(\.isHexDigit) else { throw RoomsError.invalidResponse }
        _ = try await request(path: "/api/push/subscribe", method: "POST", body: .object(["endpoint": .string("apn"), "p256dh": .string(""), "auth": .string(deviceToken.lowercased())]))
    }
    enum MissingEndpoint: Error { case missing }
    func request(path: String, method: String = "GET", body: JSONValue? = nil, broker: Bool = false, allowMissing: Bool = false, idempotencyKey: String? = nil) async throws -> Data {
        try Task.checkCancellation()
        guard let url = URL(string: path, relativeTo: origin)?.absoluteURL, url.host == origin.host else { throw RoomsError.invalidEndpoint }
        var request = URLRequest(url: url); request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue(broker ? "Bearer \(token)" : token, forHTTPHeaderField: broker ? "Authorization" : "x-session-token") }
        if let idempotencyKey { request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key") }
        if let body { request.httpBody = try JSONEncoder().encode(body) }
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch { if Task.isCancelled { throw CancellationError() }; throw RoomsError.unavailable }
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse, data.count <= 2_097_152 else { throw RoomsError.invalidResponse }
        switch response.statusCode {
        case 200..<300: return data
        case 400 where path.contains("/messages"): throw RoomsError.invalidMessage
        case 401: throw RoomsError.expired
        case 403: throw RoomsError.denied
        case 404 where allowMissing: throw MissingEndpoint.missing
        case 404: throw RoomsError.denied
        case 409 where method == "POST" && path.hasSuffix("/messages"): throw MessageRequestError.duplicate
        case 429: throw RoomsError.rateLimited
        default: throw RoomsError.unavailable
        }
    }
}

private final class TransferObserver: NSObject, URLSessionTaskDelegate, URLSessionDownloadDelegate, @unchecked Sendable {
    let limit: Int64
    let progress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var oversized = false
    private var lastProgress = Date.distantPast
    var exceeded: Bool { lock.lock(); defer { lock.unlock() }; return oversized }
    init(limit: Int, progress: @escaping @Sendable (Double) -> Void = { _ in }) { self.limit = Int64(limit); self.progress = progress }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        if totalBytesExpectedToSend > 0 {
            let value = min(1, Double(totalBytesSent) / Double(totalBytesExpectedToSend)), now = Date()
            lock.lock(); let send = now.timeIntervalSince(lastProgress) >= 0.1 || value == 1; if send { lastProgress = now }; lock.unlock()
            if send { progress(value) }
        }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > limit || totalBytesExpectedToWrite > limit { lock.lock(); oversized = true; lock.unlock(); downloadTask.cancel() }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
