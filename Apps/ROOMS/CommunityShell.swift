import UIKit
import SwiftUI
import PhotosUI
import RoomsCore

struct CommunityShell: View {
    @ObservedObject var model: RoomsModel
    @ObservedObject var chat: ChatController
    @ObservedObject var media: RoomMedia
    @State private var query = ""
    @State private var account = false
    @State private var audioSettings = false
    @State private var communityInfo = false
    @State private var miniRect = CGRect.zero
    /// Discord-like bottom tabs: Sunucular, Mesajlar, Sen.
    @State private var youTab = false
    /// Right-hand member drawer, like Discord's member list.
    @State private var drawer: MembersTarget?
    @State private var friendsOpen = false
    @State private var djOpen = false
    @State private var djNeedsRoom = false
    private var modalVisible: Bool { account || audioSettings || communityInfo || model.roomPreview != nil || model.roomExpanded }
    var body: some View {
        NavigationStack(path: Binding(get: { model.conversationPath }, set: { model.setConversationPath($0) })) {
            HStack(spacing: 0) {
                if !youTab && !model.communitySelection.messages { communityRail }
                VStack(spacing: 0) {
                    if youTab {
                        YouTab(model: model, chat: chat, openSettings: { account = true }, openAudio: { audioSettings = true })
                    } else {
                        header
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 4) {
                                searchField
                                catalogStatus
                                if model.communitySelection.messages { directMessages }
                                else { channels }
                            }.padding(.horizontal, 12).padding(.bottom, 16)
                        }.refreshable { model.retryList(); chat.retryCatalog() }
                    }
                }.frame(maxWidth: .infinity).background(Palette.canvas)
            }
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 8) {
                    DMCallDock(calls: model.calls, media: media).padding(.horizontal, 12)
                    if model.active != nil { VoiceDockView(model: model, media: media).padding(.horizontal, 12) }
                    tabBar
                }
            }
            .navigationDestination(for: String.self) { id in
                if let channel = chat.channels.first(where: { $0.id == id }) {
                    ChatConversationView(chat: chat, currentUserID: model.user?.id ?? "", channelID: id, model: model, obscuredRect: miniRect)
                        .id(id).toolbar(.visible, for: .navigationBar)
                        .toolbarBackground(Palette.canvas, for: .navigationBar).toolbarBackground(.visible, for: .navigationBar)
                        .toolbar { ToolbarItem(placement: .principal) {
                            HStack(spacing: 8) {
                                if let peer = channel.recipients.first(where: { $0 != model.user?.id }) { ChatAvatarView(chat: chat, userID: peer, name: channel.name, size: 28) }
                                else { Image(systemName: "number").foregroundStyle(.secondary) }
                                Text(channel.name).font(.headline).lineLimit(1)
                            }
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            if !channel.isDirect {
                                Button { withAnimation(.snappy) { drawer = MembersTarget(serverID: channel.serverID, name: channel.community) } } label: { Image(systemName: "person.2.fill") }
                                    .accessibilityLabel("Üyeler")
                            } else { DMCallButton(calls: model.calls, dmID: channel.id, inVoiceRoom: model.active != nil) }
                        } }
                } else { ContentUnavailableView("Sohbet kullanılamıyor", systemImage: "lock", description: Text("Erişimin veya kanal bilgisi değişmiş olabilir.")) }
            }
        }
        .background(Palette.canvas)
        .overlay {
            if let target = drawer {
                MembersDrawer(model: model, chat: chat, target: target) { withAnimation(.snappy) { drawer = nil } }
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .topTrailing) {
            if model.active != nil, !model.roomExpanded, media.selection.id != nil {
                MiniStreamPlayer(model: model, media: media).onPreferenceChange(MiniPlayerFrameKey.self) { miniRect = $0 }
            }
        }
        .sheet(isPresented: $account) { AccountPanel(model: model, chat: chat, media: media) }
        .sheet(isPresented: $audioSettings) { RoomAudioSettingsView(media: media, onMessagePeer: { model.openDirectMessage($0) }, chat: chat) }
        .sheet(isPresented: $communityInfo) { communityPanel }
        .sheet(isPresented: $friendsOpen) { FriendsView(model: model, chat: chat) }
        .sheet(isPresented: $djOpen) { DJPanelView(model: model, media: media).presentationDetents([.large]) }
        .alert(model.djName, isPresented: $djNeedsRoom) { Button("Tamam", role: .cancel) {} } message: { Text("\(model.djName) bir ses odasında çalar. Önce bir odaya katıl.") }
        .sheet(item: $model.roomPreview) { room in VoiceRoomPreview(model: model, room: room) }
        .modifier(HallPresentation(hub: model.cinema, model: model))
        .onChange(of: model.communitySelection.messages ? nil : model.communitySelection.communityID, initial: true) { _, id in model.cinema.select(community: id) }
        .fullScreenCover(isPresented: $model.roomExpanded, onDismiss: { media.setVisibleCameras([]); restoreChatVisibility() }) { VoiceRoomScreen(model: model, media: media, chat: chat) }
        .onChange(of: chat.channels) { _, _ in model.reconcileNavigation(); model.consumeDirectMessage() }
        .onChange(of: chat.catalogLoading) { _, loading in if !loading { model.reconcileNavigation() } }
        .onChange(of: chat.openedDirectID) { _, _ in model.consumeDirectMessage() }
        .onChange(of: model.communitySelection.communityID) { _, _ in query = "" }
        .onChange(of: model.communitySelection.messages) { _, _ in query = "" }
        .onChange(of: model.conversationPath) { _, path in if !path.isEmpty { youTab = false } }
        .onChange(of: modalVisible) { _, _ in restoreChatVisibility() }
        .onChange(of: media.selection.id) { _, id in if id == nil { miniRect = .zero } }
        .onChange(of: model.roomExpanded) { _, expanded in if expanded { miniRect = .zero } else { media.setVisibleCameras([]) } }
        .onAppear { model.consumeDirectMessage() }
        .onChange(of: media.keepsScreenAwake, initial: true) { _, awake in UIApplication.shared.isIdleTimerDisabled = awake }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }
    private func restoreChatVisibility() {
        if let id = model.conversationPath.last { chat.setConversationVisible(!modalVisible, channelID: id) }
    }
    private var header: some View {
        HStack(spacing: 6) {
            if model.communitySelection.messages { Text("Mesajlar").font(.title3.bold()) }
            else {
                Button { communityInfo = true } label: {
                    HStack(spacing: 5) { Text(model.selectedCommunity?.name ?? "Topluluklar").font(.title3.bold()).lineLimit(2); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary) }.foregroundStyle(.primary)
                }.buttonStyle(.plain)
            }
            Spacer(minLength: 0)
            if !model.communitySelection.messages, let community = model.selectedCommunity {
                Button { if model.musicClient() != nil { djOpen = true } else { djNeedsRoom = true } } label: {
                    Group {
                        if let poster = model.djPoster { Image(uiImage: poster).resizable().scaledToFill() }
                        else { Image(systemName: "music.note").font(.subheadline.bold()).foregroundStyle(Palette.accent) }
                    }.frame(width: 32, height: 32).background(Palette.raised).clipShape(Circle())
                        .overlay(Circle().strokeBorder(Palette.accent.opacity(0.6), lineWidth: 1.5)).frame(width: 44, height: 44)
                }.accessibilityLabel(model.djName)
                Button { withAnimation(.snappy) { drawer = MembersTarget(serverID: community.id, name: community.name) } } label: {
                    Image(systemName: "person.2.fill").frame(width: 44, height: 44)
                }.accessibilityLabel("Üyeler")
            }
            if model.communitySelection.messages {
                Button { friendsOpen = true } label: { Label("Arkadaşlar", systemImage: "person.2.fill").font(.subheadline.weight(.semibold)) }
                    .buttonStyle(.bordered).accessibilityIdentifier("friends.open")
            }
        }.frame(minHeight: 60).padding(.horizontal, 16)
    }
    private var tabBar: some View {
        HStack(spacing: 0) {
            tabButton("Sunucular", icon: "house.fill", selected: !youTab && !model.communitySelection.messages, badge: false) {
                youTab = false
                if model.communitySelection.messages { model.chooseCommunity(model.communitySelection.communityID ?? model.communities.first?.id) }
            }
            tabButton("Mesajlar", icon: "bubble.left.and.bubble.right.fill", selected: !youTab && model.communitySelection.messages,
                      badge: chat.channels.contains { $0.isDirect && chat.unread($0.id) == true }) {
                youTab = false
                if !model.communitySelection.messages { model.chooseCommunity(nil) }
            }
            Button { youTab = true } label: {
                VStack(spacing: 3) {
                    Group {
                        if let user = model.user { ChatAvatarView(chat: chat, userID: user.id, name: user.name, size: 24) }
                        else { Image(systemName: "person.crop.circle.fill").font(.title3) }
                    }.overlay(Circle().strokeBorder(youTab ? Color.primary : .clear, lineWidth: 1.5))
                    Text("Sen").font(.caption2.weight(.semibold))
                }.frame(maxWidth: .infinity, minHeight: 50).foregroundStyle(youTab ? Color.primary : Color.secondary)
            }.buttonStyle(.plain).accessibilityLabel("Sen").accessibilityAddTraits(youTab ? .isSelected : [])
        }
        .padding(.top, 6)
        .background(Palette.rail.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { Rectangle().fill(Palette.separator).frame(height: 1) }
    }
    private func tabButton(_ title: String, icon: String, selected: Bool, badge: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 19))
                    .overlay(alignment: .topTrailing) { if badge { Circle().fill(.red).frame(width: 9, height: 9).offset(x: 5, y: -2) } }
                Text(title).font(.caption2.weight(.semibold))
            }.frame(maxWidth: .infinity, minHeight: 50).foregroundStyle(selected ? Color.primary : Color.secondary)
        }.buttonStyle(.plain).accessibilityLabel(title).accessibilityValue(badge ? "Okunmamış mesaj var" : "").accessibilityAddTraits(selected ? .isSelected : [])
    }
    private var searchField: some View {
        HStack(spacing: 8) { Image(systemName: "magnifyingglass").foregroundStyle(.secondary); TextField(model.communitySelection.messages ? "Konuşma bul" : "Kanal bul", text: $query).textInputAutocapitalization(.never).autocorrectionDisabled().font(.subheadline) }
            .padding(.horizontal, 12).frame(minHeight: 44).background(Palette.raised, in: RoundedRectangle(cornerRadius: 10)).padding(.bottom, 14)
            .accessibilityHint("Yalnızca mevcut listedeki adları filtreler")
    }
    private var communityRail: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 12) {
                ForEach(model.communities) { community in
                    railButton(selected: !model.communitySelection.messages && model.communitySelection.communityID == community.id,
                               label: community.name, unread: chat.channels.contains { $0.serverID == community.id && chat.unread($0.id) == true }) {
                        model.chooseCommunity(community.id)
                    } content: { CommunityIconView(model: model, community: community) }
                }
            }.padding(.vertical, 12).padding(.horizontal, 10)
        }.frame(width: 68).background(Palette.rail)
    }
    private func railButton<Content: View>(selected: Bool, label: String, unread: Bool, action: @escaping () -> Void, @ViewBuilder content: () -> Content) -> some View {
        Button(action: action) { content().frame(width: 48, height: 48).background(selected ? Palette.accent.opacity(0.18) : Palette.raised, in: RoundedRectangle(cornerRadius: 16)).foregroundStyle(selected ? Palette.accent : Color.secondary) }
            .buttonStyle(.plain).overlay(alignment: .leading) { if selected || unread { Capsule().fill(selected ? Palette.accent : Color.primary).frame(width: 4, height: selected ? 30 : 8).offset(x: -10) } }
            .accessibilityLabel(label).accessibilityValue(selected ? "Seçili" : unread ? "Okunmamış mesaj var" : "").accessibilityAddTraits(selected ? .isSelected : [])
    }
    @ViewBuilder private var catalogStatus: some View {
        if let error = model.error ?? chat.directError ?? chat.catalogError {
            Notice(text: error)
            Button("Tekrar dene") { model.retryList(); chat.retryCatalog(); if chat.directError != nil { chat.retryDirectMessage() } }.frame(minHeight: 44)
        }
        if !model.listStatus.isEmpty || !chat.liveStatus.isEmpty {
            Notice(text: model.listStatus.isEmpty ? chat.liveStatus : model.listStatus)
            Button("Bağlantıyı yenile") { model.retryList() }.font(.footnote).frame(minHeight: 44)
        }
        if chat.catalogLoading && chat.channels.isEmpty { ProgressView("Kanallar yükleniyor…").font(.footnote).frame(maxWidth: .infinity).padding(.vertical, 24) }
        if chat.openingDirectFor != nil { ProgressView("Özel konuşma açılıyor…").font(.footnote) }
    }
    private var directMessages: some View {
        VStack(alignment: .leading, spacing: 3) {
            sectionTitle("ÖZEL MESAJLAR")
            ForEach(chat.channels.filter { $0.isDirect && matches($0.name) }) { channel in
                Button { model.openChat(channel) } label: {
                    HStack(spacing: 11) {
                        let peer = channel.recipients.first { $0 != model.user?.id }
                        if let peer { ChatAvatarView(chat: chat, userID: peer, name: channel.name, size: 42).overlay(alignment: .bottomTrailing) { if model.onlineUsers.contains(peer) { Circle().fill(.green).frame(width: 10, height: 10).overlay(Circle().stroke(Palette.canvas, lineWidth: 2)) } } }
                        else { Image(systemName: "person.crop.circle.fill").font(.largeTitle).foregroundStyle(.secondary) }
                        VStack(alignment: .leading, spacing: 5) {
                            HStack { Text(channel.name).font(.subheadline.weight(chat.unread(channel.id) == true ? .bold : .medium)).foregroundStyle(.primary).lineLimit(1); Spacer(minLength: 0); if let preview = chat.preview(channelID: channel.id) { Text(preview.created, style: .time).font(.caption2).foregroundStyle(.secondary) } }
                            Text(chat.preview(channelID: channel.id).map { $0.content.isEmpty ? "Dosya paylaşıldı" : chat.displayContent($0) } ?? "Özel konuşma").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        ChatUnreadBadge(chat: chat, channelID: channel.id)
                    }.padding(.vertical, 12).padding(.horizontal, 4).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            if !chat.directLoading && !chat.channels.contains(where: \.isDirect) { Text("Henüz özel konuşma yok. Bir katılımcının profilinden mesaj başlatabilirsin.").font(.footnote).foregroundStyle(.secondary).padding(.vertical, 20) }
            if chat.directLoading { ProgressView("Konuşmalar yükleniyor…").font(.footnote).padding() }
        }
    }
    private func matches(_ text: String) -> Bool { query.isEmpty || text.localizedStandardContains(query) }
    private var availableChannels: Set<String> {
        let id = model.selectedCommunity?.id, hall = model.cinema.hallID(community: id)
        // The cinema hall is a channel too, but it lives in its own "Sinema" row.
        return Set(chat.channels.filter { !$0.isDirect && $0.serverID == id && $0.id != hall }.map(\.id) + model.rooms.filter { model.communityID(for: $0) == id }.map(\.id))
    }
    private var sections: [(id: String, name: String, channels: [String])] {
        guard let community = model.selectedCommunity else { return [] }
        if !community.categories.isEmpty { return community.sections(available: availableChannels) }
        let order = community.ordered(availableChannels), voice = Set(model.rooms.map(\.id))
        return [("text", "METİN KANALLARI", order.filter { !voice.contains($0) }), ("voice", "SES ODALARI", order.filter { voice.contains($0) })].filter { !$0.2.isEmpty }
    }
    private var channels: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let community = model.selectedCommunity, query.isEmpty || matches("Sinema") { HallSidebarRow(hub: model.cinema, chat: chat, community: community.id).padding(.top, 4) }
            ForEach(sections, id: \.id) { section in
                sectionTitle(section.name.uppercased())
                ForEach(section.channels, id: \.self) { id in
                    if let voice = model.rooms.first(where: { $0.id == id }), matches(voice.name) { voiceRow(voice) }
                    else if let channel = chat.channels.first(where: { $0.id == id }), matches(channel.name) { textRow(channel) }
                }
            }
            if sections.isEmpty && !chat.catalogLoading && model.listStatus.isEmpty { ContentUnavailableView("Henüz kanal yok", systemImage: "number", description: Text("Erişebildiğin kanallar burada görünecek.")).font(.footnote) }
        }
    }
    private func sectionTitle(_ title: String) -> some View { HStack(spacing: 5) { Image(systemName: "chevron.down"); Text(title) }.font(.caption2.weight(.bold)).foregroundStyle(.secondary).padding(.top, 18).padding(.bottom, 6).accessibilityAddTraits(.isHeader) }
    private func textRow(_ channel: TextChannel) -> some View {
        Button { model.openChat(channel) } label: {
            HStack(spacing: 9) { Image(systemName: "number").font(.title3).foregroundStyle(.secondary); Text(channel.name).font(.subheadline.weight(chat.unread(channel.id) == true ? .semibold : .regular)).lineLimit(2); Spacer(minLength: 0); ChatUnreadBadge(chat: chat, channelID: channel.id); if !channel.access.send { Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary) } }
                .foregroundStyle(.primary).padding(.horizontal, 10).frame(minHeight: model.communitySelection.channelID == channel.id ? 42 : 46).background(model.communitySelection.channelID == channel.id ? Color.white.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 9)).frame(minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
    private func voiceRow(_ room: VoiceRoom) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Button { if model.active?.id == room.id { model.roomExpanded = true } else { model.roomPreview = room } } label: {
                HStack(spacing: 9) {
                    Image(systemName: "speaker.wave.2.fill").font(.subheadline).foregroundStyle(.secondary)
                    Text(room.name).font(.subheadline).lineLimit(2); Spacer(minLength: 0)
                    if case let members = model.occupants(room.id), !members.isEmpty { if members.contains(where: { $0.screen == true }) { Text("YAYIN").font(.system(size: 8, weight: .heavy)).padding(4).background(Palette.accent.opacity(0.15), in: RoundedRectangle(cornerRadius: 4)).foregroundStyle(Palette.accent) }; Text("\(members.count)").font(.caption2.weight(.medium)).foregroundStyle(.secondary) }
                }.foregroundStyle(.primary).padding(.horizontal, 10).frame(minHeight: model.active?.id == room.id ? 42 : 46).background(model.active?.id == room.id ? Palette.accent.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 9)).frame(minHeight: 44).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityHint("Oda önizlemesini açar; katılmadan mikrofon veya kamera açılmaz")
            ForEach(Array(model.occupants(room.id).prefix(4)), id: \.id) { person in
                HStack(spacing: 7) { ChatAvatarView(chat: chat, userID: person.id, name: person.name, size: 22); Text(person.name).font(.caption).lineLimit(1); Spacer(minLength: 0); if person.muted || person.deafened == true { Image(systemName: "mic.slash").font(.caption2).accessibilityLabel("Mikrofon kapalı") }; if person.deafened == true { Image(systemName: "headphones.slash").font(.caption2).accessibilityLabel("Sağırlaştırdı") } }.foregroundStyle(.secondary).padding(.leading, 37).padding(.vertical, 3).accessibilityElement(children: .combine)
            }
        }.padding(.bottom, 4)
    }
    private var communityPanel: some View {
        CommunitySheet(model: model, chat: chat, textChannelID: chat.channels.first { !$0.isDirect && $0.serverID == model.selectedCommunity?.id }?.id,
                       channelCount: availableChannels.count)
    }
}

private struct CommunityIconView: View {
    @ObservedObject var model: RoomsModel
    let community: RoomCommunity
    @State private var image: UIImage?
    var body: some View {
        Group { if let image { Image(uiImage: image).resizable().scaledToFill() } else { Text(String(community.name.prefix(2)).uppercased()).font(.headline.bold()) } }
            .frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 16)).accessibilityHidden(true)
            .task(id: "\(model.user?.id ?? ""):\(community.id):\(community.iconID ?? "")") { image = nil; await model.loadCommunityIcon(community); if !Task.isCancelled, let file = model.communityIcons[community.id] { image = thumbnail(file, pixels: 144) } }
    }
}
/// Desktop's friends page on the phone: online, all, requests and blocked, plus adding by name#1234.
private struct FriendsView: View {
    enum Tab: String, CaseIterable, Identifiable { case online = "Çevrimiçi", all = "Tümü", requests = "İstekler", blocked = "Engellenen"; var id: String { rawValue } }
    @ObservedObject var model: RoomsModel
    @ObservedObject var chat: ChatController
    @Environment(\.dismiss) private var dismiss
    @State private var tab = Tab.online
    @State private var friends: [Friend]?
    @State private var handle = ""
    @State private var busy = false
    @State private var notice: String?
    var body: some View {
        let list = friends ?? []
        let shown: [Friend] = switch tab {
        case .online: list.filter { $0.relationship == .friend && ($0.online || model.onlineUsers.contains($0.id)) }
        case .all: list.filter { $0.relationship == .friend }
        case .requests: list.filter { $0.relationship == .incoming || $0.relationship == .outgoing }
        case .blocked: list.filter { $0.relationship == .blocked }
        }
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 8) {
                        TextField("kullanıcıadı#1234", text: $handle).textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.send).onSubmit { Task { await add() } }
                        Button("Ekle") { Task { await add() } }.disabled(busy || Friend.validHandle(handle) == nil)
                    }
                } header: { Text("Arkadaş ekle") } footer: { Text("Kullanıcı adını ve dört haneli etiketi yaz, örneğin osman#0420.") }
                if let notice { Section { Text(notice).font(.footnote).foregroundStyle(.secondary) } }
                Section {
                    Picker("Liste", selection: $tab) { ForEach(Tab.allCases) { option in Text(label(option, list)).tag(option) } }.pickerStyle(.segmented)
                }.listRowBackground(Color.clear)
                if friends == nil { ProgressView("Arkadaşlar yükleniyor…").frame(maxWidth: .infinity) }
                else if shown.isEmpty { Text(emptyText).font(.footnote).foregroundStyle(.secondary) }
                ForEach(shown) { friend in row(friend) }
            }
            .listStyle(.insetGrouped).scrollContentBackground(.hidden).background(Palette.canvas)
            .refreshable { await reload() }
            .navigationTitle("Arkadaşlar").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Kapat") { dismiss() } } }
        }
        .task { await reload() }
    }
    private func label(_ option: Tab, _ list: [Friend]) -> String {
        let incoming = list.filter { $0.relationship == .incoming }.count
        return option == .requests && incoming > 0 ? "\(option.rawValue) (\(incoming))" : option.rawValue
    }
    private var emptyText: String {
        switch tab {
        case .online: "Şu an çevrimiçi arkadaşın yok."
        case .all: "Henüz arkadaşın yok. Yukarıdan kullanıcı adıyla ekleyebilirsin."
        case .requests: "Bekleyen arkadaşlık isteği yok."
        case .blocked: "Engellediğin kimse yok."
        }
    }
    private func row(_ friend: Friend) -> some View {
        HStack(spacing: 12) {
            let online = friend.online || model.onlineUsers.contains(friend.id)
            ChatAvatarView(chat: chat, userID: friend.id, name: friend.name, size: 38)
                .overlay(alignment: .bottomTrailing) { if online && friend.relationship == .friend { Circle().fill(.green).frame(width: 11, height: 11).overlay(Circle().stroke(Palette.surface, lineWidth: 2)) } }
            VStack(alignment: .leading, spacing: 2) {
                Text(friend.name).font(.subheadline.weight(.medium)).lineLimit(1)
                Text(friend.relationship == .incoming ? "Gelen istek" : friend.relationship == .outgoing ? "Gönderilen istek" : friend.handle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            switch friend.relationship {
            case .incoming:
                Button("Kabul et") { Task { await act { try await model.addFriend(friend.handle) } } }.buttonStyle(.borderedProminent).tint(Palette.accent)
                Button { Task { await act { try await model.removeFriend(friend.id) } } } label: { Image(systemName: "xmark") }.buttonStyle(.bordered).accessibilityLabel("Reddet")
            case .outgoing:
                Button("Geri çek") { Task { await act { try await model.removeFriend(friend.id) } } }.buttonStyle(.bordered)
            case .blocked:
                Button("Engeli kaldır") { Task { await act { try await model.unblock(friend.id) } } }.buttonStyle(.bordered)
            case .friend:
                Button { dismiss(); model.openDirectMessage(friend.id) } label: { Image(systemName: "bubble.left.fill") }.buttonStyle(.bordered).accessibilityLabel("\(friend.name) ile mesajlaş")
            }
        }
        .disabled(busy).frame(minHeight: 48).listRowBackground(Palette.surface)
        .swipeActions { if friend.relationship == .friend { Button("Çıkar", role: .destructive) { Task { await act { try await model.removeFriend(friend.id) } } } } }
    }
    private func reload() async {
        do { friends = try await model.friends(); notice = nil } catch { notice = "Arkadaşlar alınamadı: \(error.localizedDescription)" }
    }
    private func add() async {
        guard let value = Friend.validHandle(handle) else { notice = "Kullanıcı adını etiketiyle yaz: ad#1234."; return }
        await act { try await model.addFriend(value) }
        if notice == nil { handle = ""; notice = "\(value) kişisine arkadaşlık isteği gönderildi."; tab = .requests }
    }
    private func act(_ work: () async throws -> Void) async {
        busy = true; defer { busy = false }
        do { try await work(); notice = nil; await reload() } catch { notice = "İşlem yapılamadı: \(error.localizedDescription)" }
    }
}

/// Members slide in from the right over a dimmed screen; tap outside or swipe right to close.
private struct MembersDrawer: View {
    @ObservedObject var model: RoomsModel
    @ObservedObject var chat: ChatController
    let target: MembersTarget
    let close: () -> Void
    @State private var shown = false
    @State private var drag: CGFloat = 0
    @State private var query = ""
    @State private var profileID: String?
    var body: some View {
        GeometryReader { geometry in
            let width = min(340, geometry.size.width * 0.86)
            ZStack(alignment: .trailing) {
                Color.black.opacity(shown ? 0.45 : 0).ignoresSafeArea().onTapGesture { dismiss() }
                panel.frame(width: width).background(Palette.surface.ignoresSafeArea())
                    .offset(x: shown ? max(0, drag) : width)
                    .gesture(DragGesture().onChanged { drag = max(0, $0.translation.width) }.onEnded { value in
                        if value.translation.width > width * 0.3 { dismiss() } else { withAnimation(.snappy) { drag = 0 } }
                    })
            }
        }
        .onAppear { withAnimation(.snappy) { shown = true } }
        .task { chat.loadMemberList(serverID: target.serverID) }
        .sheet(item: Binding(get: { profileID.map(ProfileTarget.init) }, set: { profileID = $0?.id })) { person in
            ProfileView(chat: chat, userID: person.id, currentUserID: model.user?.id ?? "") { profileID = nil; dismiss(); model.openDirectMessage(person.id) }
        }
    }
    private func dismiss() { withAnimation(.snappy) { shown = false; drag = 0 }; DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { close() } }
    private var panel: some View {
        let members = (chat.memberDirectory[target.serverID] ?? []).filter { query.isEmpty || $0.name.localizedStandardContains(query) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let online = members.filter { model.onlineUsers.contains($0.id) }, offline = members.filter { !model.onlineUsers.contains($0.id) }
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Üyeler").font(.headline)
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }.accessibilityLabel("Üyeleri kapat")
            }.padding(.leading, 16).padding(.trailing, 4)
            HStack(spacing: 8) { Image(systemName: "magnifyingglass").foregroundStyle(.secondary); TextField("Üye ara", text: $query).textInputAutocapitalization(.never).autocorrectionDisabled() }
                .padding(.horizontal, 10).frame(minHeight: 38).background(Palette.raised, in: RoundedRectangle(cornerRadius: 9)).padding(.horizontal, 12).padding(.bottom, 8)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if chat.memberDirectory[target.serverID] == nil { ProgressView("Üyeler yükleniyor…").frame(maxWidth: .infinity).padding(.top, 24) }
                    if !online.isEmpty { header("ÇEVRİMİÇİ — \(online.count)"); ForEach(online) { row($0, online: true) } }
                    if !offline.isEmpty { header("ÇEVRİMDIŞI — \(offline.count)"); ForEach(offline) { row($0, online: false) } }
                }.padding(.horizontal, 8).padding(.bottom, 20)
            }
        }
    }
    private func header(_ title: String) -> some View { Text(title).font(.caption2.bold()).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.top, 14).padding(.bottom, 4) }
    private func row(_ member: MentionCandidate, online: Bool) -> some View {
        Button { profileID = member.id } label: {
            HStack(spacing: 10) {
                ChatAvatarView(chat: chat, userID: member.id, name: member.name, size: 34)
                    .overlay(alignment: .bottomTrailing) { if online { Circle().fill(.green).frame(width: 10, height: 10).overlay(Circle().stroke(Palette.surface, lineWidth: 2)) } }
                    .opacity(online ? 1 : 0.45)
                VStack(alignment: .leading, spacing: 1) {
                    Text(member.name + (member.id == model.user?.id ? " (sen)" : "")).font(.subheadline.weight(.medium)).foregroundStyle(online ? Color.primary : Color.secondary).lineLimit(1)
                    if let room = voiceRoom(member.id) { Label(room, systemImage: "speaker.wave.2.fill").font(.caption2).foregroundStyle(.green).lineLimit(1) }
                }
                Spacer(minLength: 0)
            }.padding(.horizontal, 8).frame(minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
    private func voiceRoom(_ id: String) -> String? {
        for room in model.rooms where model.occupants(room.id).contains(where: { $0.id == id }) { return room.name }
        return nil
    }
}

struct MembersTarget: Identifiable { let serverID: String; let name: String; var id: String { serverID } }

private struct ProfileTarget: Identifiable { let id: String }

/// Discord-like server sheet: icon, name, member counts, invite and members.
private struct CommunitySheet: View {
    @ObservedObject var model: RoomsModel
    @ObservedObject var chat: ChatController
    let textChannelID: String?
    let channelCount: Int
    @Environment(\.dismiss) private var dismiss
    @State private var invite: (code: String, link: String, expiresAt: Date?)?
    @State private var creating = false
    @State private var problem: String?
    var body: some View {
        let community = model.selectedCommunity
        let members = community.flatMap { chat.memberDirectory[$0.id] } ?? []
        let online = members.filter { model.onlineUsers.contains($0.id) }.count
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let community {
                        HStack(spacing: 14) {
                            CommunityIconView(model: model, community: community).frame(width: 64, height: 64)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(community.name).font(.title2.bold()).lineLimit(2)
                                HStack(spacing: 12) {
                                    if !members.isEmpty {
                                        Label("\(online) çevrimiçi", systemImage: "circle.fill").foregroundStyle(.green)
                                        Label("\(members.count) üye", systemImage: "circle.fill").foregroundStyle(.secondary)
                                    } else { Label("\(channelCount) kanal", systemImage: "number").foregroundStyle(.secondary) }
                                }.font(.caption).labelStyle(DotLabelStyle())
                            }
                        }
                        HStack(spacing: 10) {
                            Button { Task { await makeInvite() } } label: { Label(creating ? "Hazırlanıyor…" : "Davet et", systemImage: "person.badge.plus").frame(maxWidth: .infinity, minHeight: 44) }
                                .buttonStyle(.borderedProminent).tint(Palette.accent).disabled(creating || textChannelID == nil)
                        }
                        if let invite {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("DAVET BAĞLANTISI").font(.caption2.bold()).foregroundStyle(.secondary)
                                Text(invite.link).font(.system(.footnote, design: .monospaced)).textSelection(.enabled).lineLimit(3)
                                HStack(spacing: 10) {
                                    Button { UIPasteboard.general.string = invite.link } label: { Label("Bağlantıyı kopyala", systemImage: "doc.on.doc") }.buttonStyle(.bordered)
                                    ShareLink(item: "Tayfa'ya katıl: \(invite.link)") { Label("Paylaş", systemImage: "square.and.arrow.up") }.buttonStyle(.bordered)
                                }
                                Text(inviteNote(invite.expiresAt)).font(.caption).foregroundStyle(.secondary)
                            }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(Palette.raised, in: RoundedRectangle(cornerRadius: 14))
                        }
                        if let problem { Text(problem).font(.footnote).foregroundStyle(.secondary) }
                        if textChannelID == nil { Text("Davet için bu toplulukta erişebildiğin bir metin kanalı gerekiyor.").font(.footnote).foregroundStyle(.secondary) }
                    }
                }.padding(20)
            }
            .background(Palette.canvas)
            .navigationTitle("Topluluk").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Kapat") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .task { if let id = community?.id { chat.loadMemberList(serverID: id) } }
    }
    /// What the link does and how long it lasts, as on desktop (10 people, 7 days by default).
    private func inviteNote(_ expires: Date?) -> String {
        let days = expires.map { max(1, Int(($0.timeIntervalSinceNow / 86_400).rounded())) } ?? 7
        return "Bağlantıyı açan arkadaşın Tayfa'yı indirip bu davetle katılır. \(days) gün geçerli, en fazla 10 kişi kullanabilir."
    }
    private func makeInvite() async {
        guard let textChannelID, !creating else { return }
        creating = true; problem = nil; defer { creating = false }
        do { invite = try await model.createInvite(channelID: textChannelID) }
        catch { problem = "Davet oluşturulamadı: \(error.localizedDescription)" }
    }
}
private struct DotLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) { configuration.icon.font(.system(size: 7)); configuration.title.foregroundStyle(.secondary) }
    }
}

/// Discord-like "Sen" tab: profile card, quick status and the way into settings.
private struct YouTab: View {
    @ObservedObject var model: RoomsModel
    @ObservedObject var chat: ChatController
    let openSettings: () -> Void
    let openAudio: () -> Void
    @State private var profile: OwnProfile?
    @State private var problem: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ZStack(alignment: .bottomLeading) {
                    LinearGradient(colors: [Palette.accent.opacity(0.75), Palette.accent.opacity(0.25)], startPoint: .topLeading, endPoint: .bottomTrailing)
                        .frame(height: 110).clipShape(RoundedRectangle(cornerRadius: 18))
                    if let user = model.user {
                        ChatAvatarView(chat: chat, userID: user.id, name: user.name, size: 84)
                            .overlay(Circle().stroke(Palette.canvas, lineWidth: 5))
                            .overlay(alignment: .bottomTrailing) { Circle().fill(Self.color(profile?.presence ?? .online)).frame(width: 20, height: 20).overlay(Circle().stroke(Palette.canvas, lineWidth: 4)) }
                            .offset(x: 16, y: 42)
                    }
                }.padding(.bottom, 42)
                if let user = model.user {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(user.name).font(.title2.bold())
                        Text("@" + user.username).font(.subheadline).foregroundStyle(.secondary)
                        if let status = profile?.statusText, !status.isEmpty { Text(status).font(.subheadline).padding(.top, 4) }
                    }
                }
                HStack(spacing: 10) {
                    Button { openSettings() } label: { Label("Profili düzenle", systemImage: "pencil").frame(maxWidth: .infinity, minHeight: 44) }
                        .buttonStyle(.borderedProminent).tint(Palette.accent)
                    Menu {
                        ForEach(Presence.allCases) { option in Button(option.label) { Task { await setPresence(option) } } }
                    } label: { Label((profile?.presence ?? .online).label, systemImage: "circle.fill").frame(maxWidth: .infinity, minHeight: 44) }
                        .buttonStyle(.bordered).disabled(profile == nil)
                }
                if let problem { Text(problem).font(.footnote).foregroundStyle(.secondary) }
                if let bio = profile?.bio, !bio.isEmpty {
                    VStack(alignment: .leading, spacing: 6) { Text("HAKKINDA").font(.caption2.bold()).foregroundStyle(.secondary); Text(bio).font(.subheadline) }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(14).background(Palette.raised, in: RoundedRectangle(cornerRadius: 14))
                }
                VStack(spacing: 0) {
                    row("Ayarlar", icon: "gearshape.fill", action: openSettings)
                    Divider().overlay(Palette.separator)
                    row("Ses ve görüntü", icon: "slider.horizontal.3", action: openAudio)
                }.background(Palette.raised, in: RoundedRectangle(cornerRadius: 14))
            }.padding(16)
        }
        .task(id: model.user) { do { profile = try await model.loadOwnProfile(); problem = nil } catch { problem = "Profil yüklenemedi: \(error.localizedDescription)" } }
    }
    private func row(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) { Image(systemName: icon).frame(width: 24); Text(title); Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary) }
                .padding(.horizontal, 14).frame(minHeight: 50).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
    private func setPresence(_ value: Presence) async {
        guard var next = profile, next.presence != value else { return }
        let previous = next; next.presence = value; profile = next; problem = nil
        do { try await model.saveProfile(next, avatar: nil, removeAvatar: false) }
        catch { profile = previous; problem = "Durum değiştirilemedi: \(error.localizedDescription)" }
    }
    static func color(_ presence: Presence) -> Color {
        switch presence { case .online: .green; case .idle: .yellow; case .busy: .red; case .invisible: .gray }
    }
}

/// Discord-like user settings: profile, status, app settings and the session.
private struct AccountPanel: View {
    @ObservedObject var model: RoomsModel
    @ObservedObject var chat: ChatController
    @ObservedObject var media: RoomMedia
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var profile: OwnProfile?
    @State private var loadError: String?
    @State private var presenceError: String?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let user = model.user {
                        NavigationLink {
                            ProfileEditView(model: model, chat: chat, profile: profile) { profile = $0 }
                        } label: {
                            HStack(spacing: 14) {
                                ChatAvatarView(chat: chat, userID: user.id, name: user.name, size: 58)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(user.name).font(.headline)
                                    Text("@" + user.username).font(.subheadline).foregroundStyle(.secondary)
                                    if let status = profile?.statusText, !status.isEmpty { Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                                }
                            }.padding(.vertical, 6)
                        }.accessibilityIdentifier("settings.profile")
                    }
                    if let loadError { Text(loadError).font(.footnote).foregroundStyle(.secondary) }
                }
                Section("Durum") {
                    Picker("Durum", selection: Binding(
                        get: { profile?.presence ?? .online },
                        set: { value in Task { await setPresence(value) } }
                    )) {
                        ForEach(Presence.allCases) { Label($0.label, systemImage: Self.icon($0)).tag($0) }
                    }.disabled(profile == nil)
                    if let presenceError { Text(presenceError).font(.footnote).foregroundStyle(.secondary) }
                }
                Section("Uygulama ayarları") {
                    NavigationLink { RoomAudioSettingsView(media: media, chat: chat, embedded: true) } label: { Label("Ses ve görüntü", systemImage: "slider.horizontal.3") }
                    Button { if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) } } label: { Label("Bildirimler", systemImage: "bell.badge") }
                }
                Section { Button("Çıkış yap", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) { dismiss(); Task { await model.logout() } } }
                Section { Text("Tayfa \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""))").font(.footnote).foregroundStyle(.secondary) }
            }.navigationTitle("Ayarlar").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .confirmationAction) { Button("Kapat") { dismiss() } } }
                .task {
                    do { profile = try await model.loadOwnProfile(); loadError = nil }
                    catch { loadError = "Profil yüklenemedi: \(error.localizedDescription)" }
                }
        }
    }
    private func setPresence(_ value: Presence) async {
        guard var next = profile, next.presence != value else { return }
        let previous = next; next.presence = value; profile = next; presenceError = nil
        do { try await model.saveProfile(next, avatar: nil, removeAvatar: false) }
        catch { profile = previous; presenceError = "Durum değiştirilemedi: \(error.localizedDescription)" }
    }
    static func icon(_ presence: Presence) -> String {
        switch presence { case .online: "circle.fill"; case .idle: "moon.fill"; case .busy: "minus.circle.fill"; case .invisible: "circle.dotted" }
    }
}

/// Edit name, about, status message and avatar, like desktop Settings → Profil.
private struct ProfileEditView: View {
    @ObservedObject var model: RoomsModel
    @ObservedObject var chat: ChatController
    let profile: OwnProfile?
    var onSaved: (OwnProfile) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft: OwnProfile?
    @State private var photo: PhotosPickerItem?
    @State private var avatar: (data: Data, mime: String, preview: UIImage)?
    @State private var removeAvatar = false
    @State private var saving = false
    @State private var error: String?
    var body: some View {
        Form {
            if let user = model.user {
                Section {
                    HStack {
                        Spacer()
                        VStack(spacing: 10) {
                            Group {
                                if let preview = avatar?.preview { Image(uiImage: preview).resizable().scaledToFill() }
                                else if removeAvatar { Circle().fill(Palette.accent.opacity(0.2)).overlay(Text(String(user.name.prefix(1))).font(.title.bold())) }
                                else { ChatAvatarView(chat: chat, userID: user.id, name: user.name, size: 96) }
                            }.frame(width: 96, height: 96).clipShape(Circle())
                            HStack(spacing: 16) {
                                PhotosPicker(selection: $photo, matching: .images) { Text("Resmi değiştir") }
                                if draft?.avatarID != nil || avatar != nil { Button("Kaldır", role: .destructive) { avatar = nil; photo = nil; removeAvatar = true } }
                            }.font(.subheadline).buttonStyle(.borderless)
                        }
                        Spacer()
                    }.listRowBackground(Color.clear)
                }
            }
            if let binding = Binding($draft) {
                Section("Görünen ad") { TextField("Görünen ad", text: binding.displayName).textInputAutocapitalization(.words).accessibilityIdentifier("profile.name") }
                Section("Durum mesajı") { TextField("Ne yapıyorsun?", text: binding.statusText).accessibilityIdentifier("profile.status") }
                Section("Hakkında") { TextField("Kendinden bahset", text: binding.bio, axis: .vertical).lineLimit(3...8).accessibilityIdentifier("profile.bio") }
                if let problem = binding.wrappedValue.problem { Section { Text(problem).font(.footnote).foregroundStyle(.secondary) } }
            } else {
                Section { ProgressView("Profil yükleniyor…") }
            }
            if let error { Section { Text(error).font(.footnote).foregroundStyle(.secondary) } }
        }
        .navigationTitle("Profilim").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button(saving ? "Kaydediliyor…" : "Kaydet") { Task { await save() } }.disabled(saving || draft == nil || draft?.problem != nil) } }
        .task {
            guard draft == nil else { return }
            if let profile { draft = profile; return }
            do { draft = try await model.loadOwnProfile() } catch { self.error = "Profil yüklenemedi: \(error.localizedDescription)" }
        }
        .onChange(of: photo) { _, item in Task { await choose(item) } }
    }
    private func choose(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        do {
            guard let data = try await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else { throw RoomsError.invalidResponse }
            let side: CGFloat = 512, scale = min(1, side / max(image.size.width, image.size.height))
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let resized = UIGraphicsImageRenderer(size: size).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
            guard let jpeg = resized.jpegData(compressionQuality: 0.85), jpeg.count <= AvatarPolicy.maxBytes else { throw RoomsError.fileTooLarge }
            avatar = (jpeg, "image/jpeg", resized); removeAvatar = false; error = nil
        } catch { self.error = "Resim kullanılamadı. Başka bir fotoğraf seç." }
    }
    private func save() async {
        guard let draft, !saving else { return }
        saving = true; error = nil
        defer { saving = false }
        do {
            try await model.saveProfile(draft, avatar: avatar.map { ($0.data, $0.mime) }, removeAvatar: removeAvatar)
            onSaved(draft); dismiss()
        } catch { self.error = "Kaydedilemedi: \(error.localizedDescription)" }
    }
}
