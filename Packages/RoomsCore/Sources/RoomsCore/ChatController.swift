import Foundation
import Combine

@MainActor public final class ChatController: ObservableObject {
    @Published public private(set) var channels: [TextChannel] = []
    @Published public private(set) var selected: TextChannel?
    @Published public private(set) var timeline = MessageTimeline()
    @Published public private(set) var drafts: [String: String] = [:]
    @Published public private(set) var loading = false
    @Published public private(set) var loadingOlder = false
    @Published public private(set) var catalogLoading = false
    @Published public private(set) var hasMore = false
    @Published public private(set) var access = TextAccess.denied
    @Published public private(set) var error: String?
    @Published public private(set) var catalogError: String?
    @Published public private(set) var liveStatus = ""
    @Published public private(set) var ledger = ReadLedger()
    @Published public private(set) var readError: String?
    @Published public private(set) var directLoading = false
    @Published public private(set) var directError: String?
    @Published public private(set) var openingDirectFor: String?
    @Published public private(set) var openedDirectID: String?
    @Published public private(set) var typingNames: [String] = []
    public var sendTyping: ((String, Bool) async -> Bool)?
    private var directTask: Task<Void, Never>?
    private var directOpenTask: Task<Void, Never>?
    private var directOpenEpoch = OperationEpoch()
    private var readTask: Task<Void, Never>?
    private var ackTask: Task<Void, Never>?
    private var ackEpoch = OperationEpoch()
    private var ackFailed = false
    private var knownDirectIDs: Set<String> = []
    private let typingLifetime: TimeInterval
    private var visibleMessage: String?
    private var conversationVisible = false
    private var interactive = true
    private var composing = false
    private var failedDirectPeer: String?
    private var typingQueue: Task<Void, Never>?
    private var typingIdle: Task<Void, Never>?
    private var typingChannel: String?
    private var lastTyping = Date.distantPast
    private var typingExpiry: Task<Void, Never>?
    private var remoteTyping: [String: Date] = [:]
    @Published public private(set) var attachmentDrafts: [String: [AttachmentDraft]] = [:]
    @Published public private(set) var replyTargets: [String: String] = [:]
    @Published public private(set) var actionBusy: Set<String> = []
    @Published public private(set) var actionError: String?
    @Published public private(set) var profileCache: [String: UserProfile] = [:]
    @Published public private(set) var avatarFiles: [String: URL] = [:]
    @Published public private(set) var profileRevisions: [String: Int] = [:]
    // Inline photos: downloaded files by attachment id, newest last, a few downloads at once.
    private var previewFiles: [String: URL] = [:]
    private var previewOrder: [String] = []
    private var previewTasks: [String: Task<URL, Error>] = [:]
    private var previewRunning = 0
    private var previewWaiters: [CheckedContinuation<Void, Never>] = []
    @Published public private(set) var historyWindowLimited = false
    @Published public private(set) var memberDirectory: [String: [MentionCandidate]] = [:]
    /// Community emoji by server, loaded on demand; images by emoji id are cached files.
    @Published public private(set) var emojiDirectory: [String: [CustomEmoji]] = [:]
    private var emojiFiles: [String: URL] = [:]
    private var emojiTasks: [String: Task<URL, Error>] = [:]
    private var memberLoadedAt: [String: Date] = [:]
    private var memberTasks: [String: Task<Void, Never>] = [:]
    private var mentionBindings: [String: [String: String]] = [:]
    private var uploads: [String: Task<Void, Never>] = [:]
    private var uploadStamps: [String: UUID] = [:]
    private var mutations: [String: Task<ChatMessage?, Error>] = [:]
    private var profileTasks: [String: Task<UserProfile, Error>] = [:]
    private var avatarTasks: [String: Task<URL?, Error>] = [:]
    private var activeProfiles = 0
    private var profileLRU: [String] = []
    private var cacheLRU: [String] = []
    private var olderWindows: Set<String> = []
    private var failedAction: (channelID: String, action: MessageAction)?
    private var hasExpired = false
    private var profileStamps: [String: UUID] = [:]
    private var avatarStamps: [String: UUID] = [:]
    public var onExpired: (() -> Void)?
    private var transport: (any ChatTransport)?
    private var userID = ""
    private var userName = ""
    private var snapshot = JSONValue.object([:])
    private var users: [String: String] = [:]
    private var buffers: [String: MessageTimeline] = [:]
    private var more: [String: Bool] = [:]
    private var session = OperationEpoch()
    private var authority = OperationEpoch()
    private var selection = OperationEpoch()
    private var catalogTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var sends: [String: Task<Void, Never>] = [:]
    private var permitted: Set<String> = []
    private var foreground = true
    public init(typingLifetime: TimeInterval = 10) { self.typingLifetime = max(0.02, typingLifetime) }

    public func configure(transport: any ChatTransport, userID: String, userName: String) {
        reset(); self.transport = transport; self.userID = userID; self.userName = userName
    }
    public func reset() {
        clearRichState(); hasExpired = false; stopSocialRequests(); session.advance(); authority.advance(); selection.advance()
        ledger = ReadLedger(); knownDirectIDs = []; readError = nil; directError = nil; directLoading = false; openedDirectID = nil; failedDirectPeer = nil; conversationVisible = false; composing = false
        catalogTask?.cancel(); loadTask?.cancel(); sends.values.forEach { $0.cancel() }; sends = [:]
        transport = nil; userID = ""; userName = ""; users = [:]; snapshot = .object([:]); permitted = []
        channels = []; selected = nil; timeline = MessageTimeline(); buffers = [:]; more = [:]; drafts = [:]
        memberTasks.values.forEach { $0.cancel() }; memberTasks = [:]; memberDirectory = [:]; memberLoadedAt = [:]; mentionBindings = [:]
        loading = false; loadingOlder = false; catalogLoading = false; hasMore = false; access = .denied; error = nil; catalogError = nil; liveStatus = ""
    }
    public func setLiveStatus(_ value: String) {
        liveStatus = value
        if !value.isEmpty { stopTyping(); clearRemoteTyping(); ackTask?.cancel(); ackTask = nil; ackEpoch.advance(); ackFailed = false }
    }
    public var draft: String { selected.flatMap { drafts[$0.id] } ?? "" }
    public func setDraft(_ value: String) { if let id = selected?.id { drafts[id] = value }; updateTyping() }
    public func open(_ channel: TextChannel) {
        guard channels.contains(where: { $0.id == channel.id }) else { return }
        stopTyping(); clearRemoteTyping(); ackTask?.cancel(); ackTask = nil; ackEpoch.advance(); ackFailed = false; visibleMessage = nil
        selection.advance(); loadTask?.cancel(); loadingOlder = false
        touchConversation(channel.id)
        historyWindowLimited = olderWindows.contains(channel.id)
        selected = channel; access = .denied; error = nil; actionError = nil; failedAction = nil
        timeline = buffers[channel.id] ?? MessageTimeline(); hasMore = more[channel.id] ?? false
        load(older: false)
        if !channel.isDirect { loadMembers(serverID: channel.serverID) }
    }
    /// The member list for a community (reused for 5 minutes, like mention suggestions).
    public func loadMemberList(serverID: String) { loadMembers(serverID: serverID) }
    private func loadMembers(serverID: String) {
        guard memberTasks[serverID] == nil, let directory = transport as? any MentionDirectoryTransport else { return }
        if let loaded = memberLoadedAt[serverID], Date().timeIntervalSince(loaded) < 300 { return }
        let login = session.advanceForRead()
        memberTasks[serverID] = Task { [weak self] in
            let members = try? await directory.communityMembers(serverID: serverID)
            guard let self, self.session.owns(login) else { return }
            self.memberTasks[serverID] = nil
            // A failed listing keeps the previous directory; suggestions fall back to known authors.
            if let members { self.memberDirectory[serverID] = members; self.memberLoadedAt[serverID] = Date() }
        }
    }
    public func close() {
        setConversationVisible(false); visibleMessage = nil
        selection.advance(); loadTask?.cancel(); selected = nil; timeline = MessageTimeline()
        access = .denied; loading = false; loadingOlder = false; error = nil; hasMore = false
    }
    public func retryCatalog() { refreshCatalog() }
    public func reload() { load(older: false) }
    public func loadOlder() { guard hasMore else { return }; load(older: true) }
    private func publish(_ channelID: String) {
        buffers[channelID]?.trim(limit: 500, keepOldest: olderWindows.contains(channelID))
        if selected?.id != channelID && !cacheLRU.contains(channelID) { buffers[channelID]?.evictDelivered() }
        if selected?.id == channelID { timeline = buffers[channelID] ?? MessageTimeline(); historyWindowLimited = olderWindows.contains(channelID) }
    }
    private func load(older: Bool) {
        guard let transport, let channel = selected, foreground, !loadingOlder, !(older && loading) else { return }
        if older && !access.history { return }
        loadTask?.cancel()
        let ticket = selection.advance(), login = session.advanceForRead(), acl = authority.advanceForRead(), user = userID
        let cursor = older ? timeline.oldestServerID : nil
        if older && cursor == nil { hasMore = false; return }
        loading = !older; loadingOlder = older; error = nil
        loadTask = Task { [weak self] in
            let controller = self
            do {
                let (permissions, page) = try await withTimeout {
                    let permissions = try await transport.textAccess(channelID: channel.id, userID: user)
                    guard permissions.view else { throw RoomsError.denied }
                    guard await controller?.authorizeLoad(permissions, channelID: channel.id, login: login, ticket: ticket, acl: acl) == true else { throw CancellationError() }
                    let page = permissions.history ? try await transport.messages(channelID: channel.id, before: cursor) : MessagePage(messages: [], hasMore: false)
                    return (permissions, page)
                }
                guard let self, self.session.owns(login), self.selection.owns(ticket), self.authority.owns(acl), !Task.isCancelled else { return }
                self.access = permissions; self.permitted.insert(channel.id)
                var buffer = self.buffers[channel.id] ?? MessageTimeline()
                for message in page.messages { buffer.merge(self.named(message), history: true); self.ledger.observeLatest(channelID: channel.id, messageID: message.id) }
                if older && buffer.messages.filter({ $0.delivery == .sent }).count > 500 { self.olderWindows.insert(channel.id) }
                self.buffers[channel.id] = buffer; self.publish(channel.id)
                self.more[channel.id] = page.hasMore; self.hasMore = page.hasMore
                self.loading = false; self.loadingOlder = false; self.scheduleAcknowledgment()
            } catch {
                guard let self, self.session.owns(login), self.selection.owns(ticket), self.authority.owns(acl), !Task.isCancelled else { return }
                self.loading = false; self.loadingOlder = false
                if error as? RoomsError == .expired { self.signalExpired() }
                else if error as? RoomsError == .denied {
                    self.revoke(channel.id); self.error = "Bu sohbeti görüntüleme iznin yok veya kanal kaldırıldı."
                } else { self.error = error.localizedDescription }
            }
        }
    }
    private func authorizeLoad(_ permissions: TextAccess, channelID: String, login: UInt64, ticket: UInt64, acl: UInt64) -> Bool {
        guard session.owns(login), selection.owns(ticket), authority.owns(acl), foreground else { return false }
        access = permissions; permitted.insert(channelID)
        if buffers[channelID] == nil { buffers[channelID] = MessageTimeline() }
        return true
    }
    public func send() {
        guard let channel = selected, access.send, !loading, foreground else { return }
        let content = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = currentAttachments
        guard canSendDraft else { error = "Metni ve dosya yüklemelerini kontrol et."; return }
        guard (buffers[channel.id]?.messages.filter { $0.delivery != .sent }.count ?? 0) < 20 else { error = "Bekleyen mesajları tekrar gönder veya listeden kaldır."; return }
        if olderWindows.contains(channel.id) { returnToLatest() }
        let remote = files.compactMap(\.uploaded), reply = replyTargets[channel.id]
        let nonce = UUID().uuidString
        let encoded = MentionDraft.encode(content, bindings: mentionBindings[channel.id] ?? [:])
        mentionBindings.removeValue(forKey: channel.id)
        let message = ChatMessage(id: "pending-" + nonce, channelID: channel.id, authorID: userID, authorName: userName, content: encoded.content, nonce: nonce, delivery: .sending, attachments: remote, replyIDs: reply.map { [$0] } ?? [], mentions: encoded.mentions)
        var buffer = buffers[channel.id] ?? MessageTimeline(); buffer.insertPending(message)
        buffers[channel.id] = buffer; drafts[channel.id] = ""; replyTargets.removeValue(forKey: channel.id)
        for file in files { FileStager.remove(file.file.url) }; attachmentDrafts.removeValue(forKey: channel.id)
         publish(channel.id); stopTyping(); deliver(message)
    }
    public func retrySend(_ id: String) {
        guard let channel = selected, access.send, foreground, var buffer = buffers[channel.id], let message = buffer.message(id), message.delivery == .failed else { return }
        buffer.retry(id); buffers[channel.id] = buffer; publish(channel.id); deliver(message)
    }
    private func deliver(_ pending: ChatMessage) {
        guard let transport, let nonce = pending.nonce, sends[nonce] == nil else { return }
        let login = session.advanceForRead(), acl = authority.advanceForRead(), user = userID
        sends[nonce] = Task { [weak self] in
            do {
                let sent = try await withTimeout {
                    if let rich = transport as? any RichChatTransport { return try await rich.sendRichMessage(channelID: pending.channelID, content: pending.content, nonce: nonce, attachments: pending.attachments.map(\.id), replyID: pending.replyIDs.first) }
                    guard pending.attachments.isEmpty, pending.replyIDs.isEmpty else { throw RoomsError.filesUnavailable }
                    return try await transport.sendMessage(channelID: pending.channelID, content: pending.content, nonce: nonce)
                }
                guard let self, self.session.owns(login), self.authority.owns(acl), !Task.isCancelled else { return }
                guard sent.authorID == user else { throw RoomsError.invalidResponse }
                self.ledger.observeLatest(channelID: pending.channelID, messageID: sent.id)
                self.buffers[pending.channelID]?.merge(self.named(sent), acknowledging: nonce); self.publish(pending.channelID)
            } catch {
                guard let self, self.session.owns(login), self.authority.owns(acl), !Task.isCancelled else { return }
                if error as? RoomsError == .expired { self.signalExpired() }
                else if error as? RoomsError == .denied {
                    // 403 on POST may mean send permission was removed, not view.
                    self.buffers[pending.channelID]?.fail(pending.id); self.publish(pending.channelID)
                    if self.selected?.id == pending.channelID { self.access = .denied; self.load(older: false) }
                } else {
                    self.buffers[pending.channelID]?.fail(pending.id); self.publish(pending.channelID)
                    if self.selected?.id == pending.channelID { self.error = "Mesajın gönderildiği doğrulanamadı. Mesajın altından tekrar deneyebilirsin. " + error.localizedDescription }
                }
            }
            if let self, self.session.owns(login) { self.sends.removeValue(forKey: nonce) }
        }
    }
    private func named(_ message: ChatMessage) -> ChatMessage {
        var message = message
        if message.authorID == userID { message.authorName = userName }
        else if message.authorName == "Katılımcı", let name = users[message.authorID] { message.authorName = name }
        return message
    }
    private func revoke(_ id: String) {
        removeChannelFiles(id); replyTargets.removeValue(forKey: id)
        buffers.removeValue(forKey: id); drafts.removeValue(forKey: id); more.removeValue(forKey: id); permitted.remove(id)
        channels.removeAll { $0.id == id }; knownDirectIDs.remove(id); ledger.remove(id)
        if selected?.id == id { stopTyping(); clearRemoteTyping(); ackTask?.cancel(); ackTask = nil; ackEpoch.advance(); ackFailed = false; visibleMessage = nil }
        if selected?.id == id { timeline = MessageTimeline(); access = .denied; hasMore = false }
    }
    private func invalidateAuthority() {
        stopRichOperations(); clearProfiles()
        stopSocialRequests()
        authority.advance(); selection.advance(); loadTask?.cancel()
        sends.values.forEach { $0.cancel() }; sends = [:]
        // Retain uncertain sends for an idempotent manual retry, but discard cached
        // private history until fresh permissions are known.
        for (id, buffer) in buffers {
            var retained = MessageTimeline()
            for var message in buffer.messages where message.delivery != .sent {
                message.delivery = .failed; retained.insertPending(message)
            }
            buffers[id] = retained
        }
        permitted = []; access = .denied; loading = false; loadingOlder = false
        if let id = selected?.id { publish(id) }
    }
    private func refreshCatalog() {
        guard let transport, userID != "", foreground else { return }
        refreshDirectMessages()
        catalogTask?.cancel(); catalogLoading = true; catalogError = nil
        let login = session.advanceForRead(), acl = authority.advanceForRead(), packet = snapshot, user = userID
        catalogTask = Task { [weak self] in
            do {
                let channels = try await withTimeout { try await transport.visibleTextChannels(packet, userID: user) }
                guard let self, self.session.owns(login), self.authority.owns(acl), !Task.isCancelled else { return }
                self.channels = channels + self.channels.filter(\.isDirect); self.catalogLoading = false
                for channel in channels { self.ledger.observeLatest(channelID: channel.id, messageID: channel.lastMessageID) }
                let allowed = Set(self.channels.map(\.id))
                for id in Array(self.buffers.keys) where !allowed.contains(id) && !self.knownDirectIDs.contains(id) { self.revoke(id) }
                if let selected = self.selected, !selected.isDirect {
                    if let updated = channels.first(where: { $0.id == selected.id }) { self.selected = updated; self.load(older: false) }
                    else { self.revoke(selected.id); self.error = "Bu sohbet artık kullanılamıyor." }
                }
            } catch {
                guard let self, self.session.owns(login), self.authority.owns(acl), !Task.isCancelled else { return }
                self.catalogLoading = false; self.channels.removeAll { !$0.isDirect }
                if error as? RoomsError == .expired { self.signalExpired() }
                else { self.catalogError = "Sohbetler yüklenemedi. " + error.localizedDescription }
            }
        }
    }
    public func setForeground(_ value: Bool) {
        foreground = value
        if !value { catalogTask?.cancel(); invalidateAuthority(); catalogLoading = false; liveStatus = "Canlı mesajlar arka planda duraklatıldı." }
        // Ready after foreground/reconnect supplies a fresh catalog and resyncs messages.
    }
    public func process(_ packet: JSONValue) {
        switch packet["type"].string {
        case "Ready":
            snapshot = packet
            users = Dictionary(packet["users"].array.compactMap { raw -> (String, String)? in
                guard let id = raw["_id"].string else { return nil }; return (id, raw["display_name"].string ?? raw["username"].string ?? "Katılımcı")
            }, uniquingKeysWith: { _, last in last })
            invalidateAuthority(); channels = []; ledger.markUnavailable(); refreshCatalog(); refreshReadStates()
        case "Message":
            guard let id = packet["channel"].string, let messageID = packet["_id"].string, (try? EndpointPolicy.id(messageID)) != nil else { return }
            guard channels.contains(where: { $0.id == id && $0.access.view }) else { if !directLoading { refreshDirectMessages() }; return }
            ledger.observeLatest(channelID: id, messageID: messageID)
            if packet["mentions"].array.compactMap(\.string).contains(userID) { ledger.observeMention(channelID: id, messageID: messageID) }
            if let index = channels.firstIndex(where: { $0.id == id }) { channels[index].lastMessageID = ledger.latest[id] }
            guard permitted.contains(id), cacheLRU.contains(id) || selected?.id == id, let message = try? ChatMessage.parse(packet, channelID: id, users: users) else { return }
            remoteTyping.removeValue(forKey: message.authorID); publishTyping()
            if buffers[id] == nil { buffers[id] = MessageTimeline() }
            buffers[id]?.merge(named(message)); publish(id)
        case "MessageReact", "MessageUnreact", "MessageRemoveReaction":
            guard let channel = packet["channel_id"].string, permitted.contains(channel), let id = packet["id"].string, let emoji = packet["emoji_id"].string else { return }
            buffers[channel]?.applyReaction(id: id, emoji: emoji, user: packet["user_id"].string, remove: packet["type"].string != "MessageReact", all: packet["type"].string == "MessageRemoveReaction"); publish(channel)
        case "MessageUpdate":
            guard let channel = packet["channel"].string, permitted.contains(channel), let id = packet["id"].string else { return }
            var data = packet["data"].object ?? [:]
            for field in packet["clear"].array.compactMap(\.string) { data[field.lowercased()] = .null }
            buffers[channel]?.applyPatch(id, data: .object(data)); publish(channel)
        case "MessageDelete", "MessageDeleteBulk":
            guard let channel = packet["channel"].string, channels.contains(where: { $0.id == channel }) else { return }
            let ids = packet["id"].string.map { [$0] } ?? packet["ids"].array.compactMap(\.string)
            for id in ids {
                buffers[channel]?.delete(id)
                let fallback = buffers[channel]?.messages.filter { $0.delivery == .sent }.map(\.id).max()
                ledger.removeMessage(channelID: channel, messageID: id, fallback: fallback)
            }; publish(channel)
        case "UserUpdate":
            if let id = packet["id"].string {
                let data = packet["data"]
                if data.object?["avatar"] != nil || data.object?["profile"] != nil || data.object?["display_name"] != nil || data.object?["status"] != nil { invalidateProfile(id) }
                if let name = data["display_name"].string ?? data["username"].string { users[id] = name }
            }
        case "ChannelAck":
            guard packet["user"].string == userID, let id = packet["id"].string, let cursor = packet["message_id"].string,
                  channels.contains(where: { $0.id == id }), (try? EndpointPolicy.id(cursor)) != nil else { return }
            ledger.acknowledge(channelID: id, messageID: cursor)
        case "ChannelStartTyping", "ChannelStopTyping":
            guard let id = packet["id"].string, id == selected?.id, access.view, conversationVisible, foreground,
                  let peer = packet["user"].string, peer != userID else { return }
            if packet["type"].string == "ChannelStartTyping" { remoteTyping[peer] = Date().addingTimeInterval(typingLifetime); startTypingExpiry() }
            else { remoteTyping.removeValue(forKey: peer) }
            publishTyping()
        case "UserRelationship":
            invalidateAuthority(); refreshCatalog()
        case "ChannelUpdate":
            guard let id = packet["id"].string else { return }
            if let latest = packet["data"]["last_message_id"].string {
                ledger.observeLatest(channelID: id, messageID: latest)
                if let index = channels.firstIndex(where: { $0.id == id }) { channels[index].lastMessageID = ledger.latest[id] }
            }
            patchSnapshot(id: id, data: packet["data"], clear: packet["clear"].array.compactMap(\.string))
            let changed = Set((packet["data"].object ?? [:]).keys).union(packet["clear"].array.compactMap(\.string))
            if !changed.subtracting(["last_message_id", "name", "description", "icon", "Icon", "Description"]).isEmpty {
                invalidateAuthority(); channels = []; refreshCatalog()
            } else if let name = packet["data"]["name"].string {
                if let index = channels.firstIndex(where: { $0.id == id }) { channels[index].name = name }
                if selected?.id == id { selected?.name = name }
            }
        case "ChannelDelete":
            guard let id = packet["id"].string else { return }
            removeSnapshot(id: id); invalidateAuthority(); revoke(id); refreshCatalog()
            if selected?.id == id { error = "Bu sohbet kaldırıldı." }
        case "ChannelCreate":
            guard packet["_id"].string != nil else { return }
            var object = snapshot.object ?? [:]; object["channels"] = .array(snapshot["channels"].array + [packet]); snapshot = .object(object)
            invalidateAuthority(); refreshCatalog()
        case "ServerDelete":
            let id = packet["id"].string
            var object = snapshot.object ?? [:]; object["channels"] = .array(snapshot["channels"].array.filter { $0["server"].string != id }); snapshot = .object(object)
            invalidateAuthority(); channels = []; refreshCatalog()
        case "ServerCreate":
            var object = snapshot.object ?? [:]; object["channels"] = .array(snapshot["channels"].array + packet["channels"].array); snapshot = .object(object)
            invalidateAuthority(); refreshCatalog()
        case "ServerUpdate":
            let fields = Set((packet["data"].object ?? [:]).keys).union(packet["clear"].array.compactMap(\.string))
            if fields.subtracting(["name", "description", "icon", "Icon", "Description"]).isEmpty {
                if let id = packet["id"].string, let name = packet["data"]["name"].string {
                    for index in channels.indices where channels[index].serverID == id { channels[index].community = name }
                    if selected?.serverID == id { selected?.community = name }
                }
            } else { invalidateAuthority(); channels = []; refreshCatalog() }
        case "ServerRoleUpdate", "ServerRoleDelete", "ServerMemberUpdate", "ServerMemberLeave":
            invalidateAuthority(); channels = []; refreshCatalog()
        default: break
        }
    }
    private func patchSnapshot(id: String, data: JSONValue, clear: [String]) {
        var object = snapshot.object ?? [:]
        object["channels"] = .array(snapshot["channels"].array.map { raw in
            guard raw["_id"].string == id else { return raw }
            var fields = (raw.object ?? [:]).merging(data.object ?? [:], uniquingKeysWith: { _, new in new })
            for key in clear { fields.removeValue(forKey: key.lowercased()) }
            return .object(fields)
        }); snapshot = .object(object)
    }
    private func removeSnapshot(id: String) {
        var object = snapshot.object ?? [:]; object["channels"] = .array(snapshot["channels"].array.filter { $0["_id"].string != id }); snapshot = .object(object)
    }
}

extension ChatController {
    public func preview(channelID: String) -> ChatMessage? { buffers[channelID]?.messages.last }
    public func unread(_ channelID: String) -> Bool? { ledger.unread(channelID) }
    public func mentionCount(_ channelID: String) -> Int { ledger.available ? ledger.states[channelID]?.mentions.count ?? 0 : 0 }
    public func refreshReadStates() {
        guard let api = transport as? any SocialChatTransport, foreground else { return }
        readTask?.cancel(); readError = nil
        let login = session.advanceForRead(), acl = authority.advanceForRead(), user = userID, baseline = ledger.states
        readTask = Task { [weak self] in
            do {
                let records = try await withTimeout { try await api.readStates(userID: user) }
                guard let self, self.session.owns(login), self.authority.owns(acl), !Task.isCancelled else { return }
                self.ledger.merge(records, baseline: baseline)
            } catch {
                guard let self, self.session.owns(login), self.authority.owns(acl), !Task.isCancelled else { return }
                if error as? RoomsError == .expired { self.signalExpired() }
                else { self.readError = "Okunma bilgisi alınamadı. Tekrar dene." }
            }
        }
    }
    public func refreshDirectMessages() {
        guard let api = transport as? any SocialChatTransport, foreground else { return }
        directTask?.cancel(); directLoading = true; if failedDirectPeer == nil { directError = nil }
        let login = session.advanceForRead(), acl = authority.advanceForRead(), user = userID
        directTask = Task { [weak self] in
            do {
                let direct = try await withTimeout { try await api.directMessages(userID: user) }
                guard let self, self.session.owns(login), self.authority.owns(acl), !Task.isCancelled else { return }
                self.channels = self.channels.filter { !$0.isDirect } + direct; self.directLoading = false
                let previousDirectIDs = self.knownDirectIDs
                self.knownDirectIDs.formUnion(direct.map(\.id))
                for channel in direct {
                    self.ledger.observeLatest(channelID: channel.id, messageID: channel.lastMessageID)
                    if let peer = channel.recipients.first(where: { $0 != self.userID }) { self.users[peer] = channel.name }
                }
                let ids = Set(direct.map(\.id))
                if let selected = self.selected, selected.isDirect {
                    if let channel = direct.first(where: { $0.id == selected.id }) { self.selected = channel; self.load(older: false) }
                    else { self.revoke(selected.id); self.error = "Bu özel konuşma artık kullanılamıyor." }
                }
                for id in previousDirectIDs where !ids.contains(id) {
                    self.revoke(id)
                }
            } catch {
                guard let self, self.session.owns(login), self.authority.owns(acl), !Task.isCancelled else { return }
                self.directLoading = false
                if error as? RoomsError == .expired { self.signalExpired() }
                else { self.directError = "Özel mesajlar yüklenemedi. Tekrar dene." }
            }
        }
    }
    public func createDirectMessage(peerID: String) {
        guard let api = transport as? any SocialChatTransport, foreground, peerID != userID else { return }
        directTask?.cancel(); directLoading = false
        directOpenTask?.cancel(); let ticket = directOpenEpoch.advance()
        openingDirectFor = peerID; openedDirectID = nil; directError = nil; failedDirectPeer = peerID
        let login = session.advanceForRead(), acl = authority.advanceForRead(), user = userID
        directOpenTask = Task { [weak self] in
            do {
                let channel = try await withTimeout { try await api.createDirectMessage(peerID: peerID, userID: user) }
                guard let self, self.session.owns(login), self.authority.owns(acl), self.directOpenEpoch.owns(ticket), !Task.isCancelled else { return }
                self.channels.removeAll { $0.id == channel.id }; self.channels.append(channel); self.knownDirectIDs.insert(channel.id)
                self.ledger.observeLatest(channelID: channel.id, messageID: channel.lastMessageID)
                self.users[peerID] = channel.name; self.openingDirectFor = nil; self.failedDirectPeer = nil
                self.open(channel); self.openedDirectID = channel.id
            } catch {
                guard let self, self.session.owns(login), self.authority.owns(acl), self.directOpenEpoch.owns(ticket), !Task.isCancelled else { return }
                self.openingDirectFor = nil
                if error as? RoomsError == .expired { self.signalExpired() }
                else { self.directError = "Özel konuşma açılamadı. " + error.localizedDescription }
            }
        }
    }
    public func consumeOpenedDirectID() { openedDirectID = nil }
    public func retryDirectMessage() { if let peer = failedDirectPeer { createDirectMessage(peerID: peer) } else { refreshDirectMessages() } }
    public func setConversationVisible(_ value: Bool, channelID: String? = nil) {
        if let channelID, selected?.id != channelID { return }
        conversationVisible = value
        if !value { composing = false; stopTyping(); clearRemoteTyping(); ackTask?.cancel(); ackTask = nil; ackEpoch.advance(); ackFailed = false; visibleMessage = nil }
    }
    public func setInteractive(_ value: Bool) {
        interactive = value
        if !value { stopTyping(); clearRemoteTyping(); ackTask?.cancel(); ackTask = nil; ackEpoch.advance(); ackFailed = false }
        else { scheduleAcknowledgment() }
    }
    public func markVisible(messageID: String) {
        guard foreground, interactive, conversationVisible, !loading, access.view,
              let message = timeline.message(messageID), message.delivery == .sent, message.channelID == selected?.id else { return }
        if visibleMessage == nil || visibleMessage! < messageID { visibleMessage = messageID }
        scheduleAcknowledgment()
    }
    private func scheduleAcknowledgment() {
        guard ackTask == nil, !ackFailed, let api = transport as? any SocialChatTransport,
              foreground, interactive, conversationVisible, !loading, access.view, let id = selected?.id,
              let cursor = visibleMessage, cursor > (ledger.states[id]?.lastReadID ?? "") else { return }
        let login = session.advanceForRead(), acl = authority.advanceForRead(), choice = ackEpoch.advanceForRead()
        ackTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(300))
                guard let self, self.session.owns(login), self.authority.owns(acl), self.ackEpoch.owns(choice), !Task.isCancelled else { return }
                guard self.foreground, self.interactive, self.conversationVisible, !self.loading, self.selected?.id == id,
                      let target = self.visibleMessage, target > (self.ledger.states[id]?.lastReadID ?? "") else { self.ackTask = nil; return }
                try await withTimeout { try await api.acknowledge(channelID: id, messageID: target) }
                guard self.session.owns(login), self.authority.owns(acl), self.ackEpoch.owns(choice), !Task.isCancelled else { return }
                self.ledger.acknowledge(channelID: id, messageID: target); self.ackTask = nil; if self.ledger.available { self.readError = nil }
                self.scheduleAcknowledgment()
            } catch {
                guard let self, self.session.owns(login), self.authority.owns(acl), self.ackEpoch.owns(choice), !Task.isCancelled else { return }
                self.ackTask = nil
                if error as? RoomsError == .expired { self.signalExpired() }
                else { self.ackFailed = true; self.readError = "Okundu bilgisi kaydedilemedi. Tekrar dene." }
            }
        }
    }
    public func retryReadSync() { ackFailed = false; refreshReadStates(); scheduleAcknowledgment() }
    public func setComposing(_ value: Bool) { composing = value; if value { updateTyping() } else { stopTyping() } }
    private func updateTyping() {
        guard composing, conversationVisible, foreground, interactive, liveStatus.isEmpty, access.send,
              let id = selected?.id, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { stopTyping(); return }
        if typingChannel != id || Date().timeIntervalSince(lastTyping) >= 4 {
            typingChannel = id; lastTyping = Date(); emitTyping(channelID: id, active: true)
        }
        typingIdle?.cancel()
        typingIdle = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            guard !Task.isCancelled else { return }
            self?.stopTyping()
        }
    }
    private func emitTyping(channelID: String, active: Bool) {
        guard let sendTyping else { return }
        let previous = typingQueue, login = session.advanceForRead()
        typingQueue = Task { [weak self] in
            await previous?.value
            guard let self, self.session.owns(login), !Task.isCancelled else { return }
            _ = await sendTyping(channelID, active)
        }
    }
    private func stopTyping() {
        typingIdle?.cancel(); typingIdle = nil
        if let id = typingChannel { typingChannel = nil; emitTyping(channelID: id, active: false) }
        lastTyping = .distantPast
    }
    private func publishTyping() {
        let now = Date(); remoteTyping = remoteTyping.filter { $0.value > now }
        typingNames = remoteTyping.keys.sorted().map { users[$0] ?? "Katılımcı" }
    }
    private func startTypingExpiry() {
        guard typingExpiry == nil else { return }
        typingExpiry = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(min(1, self?.typingLifetime ?? 1))) } catch { return }
                guard !Task.isCancelled, let self else { return }; self.publishTyping()
                if self.remoteTyping.isEmpty { self.typingExpiry = nil; return }
            }
        }
    }
    private func clearRemoteTyping() { typingExpiry?.cancel(); typingExpiry = nil; remoteTyping = [:]; typingNames = [] }
    private func stopSocialRequests() {
        stopTyping(); clearRemoteTyping()
        if openingDirectFor != nil { directError = "Özel konuşma açılışı kesildi. Tekrar dene." }
        directTask?.cancel(); directOpenTask?.cancel(); directOpenEpoch.advance(); openingDirectFor = nil; directLoading = false
        readTask?.cancel(); ackTask?.cancel(); ackTask = nil; ackEpoch.advance(); ackFailed = false; visibleMessage = nil
    }
}


extension ChatController {
    private func signalExpired() { guard !hasExpired else { return }; hasExpired = true; onExpired?() }
    public var authorityGeneration: UInt64 { authority.advanceForRead() }
    public var sessionGeneration: UInt64 { session.advanceForRead() }
    public var currentAttachments: [AttachmentDraft] { selected.flatMap { attachmentDrafts[$0.id] } ?? [] }
    public var replyTarget: String? { selected.flatMap { replyTargets[$0.id] } }
    public var canSendDraft: Bool {
        access.send && !loading && draft.count <= 4000 && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !currentAttachments.isEmpty) && currentAttachments.allSatisfy { $0.state == .ready && $0.uploaded != nil } && (currentAttachments.isEmpty || access.files)
    }
    public var mentionUsers: [MentionCandidate] {
        var byID: [String: MentionCandidate] = [:]
        if let channel = selected, !channel.isDirect { for member in memberDirectory[channel.serverID] ?? [] { byID[member.id] = member } }
        for id in timeline.messages.map(\.authorID) + (selected?.recipients ?? []) where byID[id] == nil {
            byID[id] = MentionCandidate(id: id, name: users[id] ?? profileCache[id]?.name ?? "Katılımcı")
        }
        byID.removeValue(forKey: userID)
        return byID.values.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }
    /// People matching the `@query` currently typed at the end of the draft.
    public var mentionSuggestions: [MentionCandidate] {
        guard access.send, let query = MentionDraft.query(in: draft) else { return [] }
        return MentionDraft.suggestions(query, from: mentionUsers)
    }
    public func completeMention(_ candidate: MentionCandidate) {
        guard let channel = selected, let query = MentionDraft.query(in: draft) else { return }
        bindMention(candidate, into: String(draft.dropLast(query.count + 1)), channelID: channel.id)
    }
    public func displayContent(_ message: ChatMessage) -> String {
        var content = message.content
        for id in message.mentions { content = content.replacingOccurrences(of: "<@\(id)>", with: "@" + mentionName(id)) }
        return content
    }
    /// The name a `<@id>` mention shows.
    public func mentionName(_ id: String) -> String { users[id] ?? profileCache[id]?.name ?? "Katılımcı" }
    public func insertMention(_ id: String) {
        guard let channel = selected, (try? EndpointPolicy.id(id)) != nil, let candidate = mentionUsers.first(where: { $0.id == id }) else { return }
        let base = draft.isEmpty || draft.last?.isWhitespace == true ? draft : draft + " "
        bindMention(candidate, into: base, channelID: channel.id)
    }
    private func bindMention(_ candidate: MentionCandidate, into base: String, channelID: String) {
        let token = MentionDraft.token(for: candidate, among: mentionUsers)
        mentionBindings[channelID, default: [:]][token] = candidate.id
        setDraft(base + token + " ")
    }
    public func setReply(_ messageID: String?) {
        guard let id = selected?.id else { return }
        guard messageID == nil || timeline.message(messageID!)?.delivery == .sent else { return }
        replyTargets[id] = messageID
    }
    public func returnToLatest() {
        guard let id = selected?.id else { return }; olderWindows.remove(id); historyWindowLimited = false
        buffers[id]?.evictDelivered(); publish(id); load(older: false)
    }
    public func discardPending(_ id: String) { guard let channel = selected?.id, timeline.message(id)?.delivery == .failed else { return }; buffers[channel]?.delete(id); publish(channel) }
    private func touchConversation(_ id: String) {
        cacheLRU.removeAll { $0 == id }; cacheLRU.append(id)
        while cacheLRU.count > 8 {
            let old = cacheLRU.removeFirst(); buffers[old]?.evictDelivered(); more.removeValue(forKey: old); olderWindows.remove(old)
            if buffers[old]?.messages.isEmpty == true { buffers.removeValue(forKey: old) }
        }
    }
    public func addAttachment(_ file: LocalAttachment, channelID: String, expectedSession: UInt64) {
        guard session.owns(expectedSession), foreground, selected?.id == channelID, access.send, access.files, currentAttachments.count < 5 else { FileStager.remove(file.url); error = "Dosya eklenemedi. Kanalı ve dosya iznini kontrol et."; return }
        attachmentDrafts[channelID, default: []].append(AttachmentDraft(file: file)); beginUpload(file, channelID: channelID)
    }
    public func cancelAttachment(_ id: String) {
        guard let channel = selected?.id, let file = attachmentDrafts[channel]?.first(where: { $0.id == id }) else { return }
        uploads[id]?.cancel(); uploads.removeValue(forKey: id); uploadStamps.removeValue(forKey: id)
        FileStager.remove(file.file.url); attachmentDrafts[channel]?.removeAll { $0.id == id }
    }
    public func retryAttachment(_ id: String) {
        guard let channel = selected?.id, access.send, access.files, let file = attachmentDrafts[channel]?.first(where: { $0.id == id && $0.state == .failed }) else { return }
        beginUpload(file.file, channelID: channel)
    }
    private func beginUpload(_ file: LocalAttachment, channelID: String) {
        guard let api = transport as? any RichChatTransport else { return }
        uploads[file.id]?.cancel(); let stamp = UUID(); uploadStamps[file.id] = stamp
        if let index = attachmentDrafts[channelID]?.firstIndex(where: { $0.id == file.id }) { attachmentDrafts[channelID]?[index].state = .uploading; attachmentDrafts[channelID]?[index].progress = 0 }
        let login = session.advanceForRead(), acl = authority.advanceForRead(), user = userID
        uploads[file.id] = Task { [weak self] in
            let controller = self
            do {
                let uploaded = try await withTimeout(seconds: 60) {
                    let access = try await api.textAccess(channelID: channelID, userID: user)
                    guard access.view, access.send, access.files else { throw RoomsError.denied }
                    return try await api.uploadAttachment(file) { progress in
                        Task { @MainActor in
                            guard let controller, controller.session.owns(login), controller.authority.owns(acl), controller.uploadStamps[file.id] == stamp,
                                  let index = controller.attachmentDrafts[channelID]?.firstIndex(where: { $0.id == file.id && $0.state == .uploading }) else { return }
                            controller.attachmentDrafts[channelID]?[index].progress = min(1, max(0, progress))
                        }
                    }
                }
                guard let self, self.session.owns(login), self.authority.owns(acl), self.uploadStamps[file.id] == stamp, !Task.isCancelled,
                      let index = self.attachmentDrafts[channelID]?.firstIndex(where: { $0.id == file.id }) else { return }
                self.attachmentDrafts[channelID]?[index].uploaded = uploaded; self.attachmentDrafts[channelID]?[index].state = .ready; self.attachmentDrafts[channelID]?[index].progress = 1
            } catch {
                guard let self, self.session.owns(login), self.authority.owns(acl), self.uploadStamps[file.id] == stamp, !Task.isCancelled else { return }
                if let index = self.attachmentDrafts[channelID]?.firstIndex(where: { $0.id == file.id }) { self.attachmentDrafts[channelID]?[index].state = .failed }
                if error as? RoomsError == .expired { self.signalExpired() } else { self.error = "Dosya yüklenemedi. " + error.localizedDescription }
            }
            if let self, self.session.owns(login), self.uploadStamps[file.id] == stamp { self.uploads.removeValue(forKey: file.id) }
        }
    }
    public func perform(_ action: MessageAction) async -> Bool {
        guard let api = transport as? any RichChatTransport, let channel = selected?.id, let baseline = timeline.message(action.messageID), baseline.delivery == .sent, !actionBusy.contains(action.messageID), access.view else { return false }
        switch action {
        case .edit(_, let content): guard baseline.authorID == userID, access.send, content.count <= 4000, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !baseline.attachments.isEmpty else { return false }
        case .delete: guard baseline.authorID == userID else { return false }
        case .reaction: guard access.react, access.history else { return false }
        }
        let login = session.advanceForRead(), acl = authority.advanceForRead(), user = userID
        actionBusy.insert(action.messageID); actionError = nil
        let task = Task<ChatMessage?, Error> { try await withTimeout { () async throws -> ChatMessage? in
            let permission = try await api.textAccess(channelID: channel, userID: user); guard permission.view else { throw RoomsError.denied }
            switch action {
            case .edit(let id, let content): guard permission.send else { throw RoomsError.denied }; return try await api.editMessage(channelID: channel, messageID: id, content: content)
            case .delete(let id): try await api.deleteMessage(channelID: channel, messageID: id); return nil as ChatMessage?
            case .reaction(let id, let emoji, let remove): guard permission.react, permission.history else { throw RoomsError.denied }; return try await api.react(channelID: channel, messageID: id, emoji: emoji, remove: remove)
            }
        } }
        mutations[action.messageID] = task
        do {
            let result = try await task.value
            guard session.owns(login), authority.owns(acl), !Task.isCancelled else { return false }
            if let result { buffers[channel]?.applyAuthoritative(named(result), baseline: baseline) }
            else {
                buffers[channel]?.delete(action.messageID); let fallback = buffers[channel]?.messages.filter { $0.delivery == .sent }.map(\.id).max()
                ledger.removeMessage(channelID: channel, messageID: action.messageID, fallback: fallback)
            }
            publish(channel); actionBusy.remove(action.messageID); mutations.removeValue(forKey: action.messageID); failedAction = nil; return true
        } catch {
            guard session.owns(login), authority.owns(acl), !Task.isCancelled else { return false }
            actionBusy.remove(action.messageID); mutations.removeValue(forKey: action.messageID)
            if error as? RoomsError == .expired { signalExpired() }
            else { failedAction = (channel, action); actionError = "Mesaj işlemi tamamlanamadı. " + error.localizedDescription }
            return false
        }
    }
    public func retryAction() async { guard let failedAction, failedAction.channelID == selected?.id else { return }; _ = await perform(failedAction.action) }
    /// `❤`, `❤️` and a legacy `2764` key are the same reaction.
    public func reactionSelected(_ message: ChatMessage, emoji: String) -> Bool { message.reactions.contains { ReactionKey.same($0.key, emoji) && $0.value.contains(userID) } }
    /// The key to send for an emoji on this message: an equal reaction already there keeps its stored form.
    public func reactionKey(_ message: ChatMessage, for emoji: String) -> String {
        message.reactions.keys.sorted().first { ReactionKey.same($0, emoji) } ?? ReactionKey.upstream(emoji)
    }
    // MARK: GIFs and community emoji
    /// Sends a KLIPY GIF like desktop: the CDN URL is the whole message, shown as the picture.
    public func sendGif(_ url: URL) {
        guard let channel = selected, access.send, !loading, foreground, MessageMarkup.gifURL(url.absoluteString) != nil else { return }
        guard (buffers[channel.id]?.messages.filter { $0.delivery != .sent }.count ?? 0) < 20 else { error = "Bekleyen mesajları tekrar gönder veya listeden kaldır."; return }
        if olderWindows.contains(channel.id) { returnToLatest() }
        let nonce = UUID().uuidString
        let message = ChatMessage(id: "pending-" + nonce, channelID: channel.id, authorID: userID, authorName: userName, content: url.absoluteString, nonce: nonce, delivery: .sending)
        var buffer = buffers[channel.id] ?? MessageTimeline(); buffer.insertPending(message)
        buffers[channel.id] = buffer; publish(channel.id); deliver(message)
    }
    public func gifs(query: String, page: Int) async throws -> GifPage {
        guard let api = transport as? any GifTransport else { throw GifError(code: "GIFS_UNAVAILABLE") }
        let login = session.advanceForRead()
        do {
            let result = try await api.gifs(query: query, page: page)
            guard session.owns(login) else { throw CancellationError() }
            return result
        } catch { if session.owns(login), error as? RoomsError == .expired { signalExpired() }; throw error }
    }
    /// The open channel's community emoji, once per session (an older server without the route has none).
    public func loadCommunityEmojis(serverID: String) async {
        guard !serverID.isEmpty, emojiDirectory[serverID] == nil, let api = transport as? any EmojiTransport else { return }
        let login = session.advanceForRead()
        let list = (try? await withTimeout { try await api.communityEmojis(serverID: serverID) }) ?? []
        guard session.owns(login) else { return }
        emojiDirectory[serverID] = list
    }
    public func emojiName(_ id: String) -> String? { emojiDirectory.values.lazy.flatMap { $0 }.first { $0.id == id }?.name }
    public func emojiImage(_ id: String) async throws -> URL {
        if let url = emojiFiles[id] { return url }
        guard let api = transport as? any EmojiTransport else { throw RoomsError.unavailable }
        let login = session.advanceForRead()
        let task = emojiTasks[id] ?? Task { try await withTimeout(seconds: 30) { try await api.customEmoji(id: id) } }
        emojiTasks[id] = task
        let url: URL
        do { url = try await task.value } catch { if session.owns(login) { emojiTasks[id] = nil }; throw error }
        guard session.owns(login) else { FileStager.remove(url); throw CancellationError() }
        emojiTasks[id] = nil
        if let kept = emojiFiles[id], kept != url { FileStager.remove(url); return kept }
        if emojiFiles.count >= 200, let oldest = emojiFiles.keys.first, let file = emojiFiles.removeValue(forKey: oldest) { FileStager.remove(file) }
        emojiFiles[id] = url; return url
    }
    public func fetchReply(_ messageID: String, channelID: String) async throws -> ChatMessage {
        guard let api = transport as? any RichChatTransport else { throw RoomsError.unavailable }
        let login = session.advanceForRead(), acl = authority.advanceForRead(), user = userID
        let result: ChatMessage
        do { result = try await withTimeout {
            let access = try await api.textAccess(channelID: channelID, userID: user); guard access.view, access.history else { throw RoomsError.denied }
            return try await api.message(channelID: channelID, messageID: messageID)
        } } catch { if session.owns(login), error as? RoomsError == .expired { signalExpired() }; throw error }
        guard session.owns(login), authority.owns(acl), selected?.id == channelID, !Task.isCancelled else { throw CancellationError() }; return named(result)
    }
    public func download(_ attachment: ChatAttachment, message: ChatMessage) async throws -> URL {
        guard let api = transport as? any RichChatTransport, message.delivery == .sent else { throw RoomsError.denied }
        let login = session.advanceForRead(), acl = authority.advanceForRead(), user = userID
        let url: URL
        do { url = try await withTimeout { try await api.downloadAttachment(attachment, channelID: message.channelID, messageID: message.id, userID: user) } }
        catch { if session.owns(login), error as? RoomsError == .expired { signalExpired() }; throw error }
        guard session.owns(login), authority.owns(acl), selected?.id == message.channelID, !Task.isCancelled else { FileStager.remove(url); throw CancellationError() }; return url
    }
    // MARK: Inline photos
    private static let previewLimit = 80, previewConcurrency = 3
    /// A sent photo shown inside the conversation. The message list is already access-checked, so
    /// one image download is enough (desktop does the same); a few run at once and results are reused.
    public func preview(_ attachment: ChatAttachment, message: ChatMessage) async throws -> URL {
        if let url = previewFiles[attachment.id] { touchPreview(attachment.id); return url }
        guard attachment.mime.hasPrefix("image/"), message.delivery == .sent, access.history, selected?.id == message.channelID,
              let api = transport as? any RichChatTransport else { throw RoomsError.denied }
        let login = session.advanceForRead()
        let task: Task<URL, Error>
        if let existing = previewTasks[attachment.id] { task = existing }
        else {
            task = Task { [weak self] in
                await self?.acquirePreviewSlot()
                defer { Task { @MainActor [weak self] in self?.releasePreviewSlot() } }
                return try await withTimeout(seconds: 45) { try await api.imagePreview(attachment) }
            }
            previewTasks[attachment.id] = task
        }
        let url: URL
        do { url = try await task.value } catch { previewTasks[attachment.id] = nil; throw error }
        previewTasks[attachment.id] = nil
        guard session.owns(login) else { FileStager.remove(url); throw CancellationError() }
        if let kept = previewFiles[attachment.id], kept != url { FileStager.remove(url); return kept }
        previewFiles[attachment.id] = url; touchPreview(attachment.id)
        while previewOrder.count > Self.previewLimit, let oldest = previewOrder.first {
            previewOrder.removeFirst(); if let file = previewFiles.removeValue(forKey: oldest) { FileStager.remove(file) }
        }
        return url
    }
    public func cachedPreview(_ id: String) -> URL? { previewFiles[id] }
    private func touchPreview(_ id: String) { previewOrder.removeAll { $0 == id }; previewOrder.append(id) }
    private func acquirePreviewSlot() async {
        if previewRunning < Self.previewConcurrency { previewRunning += 1; return }
        await withCheckedContinuation { previewWaiters.append($0) }
    }
    private func releasePreviewSlot() {
        if previewWaiters.isEmpty { previewRunning = max(0, previewRunning - 1) } else { previewWaiters.removeFirst().resume() }
    }
    private func clearPreviews() {
        previewTasks.values.forEach { $0.cancel() }; previewTasks = [:]
        previewFiles.values.forEach(FileStager.remove); previewFiles = [:]; previewOrder = []
    }
    public func fetchProfile(_ id: String) async throws -> UserProfile {
        if let profile = profileCache[id] { return profile }
        guard let api = transport as? any RichChatTransport else { throw RoomsError.unavailable }
        let login = session.advanceForRead(), revision = profileRevisions[id, default: 0]
        let task: Task<UserProfile, Error>, stamp: UUID
        if let existing = profileTasks[id], let existingStamp = profileStamps[id] { task = existing; stamp = existingStamp }
        else {
            stamp = UUID(); profileStamps[id] = stamp
            let controller = self
            task = Task {
                while controller.activeProfiles >= 4 { try await Task.sleep(for: .milliseconds(25)); try Task.checkCancellation() }
                try Task.checkCancellation(); controller.activeProfiles += 1
                defer { controller.activeProfiles -= 1 }
                return try await withTimeout { try await api.profile(userID: id) }
            }; profileTasks[id] = task
        }
        do {
            let profile = try await task.value
            guard session.owns(login), profileRevisions[id, default: 0] == revision, profileStamps[id] == stamp else { throw CancellationError() }
            profileTasks.removeValue(forKey: id); profileCache[id] = profile
            profileLRU.removeAll { $0 == id }; profileLRU.append(id)
            while profileLRU.count > 24 { invalidateProfile(profileLRU.removeFirst()) }
            try Task.checkCancellation(); return profile
        } catch { if session.owns(login), profileStamps[id] == stamp { profileTasks.removeValue(forKey: id); if error as? RoomsError == .expired { signalExpired() } }; throw error }
    }
    public func loadAvatar(_ id: String) async throws -> URL? {
        if let url = avatarFiles[id] { return url }
        let profile = try await fetchProfile(id)
        guard let api = transport as? any RichChatTransport else { return nil }
        let login = session.advanceForRead(), revision = profileRevisions[id, default: 0]
        let task: Task<URL?, Error>, stamp: UUID
        if let existing = avatarTasks[id], let existingStamp = avatarStamps[id] { task = existing; stamp = existingStamp }
        else { stamp = UUID(); avatarStamps[id] = stamp; task = Task { try await withTimeout { try await api.avatar(profile) } }; avatarTasks[id] = task }
        do {
            let url = try await task.value
            guard session.owns(login), profileRevisions[id, default: 0] == revision, avatarStamps[id] == stamp else { if let url { FileStager.remove(url) }; throw CancellationError() }
            avatarTasks.removeValue(forKey: id); avatarFiles[id] = url
            try Task.checkCancellation(); return url
        } catch { if session.owns(login), avatarStamps[id] == stamp { avatarTasks.removeValue(forKey: id); if error as? RoomsError == .expired { signalExpired() } }; throw error }
    }
    /// After the person edits their own profile, every avatar and name shown for them reloads.
    public func refreshProfile(_ id: String) { invalidateProfile(id) }
    private func invalidateProfile(_ id: String) {
        profileRevisions[id, default: 0] += 1; profileCache.removeValue(forKey: id); profileTasks[id]?.cancel(); profileTasks.removeValue(forKey: id); profileStamps.removeValue(forKey: id)
        avatarTasks[id]?.cancel(); avatarTasks.removeValue(forKey: id); avatarStamps.removeValue(forKey: id); if let url = avatarFiles.removeValue(forKey: id) { FileStager.remove(url) }
    }
    private func removeChannelFiles(_ id: String) {
        for draft in attachmentDrafts[id] ?? [] { uploads[draft.id]?.cancel(); uploads.removeValue(forKey: draft.id); uploadStamps.removeValue(forKey: draft.id); FileStager.remove(draft.file.url) }
        attachmentDrafts.removeValue(forKey: id)
    }
    private func stopRichOperations() {
        mutations.values.forEach { $0.cancel() }; mutations = [:]; actionBusy = []; actionError = nil
        uploads.values.forEach { $0.cancel() }; uploads = [:]; uploadStamps = [:]
        for channel in attachmentDrafts.keys {
            for index in attachmentDrafts[channel]?.indices ?? [].indices where attachmentDrafts[channel]?[index].state == .uploading { attachmentDrafts[channel]?[index].state = .failed }
        }
    }
    private func clearProfiles() {
        for id in Set(profileCache.keys).union(profileTasks.keys).union(avatarTasks.keys).union(avatarFiles.keys) { invalidateProfile(id) }
        profileLRU = []
    }
    private func clearRichState() {
        stopRichOperations()
        for channel in Array(attachmentDrafts.keys) { removeChannelFiles(channel) }; attachmentDrafts = [:]; replyTargets = [:]; failedAction = nil
        clearProfiles(); profileStamps = [:]; avatarStamps = [:]; profileRevisions = [:]; clearPreviews()
        emojiTasks.values.forEach { $0.cancel() }; emojiTasks = [:]; emojiFiles.values.forEach(FileStager.remove); emojiFiles = [:]; emojiDirectory = [:]
        cacheLRU = []; olderWindows = []; historyWindowLimited = false
    }
}
