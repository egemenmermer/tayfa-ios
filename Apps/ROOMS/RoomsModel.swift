import UIKit
import Foundation
import Combine
import Network
import RoomsCore

@MainActor final class RoomsModel: ObservableObject {
    @Published private(set) var communities: [RoomCommunity] = []
    @Published private(set) var communitySelection = CommunitySelection()
    @Published var conversationPath: [String] = []
    @Published var roomExpanded = false
    @Published var roomPreview: VoiceRoom?
    @Published private(set) var communityIcons: [String: URL] = [:]
    @Published private(set) var onlineUsers: Set<String> = []
    /// The community DJ's name and picture from the server branding, for the header button.
    @Published private(set) var djName = "DJ"
    @Published private(set) var djPoster: UIImage?
    /// Looping DJ animation when the server offers an iPhone copy; shown only inside the DJ panel.
    @Published private(set) var djAnimation: URL?
    private var communityServers: [JSONValue] = []
    private var iconTasks: [String: Task<URL?, Never>] = [:]
    private var iconKeys: [String: String] = [:]
    private var iconLRU: [String] = []
    private var communityEpoch = OperationEpoch()
    private let navigationStore = CommunitySelectionStore()
    private var scrollMemory = ConversationScrollMemory()
    var selectedCommunity: RoomCommunity? { communities.first { $0.id == communitySelection.communityID } }
    func chooseCommunity(_ id: String?) {
        communitySelection.messages = id == nil
        if let id { communitySelection.communityID = id }
        conversationPath = []; chat.close(); saveNavigation()
    }
    func openChat(_ channel: TextChannel) {
        chat.open(channel); communitySelection.channelID = channel.id
        if channel.isDirect { communitySelection.messages = true }
        else { communitySelection.messages = false; communitySelection.communityID = channel.serverID }
        conversationPath = [channel.id]; saveNavigation()
    }
    /// Opens the conversation from a tapped alert; waits for the catalog if it is still loading.
    func openPendingNotification() {
        guard user != nil, let id = PushNotifications.shared.pendingChannelID, let channel = chat.channels.first(where: { $0.id == id }) else { return }
        _ = PushNotifications.shared.consumePendingChannel(); roomExpanded = false; openChat(channel)
    }
    private var pushSubscription: String?
    func subscribePush(deviceToken: String) async {
        guard let api, let user else { return }
        let key = user.id + ":" + deviceToken
        guard pushSubscription != key else { return }
        pushSubscription = key
        do { try await api.subscribePush(deviceToken: deviceToken) } catch { if pushSubscription == key { pushSubscription = nil } }
    }
    func setConversationPath(_ path: [String]) { conversationPath = path; if path.isEmpty { chat.close() } }
    func reconcileNavigation() {
        guard !chat.catalogLoading else { return }
        communitySelection.reconcile(communities: communities, permittedChannels: Set(chat.channels.map(\.id)))
        if let id = conversationPath.last, !chat.channels.contains(where: { $0.id == id }) { conversationPath = []; chat.close() }
        scrollMemory.reconcile(permitted: Set(chat.channels.map(\.id))); saveNavigation()
        openPendingNotification()
    }
    func scrollAnchor(for id: String) -> String? { scrollMemory.anchor(for: id) }
    func rememberScroll(channel: String, anchor: String) { scrollMemory.remember(channelID: channel, anchor: anchor) }
    func communityID(for room: VoiceRoom) -> String? { voiceServers[room.id] }
    private func saveNavigation() { if let user { navigationStore.save(communitySelection, origin: origin, owner: user.id) } }
    func consumeDirectMessage() {
        guard let id = chat.openedDirectID, let channel = chat.channels.first(where: { $0.id == id }) else { return }
        openChat(channel); chat.consumeOpenedDirectID()
    }
    private func clearCommunityIcons() {
        communityEpoch.advance(); iconTasks.values.forEach { $0.cancel() }; iconTasks = [:]
        communityIcons.values.forEach { FileStager.remove($0) }; communityIcons = [:]; iconKeys = [:]; iconLRU = []
    }
    func loadCommunityIcon(_ community: RoomCommunity) async {
        guard let api, let iconID = community.iconID else { return }
        let key = community.id + ":" + iconID
        if iconKeys[community.id] == iconID, communityIcons[community.id] != nil { return }
        if let task = iconTasks[key] { _ = await task.value; return }
        guard iconTasks.count < 4 else { return }
        let ticket = communityEpoch.advanceForRead(), login = sessionEpoch.advanceForRead()
        let task = Task { [weak self] () -> URL? in
            do {
                let file = try await api.communityIcon(serverID: community.id, iconID: iconID)
                guard let self, self.sessionEpoch.owns(login), self.communityEpoch.owns(ticket), !Task.isCancelled,
                      self.communities.contains(where: { $0.id == community.id && $0.iconID == iconID }) else { if let file { FileStager.remove(file) }; return nil }
                if let old = self.communityIcons[community.id] { FileStager.remove(old) }
                self.communityIcons[community.id] = file; self.iconKeys[community.id] = iconID
                self.iconLRU.removeAll { $0 == community.id }; self.iconLRU.append(community.id)
                while self.iconLRU.count > 24 { let old = self.iconLRU.removeFirst(); if let file = self.communityIcons.removeValue(forKey: old) { FileStager.remove(file) }; self.iconKeys.removeValue(forKey: old) }
                return file
            } catch {
                if error as? RoomsError == .expired, let self, self.sessionEpoch.owns(login) { await self.expire() }
                return nil
            }
        }
        iconTasks[key] = task; _ = await task.value
        if communityEpoch.owns(ticket) { iconTasks.removeValue(forKey: key) }
    }
    @Published private(set) var user: RoomsUser?
    @Published private(set) var rooms: [VoiceRoom] = []
    @Published private(set) var directory: [String: Directory.Entry] = [:]
    @Published private(set) var active: VoiceRoom?
    @Published private(set) var busy = false
    @Published private(set) var restoring = true
    /// Set when a saved session could not be restored because the server was unreachable (B5).
    /// The token stays saved; `RestoreRetryView` offers a retry instead of the login form.
    @Published private(set) var restoreProblem: String?
    @Published private(set) var restoreRetrying = false
    private var restoreFailures = 0
    private var restoreTimer: Task<Void, Never>?
    private var pendingLogoutTask: Task<Void, Never>?
    private let pathMonitor = NWPathMonitor()
    private var pathSignature: String?
    private var pathDebounce: Task<Void, Never>?
    @Published private(set) var listStatus = ""
    @Published var error: String?
    @Published var showingMessages = false
    private(set) var initialChatChannelID: String?
    func openDirectMessage(_ peerID: String) { roomExpanded = false; communitySelection.messages = true; initialChatChannelID = nil; chat.createDirectMessage(peerID: peerID) }
    func openMessages(channelID: String? = nil) {
        roomExpanded = false
        if let channelID, let channel = chat.channels.first(where: { $0.id == channelID }) { openChat(channel) }
        else { chooseCommunity(nil) }
    }
    let media = RoomMedia()
    let chat = ChatController()
    let calls = DMCallModel()
    /// A short line about the joined room that the person did not cause, e.g. a moderator's move.
    @Published private(set) var roomNotice: String?
    private var roomNoticeTimer: Task<Void, Never>?
    /// Community cinema halls (Sinema); its changes redraw the views that observe this model.
    let cinema = CinemaHub()
    private var cinemaChanges: AnyCancellable?
    private let gateway = Gateway()
    private var api: APIClient?
    /// The room DJ follows the joined voice room; nil while not connected.
    func musicClient() -> (api: APIClient, channel: String)? {
        guard let api, let room = active, media.connected else { return nil }
        return (api, room.id)
    }
    private var token: String?
    private var sessionEpoch = OperationEpoch()
    private var roomEpoch = OperationEpoch()
    private var joinDeadline: Task<Void, Never>?
    private var roomTask: Task<Void, Never>?
    private var polling: Task<Void, Never>?
    private var candidates: [VoiceRoom] = []
    private var voiceServers: [String: String] = [:]
    private var foreground = true
    private let origin: URL
    private let originConfigured: Bool
    init() {
        let configured = Bundle.main.object(forInfoDictionaryKey: "ROOMSAPIOrigin") as? String ?? ""
        // A missing or broken server configuration must fail closed, never silently use another server.
        let parsed = try? EndpointPolicy.origin(configured)
        origin = parsed ?? URL(string: "https://invalid.invalid")!
        originConfigured = parsed != nil
        gateway.onPacket = { [weak self] packet in self?.process(packet) }
        gateway.onStatus = { [weak self] status in self?.listStatus = status; self?.chat.setLiveStatus(status.replacingOccurrences(of: "Odalar", with: "Mesajlar")) }
        gateway.onExpired = { [weak self] in Task { await self?.expire() } }
        chat.sendTyping = { [weak self] channel, active in await self?.gateway.typing(channelID: channel, active: active) ?? false }
        chat.onExpired = { [weak self] in Task { await self?.expire() } }
        cinemaChanges = cinema.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        media.onHearingChange = { [weak self] deafened in
            guard let self, let api = self.api, let room = self.active else { return }
            Task { _ = try? await api.deafen(channel: room.id, deafened: deafened) }
        }
        media.handleData(topic: MoveSignal.topic) { [weak self] packet in self?.receiveMove(packet) }
        calls.attach(media: media, leaveVoice: { [weak self] in await self?.leaveForCall() }, voiceBusy: { [weak self] in self?.busy ?? false })
    }
    func restore() async {
        defer { restoring = false }
        startNetworkMonitor(); retryPendingLogouts()
        await attemptRestore()
    }
    /// "Tekrar dene" on the restore screen, and the automatic retries (timer, network, foreground).
    func retryRestore() async {
        guard restoreProblem != nil, user == nil, !restoreRetrying, !busy else { return }
        await attemptRestore()
    }
    private func attemptRestore() async {
        restoreTimer?.cancel()
        let ticket = sessionEpoch.advance()
        restoreRetrying = true
        defer { if sessionEpoch.owns(ticket) { restoreRetrying = false } }
        do {
            guard let token = try SessionVault.read(origin: origin) else { restoreProblem = nil; return }
            let api = APIClient(origin: origin, token: token)
            let user = try await api.user()
            guard sessionEpoch.owns(ticket) else { return }
            accept(api: api, token: token, user: user)
        } catch {
            guard sessionEpoch.owns(ticket) else { return }
            switch SessionRestoreOutcome(error: error) {
            case .signedOut:
                SessionVault.clear(); restoreProblem = nil; restoreFailures = 0
            case .retry:
                restoreFailures += 1; restoreProblem = error.localizedDescription
                scheduleRestoreRetry()
            }
            // Until RootView shows RestoreRetryView, the login form keeps explaining the failure.
            self.error = error.localizedDescription
        }
    }
    private func scheduleRestoreRetry() {
        restoreTimer?.cancel()
        let delay = ReconnectBackoff.delay(failures: restoreFailures, cap: ReconnectBackoff.restoreCap, jitter: Double.random(in: 0...1))
        restoreTimer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, self.foreground else { return }
            await self.retryRestore()
        }
    }
    func login(email: String, password: String) async {
        guard !busy else { return }; busy = true; error = nil
        restoreTimer?.cancel(); restoreProblem = nil; restoreRetrying = false
        let ticket = sessionEpoch.advance()
        defer { if sessionEpoch.owns(ticket) { busy = false } }
        do {
            guard originConfigured else { throw RoomsError.invalidEndpoint }
            let origin = self.origin
            let (api, token, user) = try await withTimeout {
                let token = try await APIClient.login(origin: origin, email: email.trimmingCharacters(in: .whitespacesAndNewlines), password: password)
                let api = APIClient(origin: origin, token: token)
                return (api, token, try await api.user())
            }
            guard sessionEpoch.owns(ticket) else { return }
            // A saved session that could not be restored is replaced: end it on the server later.
            if let old = try? SessionVault.read(origin: origin), old != token { try? SessionVault.addPendingLogout(token: old, origin: origin) }
            try SessionVault.save(token, origin: origin); accept(api: api, token: token, user: user)
        } catch { if sessionEpoch.owns(ticket) { self.error = error.localizedDescription } }
    }
    private func accept(api: APIClient, token: String, user: RoomsUser) {
        media.useAudioPreferences(origin: origin, userID: user.id, soundClient: api)
        chat.configure(transport: api, userID: user.id, userName: user.name)
        calls.configure(api: api, userID: user.id, account: origin.absoluteString + "|" + user.id)
        cinema.configure(api: api, me: user.id)
        restoreTimer?.cancel(); restoreProblem = nil; restoreFailures = 0; retryPendingLogouts()
        self.api = api; self.token = token; self.user = user; pushSubscription = nil; PushNotifications.shared.model = self; Task { await PushNotifications.shared.enable() }; communitySelection = navigationStore.load(origin: origin, owner: user.id); communitySelection.messages = false; error = nil; retryList()
        Task { [weak self] in
            guard let branding = try? await api.musicBranding(), let self, self.api === api else { return }
            self.djName = branding.name
            if let url = branding.poster { self.djPoster = UIImage(contentsOfFile: url.path); FileStager.remove(url) }
            if let animation = await api.musicAnimation() {
                // A clip that cannot be decoded here would leave an empty space; the poster stays instead.
                guard self.api === api, await animationDecodes(animation) else { FileStager.remove(animation); return }
                if let old = self.djAnimation { FileStager.remove(old) }
                self.djAnimation = animation
            }
        }
    }
    func retryList() {
        guard let api, let token else { return }
        gateway.start(api: api, token: token); startPolling()
    }
    private func startPolling() {
        polling?.cancel()
        polling = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled && self.foreground && self.user != nil {
                await self.refreshDirectory()
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
    }
    private func process(_ packet: JSONValue) {
        chat.process(packet)
        switch packet["type"].string {
        case "Ready":
            communityServers = packet["servers"].array
            communities = RoomCommunity.fromReady(packet)
            onlineUsers = Set(packet["users"].array.filter { $0["online"] == .bool(true) }.compactMap { $0["_id"].string })
            candidates = VoiceRoom.fromReady(packet)
            voiceServers = Dictionary(packet["channels"].array.compactMap { value -> (String, String)? in
                guard let id = value["_id"].string, let server = value["server"].string else { return nil }; return (id, server)
            }, uniquingKeysWith: { _, last in last })
            let names = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
            if let active, let updated = names[active.id] { self.active = updated }
            Task { await refreshDirectory() }
        case "ChannelDelete":
            if let id = packet["id"].string { candidates.removeAll { $0.id == id }; rooms.removeAll { $0.id == id }; if active?.id == id { leave(); error = "Oda artık kullanılamıyor." } }
        case "ChannelUpdate":
            let fields = Set((packet["data"].object ?? [:]).keys).union(packet["clear"].array.compactMap(\.string))
            let presentation: Set<String> = ["last_message_id", "name", "description", "icon", "Icon", "Description"]
            if fields.subtracting(presentation).isEmpty {
                if let id = packet["id"].string, let name = packet["data"]["name"].string {
                    candidates = candidates.map { $0.id == id ? VoiceRoom(id: id, name: name, community: $0.community) : $0 }
                    rooms = rooms.map { $0.id == id ? VoiceRoom(id: id, name: name, community: $0.community) : $0 }
                    if let room = active, room.id == id { active = VoiceRoom(id: id, name: name, community: room.community) }
                }
            } else { refreshVoiceAuthority() }
        case "ServerUpdate":
            if let id = packet["id"].string {
                communityServers = communityServers.map { raw in
                    guard raw["_id"].string == id else { return raw }
                    var data = raw.object ?? [:]
                    for (key, value) in packet["data"].object ?? [:] { data[key] = value }
                    for clear in packet["clear"].array.compactMap(\.string) { data.removeValue(forKey: clear.lowercased()) }
                    return .object(data)
                }
                communities = RoomCommunity.fromReady(.object(["servers": .array(communityServers)]))
                if let old = communityIcons.removeValue(forKey: id) { FileStager.remove(old) }; iconKeys.removeValue(forKey: id)
            }
            let fields = Set((packet["data"].object ?? [:]).keys).union(packet["clear"].array.compactMap(\.string))
            if fields.subtracting(["name", "description", "icon", "Icon", "Description"]).isEmpty {
                if let id = packet["id"].string, let name = packet["data"]["name"].string {
                    candidates = candidates.map { voiceServers[$0.id] == id ? VoiceRoom(id: $0.id, name: $0.name, community: name) : $0 }
                    rooms = rooms.map { voiceServers[$0.id] == id ? VoiceRoom(id: $0.id, name: $0.name, community: name) : $0 }
                    if let room = active, voiceServers[room.id] == id { active = VoiceRoom(id: room.id, name: room.name, community: name) }
                }
            } else { refreshVoiceAuthority() }
        case "UserUpdate":
            if let id = packet["id"].string, packet["data"]["online"] != .null {
                if packet["data"]["online"] == .bool(true) { onlineUsers.insert(id) } else { onlineUsers.remove(id) }
            }
        case "ServerRoleUpdate", "ServerRoleDelete", "ServerMemberUpdate", "ServerMemberLeave", "ServerDelete", "ChannelCreate", "ServerCreate":
            clearCommunityIcons()
            if packet["type"].string == "ServerDelete", let id = packet["id"].string { communities.removeAll { $0.id == id } }
            refreshVoiceAuthority()
        default: break
        }
    }
    private var directoryBusy = false
    private func refreshDirectory() async {
        guard !directoryBusy, let api, user != nil, !candidates.isEmpty else {
            if candidates.isEmpty, user != nil, listStatus.isEmpty { rooms = []; directory = [:] }; return
        }
        directoryBusy = true; defer { directoryBusy = false }
        let ticket = sessionEpoch.advanceForRead()
        do {
            let snapshot = try await api.directory(ids: candidates.map(\.id))
            guard sessionEpoch.owns(ticket), !Task.isCancelled else { return }
            directory = Dictionary(snapshot.rooms.map { ($0.channelId, $0) }, uniquingKeysWith: { _, last in last })
            rooms = candidates.filter { directory[$0.id] != nil }
            listStatus = ""
        } catch {
            guard sessionEpoch.owns(ticket), !Task.isCancelled else { return }
            if error as? RoomsError == .expired { await expire() }
            else { directory = [:]; listStatus = "Oda bilgileri alınamadı. Tekrar dene." }
        }
    }
    private func validateActive() async {
        guard let api, let active else { return }
        let login = sessionEpoch.advanceForRead(), room = roomEpoch.advanceForRead()
        do { _ = try await api.channel(active.id) }
        catch {
            guard sessionEpoch.owns(login), roomEpoch.owns(room), self.active?.id == active.id else { return }
            if error as? RoomsError == .expired { await expire() }
            else if error as? RoomsError == .denied { leave(); self.error = "Odaya erişimin değişti." }
        }
    }
    private func refreshVoiceAuthority() {
        let login = sessionEpoch.advanceForRead()
        Task {
            await validateActive()
            guard sessionEpoch.owns(login), foreground, user != nil else { return }
            retryList()
        }
    }
    /// `expand: false` keeps the current screen (a moderator's move must not take over the app).
    func join(_ target: VoiceRoom, resumeInterruptedMicrophone: Bool = false, expand: Bool = true) {
        guard let api, user != nil else { return }
        // A private call holds the media connection, as on desktop.
        if let reason = calls.voiceBlockReason { error = reason; return }
        if expand { roomExpanded = true }; roomPreview = nil
        if active?.id == target.id && media.connected { return }
        // The microphone as it was left: the room being switched from, else the saved choice (RC24).
        let wantsMicrophone = resumeInterruptedMicrophone || media.microphoneForJoin()
        let ticket = roomEpoch.advance()
        let previous = roomTask; previous?.cancel()
        busy = true; error = nil
        joinDeadline?.cancel()
        joinDeadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(25))
            guard !Task.isCancelled, let self, self.roomEpoch.owns(ticket), self.busy else { return }
            let cleanup = self.roomEpoch.advance(); self.roomTask?.cancel(); await self.media.disconnect()
            guard self.roomEpoch.owns(cleanup) else { return }
            self.busy = false; self.error = "Odaya bağlanılamadı. Tekrar dene."
        }
        roomTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.roomEpoch.owns(ticket) { self.joinDeadline?.cancel() } }
            let microphoneIntent = self.media.microphoneIntentRevision
            // Interrupt a connecting transport before awaiting its old operation.
            await self.media.disconnect(); await previous?.value
            guard self.roomEpoch.owns(ticket), !Task.isCancelled, self.user != nil else { return }
            if let old = self.active { try? await api.leave(channel: old.id) }
            guard self.roomEpoch.owns(ticket), !Task.isCancelled else { return }
            self.active = target
            let login = self.sessionEpoch.advanceForRead()
            self.media.onInterruptionRecovery = { [weak self] microphone in
                guard let self, self.sessionEpoch.owns(login), self.roomEpoch.owns(ticket),
                      self.active?.id == target.id, self.user != nil, !self.busy else { return }
                self.join(target, resumeInterruptedMicrophone: microphone)
            }
            do {
                let grant = try await api.grant(channel: target.id)
                guard self.roomEpoch.owns(ticket), !Task.isCancelled else { return }
                try await self.media.connect(grant: grant, soundChannel: target.id)
                // After connect: connecting first tears down the previous room, including its lease hook.
                self.media.screenLease = { acquire in try await api.screenLease(channel: target.id, acquire: acquire) }
                guard self.roomEpoch.owns(ticket), !Task.isCancelled else { await self.media.disconnect(); return }
                if wantsMicrophone && self.media.muted && self.media.microphoneIntentRevision == microphoneIntent { await self.media.toggleMicrophone(remember: false) }
            } catch {
                guard self.roomEpoch.owns(ticket), !Task.isCancelled else { return }
                await self.media.disconnect()
                guard self.roomEpoch.owns(ticket), !Task.isCancelled else { return }
                if error as? RoomsError == .expired { Task { await self.expire() } }
                else { self.error = "Odaya bağlanılamadı. Tekrar dene." }
            }
            if self.roomEpoch.owns(ticket) { self.busy = false }
        }
    }
    /// A private call takes over the media connection: the voice room is left and its teardown awaited.
    func leaveForCall() async {
        guard active != nil || busy else { return }
        leave(); await roomTask?.value
    }
    /// The server's `rooms-move-v1`: a moderator moved this person, who joins the target through the normal grant.
    private func receiveMove(_ packet: RoomDataPacket) {
        guard packet.fromServer, let move = MoveSignal.parse(packet.payload), user != nil, let current = active, move.channelID != current.id else { return }
        let target = candidates.first { $0.id == move.channelID } ?? VoiceRoom(id: move.channelID, name: "Oda", community: current.community)
        let mover = move.by.flatMap { id in media.people.first { $0.id == id }?.name }
        showRoomNotice("\(mover ?? "Bir yönetici") seni \(target.name) odasına taşıdı.")
        join(target, expand: false)
    }
    private func showRoomNotice(_ text: String) {
        roomNotice = text; roomNoticeTimer?.cancel()
        roomNoticeTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            if !Task.isCancelled { self?.roomNotice = nil }
        }
    }
    /// Moderation for one person in the joined voice room (desktop `VoiceMemberMenu`); nil for yourself.
    func voiceModeration(for person: RoomPerson) -> VoiceModerationContext? {
        guard let api, let user, let room = active, let server = voiceServers[room.id], !person.local, person.id != user.id,
              !person.id.hasPrefix("rooms-music-") else { return nil }
        return VoiceModerationContext(api: api, me: user.id, serverID: server, room: room, otherRooms: candidates.filter { voiceServers[$0.id] == server && $0.id != room.id })
    }
    func leave() {
        roomExpanded = false; roomPreview = nil
        joinDeadline?.cancel()
        let ticket = roomEpoch.advance(); let old = active; let api = api
        let previous = roomTask; previous?.cancel(); active = nil; busy = false
        roomTask = Task { [weak self] in
            guard let self else { return }; await self.media.disconnect(); await previous?.value
            if let old, let api { try? await api.leave(channel: old.id) }
            if self.roomEpoch.owns(ticket) { self.busy = false }
            await self.refreshDirectory()
        }
    }
    /// Who is in a voice room. The joined room uses the live LiveKit roster (joins and leaves show at
    /// once); other rooms use the 5 s directory without this account, as desktop shows it.
    func occupants(_ roomID: String) -> [Directory.Occupant] {
        if active?.id == roomID, media.connected {
            return media.people.map { person in
                Directory.Occupant(id: person.id, name: person.name, muted: person.muted,
                                   screen: media.streams.contains { $0.participantID == person.id } || (person.local && media.sharingScreen),
                                   deafened: person.deafened)
            }
        }
        return (directory[roomID]?.participants ?? []).filter { $0.id != user?.id }
    }
    func friends() async throws -> [Friend] { guard let api else { throw RoomsError.expired }; return try await api.friends() }
    func addFriend(_ handle: String) async throws { guard let api else { throw RoomsError.expired }; try await api.addFriend(handle: handle) }
    func removeFriend(_ id: String) async throws { guard let api else { throw RoomsError.expired }; try await api.removeFriend(id: id) }
    func unblock(_ id: String) async throws { guard let api else { throw RoomsError.expired }; try await api.unblock(id: id) }
    /// The same https `/davet/` link desktop copies: it opens a page that downloads Tayfa and
    /// joins with the invitation. Older non-token codes keep the `rooms://invite` app link.
    func createInvite(channelID: String) async throws -> (code: String, link: String, expiresAt: Date?) {
        guard let api else { throw RoomsError.expired }
        let invite = try await api.createInvite(channel: channelID)
        let origin = await api.origin
        let expires = invite.expiresAt.flatMap { value -> Date? in
            let precise = ISO8601DateFormatter(); precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return precise.date(from: value) ?? ISO8601DateFormatter().date(from: value)
        }
        if invite.code.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
           var page = URLComponents(url: origin, resolvingAgainstBaseURL: false) {
            page.path = "/davet/\(invite.code)"; page.query = nil; page.fragment = nil
            if let link = page.url?.absoluteString { return (invite.code, link, expires) }
        }
        var parts = URLComponents(); parts.scheme = "rooms"; parts.host = "invite"
        parts.queryItems = [URLQueryItem(name: "server", value: origin.absoluteString), URLQueryItem(name: "code", value: invite.code)]
        return (invite.code, parts.url?.absoluteString ?? "", expires)
    }
    /// The shared activity of a voice room the person is in (Birlikte izle).
    func watchTogether(roomID: String) -> WatchTogetherModel? {
        guard let api, let user else { return nil }
        return WatchTogetherModel(api: api, roomID: roomID, me: user.id)
    }
    func loadOwnProfile() async throws -> OwnProfile {
        guard let api else { throw RoomsError.expired }
        return try await api.ownProfile()
    }
    /// Saves the edited fields, then the new or removed avatar, and reloads every place showing them.
    func saveProfile(_ profile: OwnProfile, avatar: (data: Data, mime: String)?, removeAvatar: Bool) async throws {
        guard let api else { throw RoomsError.expired }
        var updated = try await api.updateProfile(profile)
        if let avatar { updated = try await api.uploadAvatar(avatar.data, mime: avatar.mime) }
        else if removeAvatar { updated = try await api.removeAvatar() }
        user = updated
        chat.refreshProfile(updated.id)
    }
    /// Signs out at once, also offline (B4). The token is kept as a pending logout until the server
    /// confirms the session (and with it the push subscription) is gone; until then this device
    /// stops taking alerts.
    func logout() async {
        let token = self.token ?? (try? SessionVault.read(origin: origin))
        if let token { try? SessionVault.addPendingLogout(token: token, origin: origin) }
        restoreTimer?.cancel(); restoreProblem = nil; restoreFailures = 0; error = nil
        await clearSession()
        guard let token else { return }
        if !(await endSession(PendingLogout(origin: origin.absoluteString, token: token))) {
            PushNotifications.shared.signedOut(stopDelivery: true)
        }
    }
    /// True when the server ended the session or it can never be used again; the entry is then dropped.
    private func endSession(_ item: PendingLogout) async -> Bool {
        guard let origin = try? EndpointPolicy.origin(item.origin) else { SessionVault.removePendingLogout(item); return true }
        let api = APIClient(origin: origin, token: item.token)
        do { try await withTimeout(seconds: 15) { try await api.endSession() } }
        catch { guard PendingLogout.isFinished(after: error) else { return false } }
        SessionVault.removePendingLogout(item); return true
    }
    /// Retries sessions signed out while offline: on launch, sign-in, foreground and network return.
    private func retryPendingLogouts() {
        guard pendingLogoutTask == nil else { return }
        let queue = SessionVault.pendingLogouts()
        guard !queue.isEmpty else { return }
        pendingLogoutTask = Task { [weak self] in
            for item in queue.items { guard let self else { return }; _ = await self.endSession(item) }
            self?.pendingLogoutTask = nil
        }
    }
    private func startNetworkMonitor() {
        guard pathMonitor.pathUpdateHandler == nil else { return }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let signature = path.status == .satisfied ? "up:" + (path.availableInterfaces.first.map { "\($0.type)" } ?? "") : "down"
            Task { @MainActor [weak self] in self?.networkChanged(signature) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.egemenmermer.rooms.network"))
    }
    /// Network back or the primary interface changed: reconnect the gateway now instead of waiting
    /// for its backoff, retry an offline restore, and finish pending sign-outs (B5, B6).
    private func networkChanged(_ signature: String) {
        let previous = pathSignature; pathSignature = signature
        guard let previous, previous != signature, signature != "down" else { return }
        // Down -> up: only a gateway that is not live reconnects. A new primary interface usually
        // strands the old socket, so it reconnects even if it still looks live.
        let interfaceChanged = previous != "down"
        pathDebounce?.cancel()
        pathDebounce = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            guard let self, self.foreground else { return }
            self.retryPendingLogouts()
            if self.user != nil { self.gateway.reconnectNow(force: interfaceChanged) }
            else { await self.retryRestore() }
        }
    }
    private func expire() async { await clearSession(); error = RoomsError.expired.localizedDescription }
    private func clearSession() async {
        await calls.reset()
        clearCommunityIcons(); communities = []; communityServers = []; communitySelection = .init(); conversationPath = []; onlineUsers = []; scrollMemory = .init()
        // B8: nothing of the previous account survives the sign-out.
        roomNoticeTimer?.cancel(); roomNotice = nil; listStatus = ""; pushSubscription = nil
        djName = "DJ"; djPoster = nil; if let animation = djAnimation { FileStager.remove(animation) }; djAnimation = nil
        PushNotifications.shared.signedOut(stopDelivery: false)
        sessionEpoch.advance(); showingMessages = false; initialChatChannelID = nil; cinema.reset(); chat.reset(); gateway.stop(); polling?.cancel(); SessionVault.clear(); token = nil; user = nil; rooms = []; candidates = []; voiceServers = [:]; directory = [:]
        leave(); api = nil; await roomTask?.value; if user == nil { media.clearAudioPreferences() }
    }
    func setForeground(_ value: Bool) {
        guard foreground != value else { return }
        foreground = value; media.setForeground(value); chat.setForeground(value); calls.setForeground(value); cinema.setForeground(value)
        if value { retryPendingLogouts() }
        if value, user != nil { retryList(); Task { await validateActive() } }
        else if value { Task { await retryRestore() } }
        else { gateway.stop(); polling?.cancel() }
    }
}
