import SwiftUI
import RoomsCore

/// Browsing text channels never owns or tears down the voice connection.
struct ChatBrowserView: View {
    @ObservedObject var model: RoomsModel
    @ObservedObject var chat: ChatController
    @ObservedObject var media: RoomMedia
    var initialChannelID: String? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var path: [String] = []
    @State private var attemptedInitialChannel = false
    var body: some View {
        NavigationStack(path: $path) {
            List {
                if chat.openingDirectFor != nil { Section { ProgressView("Özel konuşma açılıyor…") } }
                if let error = chat.directError { Section { Text(error).foregroundStyle(.secondary); Button("Tekrar dene") { chat.retryDirectMessage() } } }
                if let error = chat.readError { Section { Text(error).foregroundStyle(.secondary); Button("Okunma bilgisini yenile") { chat.retryReadSync() } } }
                Section("Özel mesajlar") {
                    if chat.directLoading { ProgressView("Özel mesajlar yükleniyor…") }
                    ForEach(chat.channels.filter(\.isDirect)) { channel in
                        Button { chat.open(channel); path.append(channel.id) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "person.crop.circle").foregroundStyle(Palette.accent)
                                Text(channel.name).foregroundStyle(.primary); Spacer()
                                ChatUnreadBadge(chat: chat, channelID: channel.id)
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                            }.frame(minHeight: 44)
                        }.accessibilityIdentifier("chat.dm.\(channel.id)")
                    }
                    if !chat.directLoading && !chat.channels.contains(where: \.isDirect) { Text("Henüz özel konuşma yok. Odadaki bir kişiden mesaj açabilirsin.").font(.footnote).foregroundStyle(.secondary) }
                }
                if chat.catalogLoading { Section { ProgressView("Sohbetler yükleniyor…") } }
                if let error = chat.catalogError {
                    Section { Text(error).foregroundStyle(.secondary); Button("Tekrar dene") { chat.retryCatalog() } }
                }
                if !chat.liveStatus.isEmpty {
                    Section { Text(chat.liveStatus).font(.footnote).foregroundStyle(.secondary); Button("Bağlantıyı yenile") { model.retryList() } }
                }
                if chat.channels.isEmpty && !chat.catalogLoading && chat.catalogError == nil && chat.liveStatus.isEmpty {
                    ContentUnavailableView("Metin kanalı yok", systemImage: "text.bubble", description: Text("Bu hesap için erişilebilir metin kanalı bulunamadı."))
                }
                ForEach(Array(Set(chat.channels.filter { !$0.isDirect }.map(\.serverID))).sorted(), id: \.self) { serverID in
                    Section(chat.channels.first(where: { $0.serverID == serverID })?.community ?? "Topluluk") {
                        ForEach(chat.channels.filter { $0.serverID == serverID }) { channel in
                            Button { chat.open(channel); path.append(channel.id) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "number").foregroundStyle(Palette.accent)
                                    Text(channel.name).foregroundStyle(.primary)
                                    Spacer()
                                    ChatUnreadBadge(chat: chat, channelID: channel.id)
                                    if !channel.access.send { Image(systemName: "lock").foregroundStyle(.secondary).accessibilityLabel("Salt okunur") }
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                                }.frame(minHeight: 44)
                            }.accessibilityIdentifier("chat.channel.\(channel.id)")
                        }
                    }
                }
            }.scrollContentBackground(.hidden).background(Palette.canvas).navigationTitle("Mesajlar")
                .refreshable { chat.retryCatalog() }
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Kapat") { dismiss() } } }
                .navigationDestination(for: String.self) { id in ChatConversationView(chat: chat, currentUserID: model.user?.id ?? "", channelID: id) }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { ChatVoiceBar(model: model, media: media) { dismiss() } }
        .onChange(of: path) { _, path in if path.isEmpty { chat.close() } }
        .onChange(of: chat.channels) { _, _ in openRequestedDirectIfAvailable(); openInitialIfAvailable() }
        .onChange(of: chat.openedDirectID) { _, _ in openRequestedDirectIfAvailable() }
        .onAppear { openRequestedDirectIfAvailable(); openInitialIfAvailable() }
        .onDisappear { chat.close() }
        .tint(Palette.accent)
    }
    private func openRequestedDirectIfAvailable() {
        guard let id = chat.openedDirectID, let channel = chat.channels.first(where: { $0.id == id }) else { return }
        attemptedInitialChannel = true
        if chat.selected?.id != id { chat.open(channel) }
        path = [id]; chat.consumeOpenedDirectID()
    }
    private func openInitialIfAvailable() {
        guard !attemptedInitialChannel, chat.openingDirectFor == nil, chat.openedDirectID == nil, path.isEmpty, let id = initialChannelID,
              let channel = chat.channels.first(where: { $0.id == id }) else { return }
        attemptedInitialChannel = true; chat.open(channel); path = [id]
    }
}

struct ChatConversationView: View {
    @ObservedObject var chat: ChatController
    let currentUserID: String
    let channelID: String
    var model: RoomsModel? = nil
    var obscuredRect = CGRect.zero
    @State private var viewportGlobal = CGRect.zero
    @State private var pickerPresented = false
    private var overlayPresented: Bool { pickerPresented || editingMessage != nil || deletingMessage != nil || viewingAttachment != nil || viewingProfile != nil || viewingReply != nil || reactingMessage != nil }
    @FocusState private var composing: Bool
    @State private var initiallyScrolled = false
    @State private var nearBottom = true
    @State private var olderAnchor: String?
    @State private var newMessages = false
    @State private var editingMessage: ChatMessage?
    @State private var deletingMessage: ChatMessage?
    @State private var reactingMessage: ChatMessage?
    @State private var viewingAttachment: FileRequest?
    @State private var viewingProfile: ProfileRequest?
    @State private var viewingReply: ReplyRequest?
    @State private var pendingProfilePeer: String?
    @State private var rowFrames: [String: CGRect] = [:]
    @State private var viewportHeight: CGFloat = 0
    @State private var capturedUnread = false
    @State private var unreadBoundary: String?
    private var groupedIDs: Set<String> {
        var result: Set<String> = []
        for (previous, current) in zip(messages, messages.dropFirst()) where previous.authorID == current.authorID && current.replyIDs.isEmpty && current.created != .distantPast && current.created.timeIntervalSince(previous.created) >= 0 && current.created.timeIntervalSince(previous.created) < 300 && Calendar.current.isDate(previous.created, inSameDayAs: current.created) { result.insert(current.id) }
        return result
    }
    private var dayStarts: Set<String> {
        var result: Set<String> = []; var previous: Date?
        for message in messages { if previous == nil || !Calendar.current.isDate(previous!, inSameDayAs: message.created) { result.insert(message.id) }; previous = message.created }
        return result
    }
    private var messages: [ChatMessage] { chat.selected?.id == channelID ? chat.timeline.messages : [] }
    var body: some View {
        ScrollViewReader { proxy in
            let grouped = groupedIDs
            let days = dayStarts
            VStack(spacing: 0) {
                if !chat.liveStatus.isEmpty {
                    Text(chat.liveStatus).font(.footnote).foregroundStyle(.secondary).padding(8)
                }
                if let error = chat.error ?? chat.catalogError {
                    HStack {
                        Text(error).font(.footnote).foregroundStyle(.secondary)
                        Button("Tekrar dene") { if chat.catalogError != nil { chat.retryCatalog() } else { chat.reload() } }
                    }.padding(12).accessibilityElement(children: .contain)
                }
                if let error = chat.readError {
                    HStack { Text(error).font(.footnote).foregroundStyle(.secondary); Button("Tekrar dene") { chat.retryReadSync() } }.padding(8)
                }
                if let error = chat.actionError { HStack { Text(error).font(.footnote).foregroundStyle(.secondary); Button("Tekrar dene") { Task { await chat.retryAction() } } }.padding(8) }
                if chat.historyWindowLimited { Button("Güncel mesajlara dön", systemImage: "arrow.down.to.line") { initiallyScrolled = false; nearBottom = true; chat.returnToLatest() }.frame(minHeight: 44) }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 7) {
                        if chat.loading { ProgressView("Mesajlar yükleniyor…").frame(maxWidth: .infinity) }
                        if chat.hasMore {
                            Button { loadOlder() } label: {
                                HStack { if chat.loadingOlder { ProgressView() }; Text(chat.loadingOlder ? "Geçmiş yükleniyor…" : "Daha eski mesajları yükle") }
                            }.disabled(chat.loadingOlder || chat.loading)
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .onAppear { if initiallyScrolled { loadOlder() } }
                        }
                        if !chat.loading && chat.access.view && !chat.access.history {
                            Text("Bu kanalda geçmişi görüntüleme iznin yok.").font(.footnote).foregroundStyle(.secondary)
                        }
                        if messages.isEmpty && !chat.loading && chat.error == nil && chat.access.history {
                            Text("Henüz mesaj yok. İlk mesajı sen yaz.").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 32)
                        }
                        ForEach(messages) { message in
                            if days.contains(message.id), message.created != .distantPast { HStack { Rectangle().fill(Palette.separator).frame(height: 1); Text(message.created, format: .dateTime.day().month(.wide).year()).font(.caption2).foregroundStyle(.secondary).fixedSize(); Rectangle().fill(Palette.separator).frame(height: 1) }.padding(.vertical, 14) }
                            if unreadBoundary == message.id { HStack { Rectangle().fill(Palette.accent.opacity(0.3)).frame(height: 1); Text("YENİ MESAJLAR").font(.caption2.bold()).foregroundStyle(Palette.accent).fixedSize(); Rectangle().fill(Palette.accent.opacity(0.3)).frame(height: 1) }.padding(.vertical, 10) }
                            MessageCardView(chat: chat, message: message, currentUserID: currentUserID, grouped: grouped.contains(message.id),
                                openProfile: { viewingProfile = ProfileRequest(id: $0) },
                                openFile: { viewingAttachment = FileRequest(attachment: $0, message: $1) },
                                openReply: { viewingReply = ReplyRequest(id: $0, channelID: $1) },
                                edit: { editingMessage = $0 }, delete: { deletingMessage = $0 }, react: { reactingMessage = $0 }, pollHub: model?.chatPollHub)
                                .id(message.id)
                                .background { GeometryReader { geometry in Color.clear.preference(key: MessageFrameKey.self, value: [message.id: geometry.frame(in: .named("chat-scroll"))]) } }
                        }
                        Color.clear.frame(height: 1).id("chat-bottom")
                            .onAppear { nearBottom = true; newMessages = false }
                            .onDisappear { nearBottom = false }
                    }.padding(16)
                }.coordinateSpace(name: "chat-scroll")
                    .background { GeometryReader { geometry in Color.clear.preference(key: ChatViewportKey.self, value: geometry.size.height).preference(key: ChatViewportFrameKey.self, value: geometry.frame(in: .global)) } }
                    .onPreferenceChange(MessageFrameKey.self) { frames in rowFrames = frames; markRenderedMessages() }
                    .onPreferenceChange(ChatViewportKey.self) { height in viewportHeight = height; markRenderedMessages() }
                    .onPreferenceChange(ChatViewportFrameKey.self) { viewportGlobal = $0; markRenderedMessages() }
                    .onChange(of: obscuredRect) { _, _ in markRenderedMessages() }
                    .scrollDismissesKeyboard(.interactively)
                if newMessages {
                    Button("Yeni mesajlara git", systemImage: "arrow.down") { proxy.scrollTo("chat-bottom", anchor: .bottom); newMessages = false }
                        .frame(minHeight: 44)
                }
                if !chat.typingNames.isEmpty { Text(chat.typingNames.joined(separator: ", ") + " yazıyor…").font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading) }
                if let model, model.active != nil { VoiceDockView(model: model, media: model.media).padding(.horizontal, 12).padding(.bottom, 7) }
                composer
            }.background(Palette.canvas)
                .navigationTitle(chat.selected?.name ?? "Sohbet").navigationBarTitleDisplayMode(.inline)
                .onChange(of: chat.loading) { _, loading in
                    if !loading { markRenderedMessages() }
                    if !loading && !initiallyScrolled {
                        restorePosition(proxy); initiallyScrolled = true
                    }
                }
                .onChange(of: chat.loadingOlder) { _, loading in
                    if !loading, let anchor = olderAnchor { proxy.scrollTo(anchor, anchor: .top); olderAnchor = nil }
                }
                .onChange(of: messages.last?.id) { _, _ in
                    guard !chat.loadingOlder else { return }
                    if nearBottom || messages.last?.authorID == currentUserID { proxy.scrollTo("chat-bottom", anchor: .bottom) }
                    else { newMessages = true }
                }
                .onChange(of: composing) { _, value in chat.setComposing(value) }
                .onAppear { chat.setConversationVisible(!overlayPresented, channelID: channelID); if !chat.loading { restorePosition(proxy); initiallyScrolled = true } }
                .onDisappear { chat.setConversationVisible(false, channelID: channelID) }
                .onChange(of: chat.selected?.id) { _, _ in initiallyScrolled = false; olderAnchor = nil; nearBottom = true; newMessages = false; editingMessage = nil; deletingMessage = nil; viewingAttachment = nil; viewingProfile = nil; viewingReply = nil; reactingMessage = nil }
                .onChange(of: overlayPresented) { _, active in chat.setConversationVisible(!active, channelID: channelID); if !active { markRenderedMessages() } }
                .onChange(of: chat.authorityGeneration) { _, _ in editingMessage = nil; deletingMessage = nil; viewingAttachment = nil; viewingProfile = nil; viewingReply = nil; reactingMessage = nil }
                .sheet(item: $editingMessage) { MessageEditView(chat: chat, message: $0) }
                .sheet(item: $reactingMessage) { ReactionPickerView(chat: chat, message: $0) }
                .sheet(item: $viewingAttachment) { AttachmentViewer(chat: chat, attachment: $0.attachment, message: $0.message) }
                .sheet(item: $viewingReply) { ReplyDetailView(chat: chat, messageID: $0.id, channelID: $0.channelID) }
                .sheet(item: $viewingProfile, onDismiss: {
                    if let peer = pendingProfilePeer { pendingProfilePeer = nil; chat.createDirectMessage(peerID: peer) }
                }) { profile in ProfileView(chat: chat, userID: profile.id, currentUserID: currentUserID) { pendingProfilePeer = profile.id; viewingProfile = nil } }
                .alert("Mesajı sil?", isPresented: Binding(get: { deletingMessage != nil }, set: { if !$0 { deletingMessage = nil } }), presenting: deletingMessage) { message in
                    Button("Sil", role: .destructive) { deletingMessage = nil; Task { _ = await chat.perform(.delete(id: message.id)) } }
                    Button("Vazgeç", role: .cancel) { deletingMessage = nil }
                } message: { _ in Text("Bu mesaj konuşmadan kaldırılacak.") }
        }
    }
    private func markRenderedMessages() {
        guard viewportHeight > 0, !overlayPresented, chat.selected?.id == channelID else { return }
        if !capturedUnread, !chat.loading, chat.ledger.available {
            let marker = chat.ledger.states[channelID]?.lastReadID
            unreadBoundary = chat.unread(channelID) == true ? messages.first(where: { marker == nil || $0.id > marker! })?.id : nil
            capturedUnread = true
        }
        // A row is read only once its bottom is in the actual scroll viewport.
        // Lazy stack prefetch/onAppear alone is not evidence that text was seen.
        let visible = rowFrames.filter { $0.value.maxY > 0 && $0.value.minY < viewportHeight }
        guard initiallyScrolled else { return }
        if let first = visible.min(by: { $0.value.minY < $1.value.minY }) { model?.rememberScroll(channel: channelID, anchor: nearBottom ? "chat-bottom" : first.key) }
        let firstCovered = rowFrames.compactMap { id, frame -> String? in
            let global = frame.offsetBy(dx: viewportGlobal.minX, dy: viewportGlobal.minY)
            return !obscuredRect.isEmpty && global.intersects(obscuredRect) && global.intersects(viewportGlobal) ? id : nil
        }.min()
        for (id, frame) in rowFrames {
            // Read markers are cumulative; never advance past a row hidden behind the mini player.
            if let firstCovered, id >= firstCovered { continue }
            let global = frame.offsetBy(dx: viewportGlobal.minX, dy: viewportGlobal.minY)
            if ReadVisibilityPolicy.readable(row: global, viewport: viewportGlobal, occlusions: [obscuredRect]) { chat.markVisible(messageID: id) }
        }
    }
    private func restorePosition(_ proxy: ScrollViewProxy) {
        if let anchor = model?.scrollAnchor(for: channelID), anchor != "chat-bottom", messages.contains(where: { $0.id == anchor }) { nearBottom = false; proxy.scrollTo(anchor, anchor: .top) }
        else { proxy.scrollTo("chat-bottom", anchor: .bottom) }
    }
    private func loadOlder() {
        guard !chat.loadingOlder, !chat.loading, chat.hasMore else { return }
        olderAnchor = messages.first?.id; chat.loadOlder()
    }
    private var mentionSuggestions: some View {
        VStack(spacing: 0) {
            ForEach(chat.mentionSuggestions) { person in
                Button { chat.completeMention(person) } label: {
                    HStack(spacing: 9) { ChatAvatarView(chat: chat, userID: person.id, name: person.name, size: 26); Text(person.name).font(.subheadline).lineLimit(1); Spacer(minLength: 0) }
                        .padding(.horizontal, 10).frame(minHeight: 44).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("\(person.name) kişisinden bahset")
            }
        }.background(Palette.raised, in: RoundedRectangle(cornerRadius: 14)).accessibilityElement(children: .contain).accessibilityLabel("Bahsetme önerileri")
    }
    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if chat.access.send {
                if let reply = chat.replyTarget {
                    HStack { Label(chat.timeline.message(reply).map { "Yanıt: " + $0.authorName } ?? "Mesaja yanıt", systemImage: "arrowshape.turn.up.left").font(.caption); Spacer(); Button { chat.setReply(nil) } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }.accessibilityLabel("Yanıtı iptal et") }
                }
                if !chat.mentionSuggestions.isEmpty { mentionSuggestions }
                AttachmentComposer(chat: chat, onPickerActive: { pickerPresented = $0 }) {
                    HStack(alignment: .bottom, spacing: 4) {
                        TextField("Mesaj yaz", text: Binding(get: { chat.draft }, set: { chat.setDraft($0) }), axis: .vertical)
                            .lineLimit(1...4).focused($composing).padding(.vertical, 11).padding(.leading, 4)
                            .accessibilityIdentifier("chat.composer")
                        Button { chat.send() } label: { Image(systemName: "paperplane.fill").frame(width: 44, height: 44) }
                            .foregroundStyle(Palette.accent).accessibilityLabel("Mesajı gönder").accessibilityIdentifier("chat.send").disabled(!chat.canSendDraft)
                    }
                }
                if chat.draft.count > 3500 {
                    Text("\(chat.draft.count)/4000").font(.caption).foregroundStyle(chat.draft.count > 4000 ? Color.red : .secondary)
                }
            } else {
                Text(chat.loading || chat.catalogLoading ? "Sohbet yükleniyor…" : chat.access.view ? "Bu kanalda mesaj gönderme iznin yok." : "Sohbet erişimi doğrulanamadı.")
                    .font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 44)
            }
        }.padding(.horizontal, 12).padding(.top, 5).padding(.bottom, 8).background(Palette.canvas)
    }
}

private struct ChatVoiceBar: View {
    @ObservedObject var model: RoomsModel
    @ObservedObject var media: RoomMedia
    let returnToRoom: () -> Void
    var body: some View {
        if let room = model.active {
            VStack(spacing: 8) {
                Button(action: returnToRoom) {
                    HStack { Image(systemName: "headphones"); Text(room.name).lineLimit(1); Spacer(); Text(model.busy ? "Bağlanıyor…" : media.status).font(.caption).lineLimit(1) }
                }.accessibilityLabel("\(room.name) sesli odasına dön")
                HStack(spacing: 10) {
                    control(media.muted ? "Mikrofonu aç" : "Mikrofonu kapat", icon: media.muted ? "mic.slash" : "mic", selected: !media.muted) { Task { await media.toggleMicrophone() } }.disabled(!media.canToggleMicrophone)
                    control(media.hearingMuted ? "Oda sesini aç" : "Oda sesini kapat", icon: media.hearingMuted ? "headphones.slash" : "headphones", selected: !media.hearingMuted) { media.toggleHearing() }.disabled(!media.connected)
                    if media.selectedStream?.hasAudio == true {
                        control(media.screenMuted ? "Yayın sesini aç" : "Yayın sesini kapat", icon: media.screenMuted ? "speaker.slash" : "speaker.wave.2", selected: !media.screenMuted) { media.setScreenAudio(muted: !media.screenMuted) }
                    }
                    control("Odadan ayrıl", icon: "phone.down", destructive: true) { model.leave() }
                }
            }.padding(.horizontal, 12).padding(.top, 5).padding(.bottom, 8).background(Palette.canvas)
                .overlay(alignment: .top) { Divider() }
        }
    }
    private func control(_ label: String, icon: String, selected: Bool = false, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).frame(maxWidth: .infinity, minHeight: 44) }
            .buttonStyle(RoomControlStyle(selected: selected, destructive: destructive)).accessibilityLabel(label)
    }
}

private struct MessageFrameKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue(), uniquingKeysWith: { _, new in new }) }
}
private struct ChatViewportKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
struct ChatUnreadBadge: View {
    @ObservedObject var chat: ChatController
    let channelID: String
    var body: some View {
        HStack(spacing: 6) {
            if chat.unread(channelID) == true { Circle().fill(Palette.accent).frame(width: 9, height: 9).accessibilityLabel("Okunmamış mesaj var") }
            if chat.mentionCount(channelID) > 0 { Text("@\(chat.mentionCount(channelID))").font(.caption.bold()).foregroundStyle(Palette.accent).accessibilityLabel("\(chat.mentionCount(channelID)) okunmamış bahsetme") }
        }.accessibilityValue(chat.unread(channelID) == nil ? "Okunma bilgisi bilinmiyor" : chat.unread(channelID) == true ? "Okunmamış" : "Okundu")
    }
}

struct MessagesEntryButton: View {
    @ObservedObject var chat: ChatController
    let action: () -> Void
    private var unreadConversations: Int { chat.channels.filter { chat.unread($0.id) == true }.count }
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Label("Mesajlar", systemImage: "text.bubble")
                if unreadConversations > 0 { Text("\(unreadConversations)").font(.caption.bold()).padding(.horizontal, 6).padding(.vertical, 3).background(Palette.accent.opacity(0.2), in: Capsule()) }
            }
        }.accessibilityLabel("Mesajlar").accessibilityValue(chat.ledger.available ? "\(unreadConversations) okunmamış sohbet" : "Okunma bilgisi bilinmiyor")
    }
}

private struct ProfileRequest: Identifiable { let id: String }
private struct ReplyRequest: Identifiable { let id: String; let channelID: String }
private struct FileRequest: Identifiable {
    var id: String { message.id + ":" + attachment.id }
    let attachment: ChatAttachment; let message: ChatMessage
}

private struct ChatViewportFrameKey: PreferenceKey { static let defaultValue = CGRect.zero; static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() } }
