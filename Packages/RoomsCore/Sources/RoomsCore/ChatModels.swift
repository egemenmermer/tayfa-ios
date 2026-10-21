import Foundation

public struct TextAccess: Equatable, Sendable {
    public let view: Bool
    public let send: Bool
    public let history: Bool
    public let files: Bool
    public let react: Bool
    public init(view: Bool, send: Bool, history: Bool, files: Bool = false, react: Bool = false) { self.view = view; self.send = send; self.history = history; self.files = files; self.react = react }
    public static let denied = TextAccess(view: false, send: false, history: false)
}

public struct TextChannel: Identifiable, Equatable, Sendable {
    public let id: String
    public let serverID: String
    public var name: String
    public var community: String
    public var access: TextAccess
    public let isDirect: Bool
    public let recipients: [String]
    public var lastMessageID: String?
    public init(id: String, serverID: String, name: String, community: String, access: TextAccess, isDirect: Bool = false, recipients: [String] = [], lastMessageID: String? = nil) {
        self.id = id; self.serverID = serverID; self.name = name; self.community = community; self.access = access; self.isDirect = isDirect; self.recipients = recipients; self.lastMessageID = lastMessageID
    }
    public static func parse(_ raw: JSONValue, community: String, access: TextAccess) throws -> TextChannel {
        guard raw["channel_type"].string == "TextChannel", let id = raw["_id"].string,
              let server = raw["server"].string else { throw RoomsError.invalidResponse }
        return TextChannel(id: try EndpointPolicy.id(id), serverID: try EndpointPolicy.id(server), name: raw["name"].string ?? "Sohbet", community: community, access: access, lastMessageID: raw["last_message_id"].string)
    }
}

/// Mirrors the desktop's pinned Stoat v0.15.5 channel permission ordering.
public enum TextPermissionPolicy {
    private static let mask: UInt64 = (1 << 52) - 1
    private static func bits(_ value: JSONValue) throws -> UInt64 {
        guard case .number(let number) = value, number.isFinite, number.rounded() == number,
              number >= 0, number <= Double(mask) else { throw RoomsError.invalidResponse }
        return UInt64(number)
    }
    private static func override(_ raw: JSONValue) throws -> (allow: UInt64, deny: UInt64) {
        if raw == .null { return (0, 0) }
        return (try bits(raw["a"]), try bits(raw["d"]))
    }
    public static func evaluate(userID: String, privileged: Bool, server: JSONValue, channel: JSONValue, member: JSONValue?, now: Date = Date()) throws -> TextAccess {
        if privileged || server["owner"].string == userID { return TextAccess(view: true, send: true, history: true, files: true, react: true) }
        let value = try channelBits(userID: userID, privileged: privileged, server: server, channel: channel, member: member, now: now)
        let view = value & StoatPermission.view != 0
        return TextAccess(view: view, send: view && value & (1 << 22) != 0, history: view && value & (1 << 21) != 0, files: view && value & (1 << 27) != 0, react: view && value & (1 << 29) != 0)
    }
    /// Effective bits in a server channel (text or voice): channel defaults before server roles, then
    /// channel role overrides; nothing without View (desktop `stoatChannelPermissionBits`).
    public static func channelBits(userID: String, privileged: Bool, server: JSONValue, channel: JSONValue, member: JSONValue?, now: Date = Date()) throws -> UInt64 {
        if privileged || server["owner"].string == userID { return mask }
        guard let member else { return 0 }
        var value = try bits(server["default_permissions"])
        let defaults = try override(channel["default_permissions"])
        value = (value | defaults.allow) & ~defaults.deny
        let ranked = try rankedRoles(server: server, member: member)
        try apply(&value, ranked.map { ($0.rank, $0.permissions) })
        try apply(&value, ranked.map { ($0.rank, channel["role_permissions"][$0.id]) })
        value = timedOut(member, now: now) ? value & (StoatPermission.view | (1 << 21)) : value
        return value & StoatPermission.view != 0 ? value : 0
    }
    /// Server-wide bits without channel overrides (desktop `managementPermissionBits`), e.g. kick and ban.
    public static func serverBits(userID: String, privileged: Bool, server: JSONValue, member: JSONValue?, now: Date = Date()) throws -> UInt64 {
        if privileged || server["owner"].string == userID { return mask }
        guard let member else { return 0 }
        var value = try bits(server["default_permissions"])
        try apply(&value, try rankedRoles(server: server, member: member).map { ($0.rank, $0.permissions) })
        return timedOut(member, now: now) ? value & (StoatPermission.view | (1 << 21)) : value
    }
    private static func rankedRoles(server: JSONValue, member: JSONValue) throws -> [(id: String, rank: Int, permissions: JSONValue)] {
        let memberRoles = Set(member["roles"].array.compactMap(\.string))
        var ranked: [(id: String, rank: Int, permissions: JSONValue)] = []
        for (id, role) in server["roles"].object ?? [:] where memberRoles.contains(id) {
            guard case .number(let rank) = role["rank"], rank.isFinite, rank.rounded() == rank,
                  rank >= Double(Int32.min), rank <= Double(Int32.max) else { throw RoomsError.invalidResponse }
            ranked.append((id, Int(rank), role["permissions"]))
        }
        return ranked
    }
    /// Same-rank upstream order is unknown, so a rank's denials always win over its allowances.
    private static func apply(_ value: inout UInt64, _ entries: [(Int, JSONValue)]) throws {
        var groups: [Int: (allow: UInt64, deny: UInt64)] = [:]
        for (rank, raw) in entries {
            let permission = try override(raw)
            let previous = groups[rank] ?? (0, 0)
            groups[rank] = (previous.allow | permission.allow, previous.deny | permission.deny)
        }
        for rank in groups.keys.sorted(by: >) {
            let permission = groups[rank]!
            value = (value | permission.allow) & ~permission.deny
        }
    }
    private static func timedOut(_ member: JSONValue, now: Date) -> Bool {
        guard let timeout = member["timeout"].string, let date = ChatMessage.isoDate(timeout) else { return false }
        return date > now
    }
}

/// Stoat permission bits used outside text access (the 14 desktop role keys include these).
public enum StoatPermission {
    public static let view: UInt64 = 1 << 20
    public static let kickMembers: UInt64 = 64
    public static let banMembers: UInt64 = 128
    public static let moveMembers: UInt64 = 1 << 35
}

public struct ChatMessage: Identifiable, Equatable, Sendable {
    public enum Delivery: Equatable, Sendable { case sending, failed, sent }
    public let id: String
    public let channelID: String
    public let authorID: String
    public var authorName: String
    public var content: String
    public let nonce: String?
    public let created: Date
    public var edited: Bool
    public var attachmentCount: Int
    public var delivery: Delivery
    public var attachments: [ChatAttachment]
    public var replyIDs: [String]
    public var reactions: [String: [String]]
    public var mentions: [String]
    public var editedAt: Date?
    public var avatarID: String?
    public init(id: String, channelID: String, authorID: String, authorName: String, content: String, nonce: String?, created: Date = Date(), edited: Bool = false, attachmentCount: Int = 0, delivery: Delivery = .sent, attachments: [ChatAttachment] = [], replyIDs: [String] = [], reactions: [String: [String]] = [:], mentions: [String] = [], editedAt: Date? = nil, avatarID: String? = nil) {
        self.id = id; self.channelID = channelID; self.authorID = authorID; self.authorName = authorName; self.content = content; self.nonce = nonce; self.created = created; self.edited = edited; self.attachmentCount = attachments.isEmpty ? attachmentCount : attachments.count; self.delivery = delivery; self.attachments = attachments; self.replyIDs = replyIDs; self.reactions = reactions; self.mentions = mentions; self.editedAt = editedAt; self.avatarID = avatarID
    }
    public static func isoDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
    private static func ulidDate(_ id: String) -> Date {
        let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        guard id.count == 26 else { return .distantPast }
        var milliseconds: UInt64 = 0
        for char in id.prefix(10) {
            guard let value = alphabet.firstIndex(of: char) else { return .distantPast }
            milliseconds = milliseconds * 32 + UInt64(value)
        }
        return Date(timeIntervalSince1970: Double(milliseconds) / 1000)
    }
    public static func parse(_ raw: JSONValue, channelID: String, users: [String: String] = [:]) throws -> ChatMessage {
        guard let id = raw["_id"].string, raw["channel"].string == channelID, let author = raw["author"].string else { throw RoomsError.invalidResponse }
        let name = raw["user"]["display_name"].string ?? raw["user"]["username"].string ?? users[author] ?? "Katılımcı"
        return ChatMessage(id: try EndpointPolicy.id(id), channelID: channelID, authorID: try EndpointPolicy.id(author), authorName: name, content: raw["content"].string ?? "", nonce: raw["nonce"].string, created: ulidDate(id), edited: raw["edited"] != .null, attachmentCount: raw["attachments"].array.count, attachments: try raw["attachments"].array.map(ChatAttachment.parse), replyIDs: try raw["replies"].array.compactMap(\.string).map(EndpointPolicy.id), reactions: (raw["reactions"].object ?? [:]).mapValues { Array(Set($0.array.compactMap(\.string))).sorted() }, mentions: raw["mentions"].array.compactMap(\.string), editedAt: raw["edited"].string.flatMap(isoDate), avatarID: raw["user"]["avatar"]["_id"].string)
    }
}

public struct MessagePage: Sendable {
    public let messages: [ChatMessage]
    public let hasMore: Bool
    public init(messages: [ChatMessage], hasMore: Bool) { self.messages = messages; self.hasMore = hasMore }
}

/// Reconciles REST pages, live events and optimistic sends without resurrecting deletions.
public struct MessageTimeline: Sendable {
    private var records: [String: ChatMessage] = [:]
    private var deleted: Set<String> = []
    private var patches: [String: JSONValue] = [:]
    private enum ReactionPatch: Sendable { case full([String: [String]]); case delta(String, String?, Bool, Bool) }
    private var reactionPatches: [String: [ReactionPatch]] = [:]
    private var orderedIDs: [String] = []
    public init() {}
    public var messages: [ChatMessage] { orderedIDs.compactMap { records[$0] } }
    private mutating func rebuildOrder() { orderedIDs = records.values.sorted { ($0.created, $0.id) < ($1.created, $1.id) }.map(\.id) }
    public var oldestServerID: String? { messages.first(where: { $0.delivery == .sent })?.id }
    public func message(_ id: String) -> ChatMessage? { records[id] }
    public mutating func insertPending(_ message: ChatMessage) { records[message.id] = message; rebuildOrder() }
    public mutating func merge(_ message: ChatMessage, acknowledging nonce: String? = nil, history: Bool = false) {
        let key = nonce ?? message.nonce
        if let key {
            records = records.filter { _, existing in
                !(existing.delivery != .sent && existing.nonce == key && existing.authorID == message.authorID && existing.channelID == message.channelID)
            }
        }
        orderedIDs.removeAll { records[$0] == nil }
        guard !deleted.contains(message.id) else { return }
        // A REST response can be older than a live edit received during that request.
        if records[message.id]?.delivery == .sent { return }
        records[message.id] = message; rebuildOrder()
        if let patch = patches.removeValue(forKey: message.id) { applyPatch(message.id, data: patch) }
        if let reactions = reactionPatches.removeValue(forKey: message.id) {
            for reaction in reactions {
                switch reaction {
                case .full(let values): records[message.id]?.reactions = values
                case .delta(let emoji, let user, let remove, let all): applyReaction(id: message.id, emoji: emoji, user: user, remove: remove, all: all)
                }
            }
        }
    }
    public mutating func applyAuthoritative(_ incoming: ChatMessage, baseline: ChatMessage?) {
        guard !deleted.contains(incoming.id) else { return }
        guard var current = records[incoming.id], let baseline else { merge(incoming); return }
        if current.content == baseline.content && current.editedAt == baseline.editedAt { current.content = incoming.content; current.edited = incoming.edited; current.editedAt = incoming.editedAt }
        if current.reactions == baseline.reactions { current.reactions = incoming.reactions }
        if current.attachments == baseline.attachments { current.attachments = incoming.attachments; current.attachmentCount = incoming.attachmentCount }
        records[incoming.id] = current
    }
    public mutating func trim(limit: Int, keepOldest: Bool = false) {
        let server = messages.filter { $0.delivery == .sent }
        guard server.count > limit else { return }
        let removing = keepOldest ? server.suffix(server.count - limit) : server.prefix(server.count - limit)
        for message in removing { records.removeValue(forKey: message.id) }
        rebuildOrder()
    }
    public mutating func evictDelivered() { records = records.filter { $0.value.delivery != .sent }; rebuildOrder() }
    private mutating func storeReaction(_ event: ReactionPatch, id: String) {
        if reactionPatches[id] == nil && reactionPatches.count >= 1024 { return }
        reactionPatches[id, default: []].append(event)
        if reactionPatches[id]!.count > 50 { reactionPatches[id] = Array(reactionPatches[id]!.suffix(50)) }
    }
    public mutating func applyReaction(id: String, emoji: String, user: String?, remove: Bool, all: Bool = false) {
        guard !deleted.contains(id) else { return }
        guard records[id] != nil else { storeReaction(.delta(emoji, user, remove, all), id: id); return }
        if all { records[id]?.reactions.removeValue(forKey: emoji); return }
        guard let user else { return }
        var people = Set(records[id]?.reactions[emoji] ?? [])
        if remove { people.remove(user) } else { people.insert(user) }
        if people.isEmpty { records[id]?.reactions.removeValue(forKey: emoji) } else { records[id]?.reactions[emoji] = people.sorted() }
    }
    public mutating func fail(_ id: String) { if records[id]?.delivery == .sending { records[id]?.delivery = .failed } }
    public mutating func retry(_ id: String) { if records[id]?.delivery == .failed { records[id]?.delivery = .sending } }
    public mutating func delete(_ id: String) { records.removeValue(forKey: id); orderedIDs.removeAll { $0 == id }; deleted.insert(id); patches.removeValue(forKey: id); reactionPatches.removeValue(forKey: id) }
    public mutating func applyPatch(_ id: String, data: JSONValue) {
        guard !deleted.contains(id) else { return }
        guard records[id] != nil else {
            let previous = patches[id]?.object ?? [:]
            var fields = data.object ?? [:]
            if let reactions = fields.removeValue(forKey: "reactions") { storeReaction(.full((reactions.object ?? [:]).mapValues { Array(Set($0.array.compactMap(\.string))).sorted() }), id: id) }
            patches[id] = .object(previous.merging(fields, uniquingKeysWith: { _, new in new })); return
        }
        if let object = data.object, let content = object["content"] { records[id]?.content = content.string ?? "" }
        if data["edited"] != .null { records[id]?.edited = true; records[id]?.editedAt = data["edited"].string.flatMap(ChatMessage.isoDate) }
        if let attachments = data.object?["attachments"], let parsed = try? attachments.array.map(ChatAttachment.parse) { records[id]?.attachments = parsed; records[id]?.attachmentCount = parsed.count }
        if let reactions = data.object?["reactions"] { records[id]?.reactions = (reactions.object ?? [:]).mapValues { Array(Set($0.array.compactMap(\.string))).sorted() } }
    }
}

public protocol ChatTransport: Sendable {
    func visibleTextChannels(_ packet: JSONValue, userID: String) async throws -> [TextChannel]
    func textAccess(channelID: String, userID: String) async throws -> TextAccess
    func messages(channelID: String, before: String?) async throws -> MessagePage
    func sendMessage(channelID: String, content: String, nonce: String) async throws -> ChatMessage
}

public protocol SocialChatTransport: ChatTransport {
    func directMessages(userID: String) async throws -> [TextChannel]
    func createDirectMessage(peerID: String, userID: String) async throws -> TextChannel
    func readStates(userID: String) async throws -> [ChannelReadState]
    func acknowledge(channelID: String, messageID: String) async throws
}
