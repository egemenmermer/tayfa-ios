import SwiftUI
import RoomsCore

/// The community cinema hall on iPhone (desktop `CinemaHall`): one shared screen, a catalog to open
/// things from, and the hall's chat, queue and viewers. Closing the cover keeps the hall playing in
/// the mini player; leaving gives up the seat.
struct CinemaHallView: View {
    @ObservedObject var hub: CinemaHub
    @ObservedObject var hall: HallModel
    @ObservedObject var chat: ChatController
    let model: RoomsModel
    @Environment(\.verticalSizeClass) private var vertical
    private var miniVisible: Bool { hall.tab != .stage && hall.current != nil }
    var body: some View {
        Group {
            if vertical == .compact, hall.tab == .stage, hall.current != nil {
                // Landscape: the screen alone.
                HallPlayerSurface(player: hall.player, style: .stage).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.black).ignoresSafeArea()
            } else {
                VStack(spacing: 0) {
                    header
                    tabBar
                    banners
                    content.frame(maxWidth: .infinity, maxHeight: .infinity)
                        .safeAreaInset(edge: .bottom, spacing: 0) { if miniVisible { Color.clear.frame(height: 150) } }
                }
            }
        }
        .background(Palette.rail.ignoresSafeArea())
        .overlay(alignment: .bottomTrailing) {
            if miniVisible { HallMiniPlayer(hall: hall, onExpand: { hall.tab = .stage }).padding(12) }
        }
        .overlay(alignment: .top) { if let notice = hall.notice { HallToast(text: notice) } }
        .animation(.snappy(duration: 0.2), value: hall.notice)
        .sheet(isPresented: $hall.searchOpen) { HallSearchSheet(hall: hall) }
        .sheet(item: $hall.details) { HallDetailsSheet(hall: hall, request: $0) }
    }
    private var header: some View {
        HStack(spacing: 4) {
            Button { hub.minimize() } label: { Image(systemName: "chevron.down").font(.headline).frame(width: 44, height: 44) }
                .accessibilityLabel("Salonu küçült").accessibilityHint("Yayın köşedeki küçük oynatıcıda sürer")
            VStack(alignment: .leading, spacing: 1) {
                Text("Sinema").font(.headline)
                Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button { hall.searchOpen = true } label: { Image(systemName: "magnifyingglass").font(.headline).frame(width: 44, height: 44) }
                .accessibilityLabel("Aç…").accessibilityHint("Kanal, film, dizi ya da YouTube bağlantısı arar")
            Menu {
                if hall.canEnd, hall.primary != nil { Button("Salonu herkes için kapat", systemImage: "stop.circle", role: .destructive) { hall.run(.end) } }
                Button("Salondan çık", systemImage: "rectangle.portrait.and.arrow.right") { hub.close() }
            } label: { Image(systemName: "ellipsis.circle").font(.headline).frame(width: 44, height: 44) }
                .accessibilityLabel("Salon seçenekleri")
        }.padding(.horizontal, 6)
    }
    private var subtitle: String {
        let viewers = hall.viewers.count
        if let current = hall.current { return viewers > 0 ? "\(current.media.title) · \(HallRecipes.viewerLabel(viewers))" : current.media.title }
        return viewers > 0 ? HallRecipes.viewerLabel(viewers) : "Topluluğun ortak sineması"
    }
    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(HallTab.allCases) { tab in
                    let selected = hall.tab == tab
                    Button {
                        // A second tap on Filmler/Diziler goes back to its home.
                        if selected, tab == .movies { hall.moviePath = [] } else if selected, tab == .series { hall.seriesPath = [] }
                        hall.tab = tab
                    } label: {
                        HStack(spacing: 5) { Text(tab.rawValue); if tab == .stage, hall.current?.media.isLive == true { HallLiveDot() } }
                            .font(.subheadline.weight(.semibold)).padding(.horizontal, 14).frame(minHeight: 36)
                            .background(selected ? Palette.accent.opacity(0.22) : Color.clear, in: Capsule())
                            .foregroundStyle(selected ? Palette.accent : Color.secondary)
                    }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
                }
            }.padding(.horizontal, 10).padding(.vertical, 4)
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.separator).frame(height: 1) }
    }
    @ViewBuilder private var banners: some View {
        if !hall.activity.reachable, let failure = hall.activity.failure {
            HStack(spacing: 8) {
                Text("Salon hizmetine bağlanılamıyor. \(failure)").font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                Button("Yeniden dene") { hall.activity.stop(); hall.activity.start() }.font(.caption.bold())
            }.padding(10).background(Color.orange.opacity(0.14))
        }
        if let importing = hall.status.importing, importing.running, hall.tab != .stage, hall.tab != .youtube {
            Label("Katalog güncelleniyor: \(Self.step(importing.step))…", systemImage: "arrow.triangle.2.circlepath")
                .font(.caption).foregroundStyle(.secondary).padding(10).frame(maxWidth: .infinity, alignment: .leading).background(Palette.surface)
        }
    }
    private static func step(_ value: String) -> String {
        switch value {
        case "connecting": "sağlayıcıya bağlanılıyor"
        case "live": "kanallar"
        case "movies": "filmler"
        case "series": "diziler"
        case "guide": "yayın akışı"
        default: "hazırlanıyor"
        }
    }
    @ViewBuilder private var content: some View {
        switch hall.tab {
        case .stage: HallSalonTab(hall: hall, chat: chat, model: model)
        case .youtube: HallYouTubeTab(hall: hall)
        case .live, .movies, .series:
            if !hall.status.connected { notConnected }
            else if hall.tab == .live { HallLiveTab(hall: hall) }
            else { HallVodTab(hall: hall, kind: hall.tab == .movies ? .movie : .series) }
        }
    }
    /// Connecting the server's IPTV account is the owner's job on desktop; YouTube works meanwhile.
    private var notConnected: some View {
        ScrollView {
            HallMessage(icon: "powerplug", title: hall.status.isOwner ? "Sunucu IPTV'sini bağla" : "Sahip henüz bir kaynak bağlamadı",
                        detail: hall.status.isOwner
                            ? "Hesabı masaüstündeki Sunucu ayarları → Sinema bölümünden bağla; şifre sunucuda kalır, hiçbir üyeye gitmez. YouTube şimdiden açılabilir."
                            : "Topluluk sahibi sunucunun IPTV hesabını bağladığında kanallar ve filmler burada olacak. Şimdilik YouTube açabilirsin.",
                        action: ("YouTube'a geç", { hall.tab = .youtube })).padding(.top, 40)
        }
    }
}

// MARK: Salon

private struct HallSalonTab: View {
    @ObservedObject var hall: HallModel
    @ObservedObject var chat: ChatController
    let model: RoomsModel
    var body: some View {
        VStack(spacing: 0) {
            if hall.current != nil {
                HallPlayerSurface(player: hall.player, style: .stage).aspectRatio(16 / 9, contentMode: .fit).frame(maxWidth: .infinity).background(Color.black)
                HallNowBar(hall: hall, chat: chat)
            } else {
                HallWelcome(hall: hall)
            }
            Picker("Salon paneli", selection: $hall.panel) {
                ForEach(HallPanelTab.allCases) { tab in Text(label(tab)).tag(tab) }
            }.pickerStyle(.segmented).padding(.horizontal, 12).padding(.vertical, 8)
            Group {
                switch hall.panel {
                case .chat: HallChatPanel(hall: hall, chat: chat, model: model)
                case .queue: HallQueuePanel(hall: hall)
                case .people: HallPeoplePanel(hall: hall, chat: chat)
                }
            }.frame(maxHeight: .infinity)
        }
    }
    private func label(_ tab: HallPanelTab) -> String {
        let count = switch tab {
        case .chat: 0
        case .queue: hall.primary == nil ? 0 : hall.room?.queue.count ?? 0
        case .people: hall.viewers.count
        }
        return count > 0 ? "\(tab.rawValue) \(count)" : tab.rawValue
    }
}

/// Under the screen: what is on, how far along it is, and what comes next (desktop `NowBar`).
private struct HallNowBar: View {
    @ObservedObject var hall: HallModel
    @ObservedObject var chat: ChatController
    @ObservedObject private var titles = YouTubeTitles.shared
    @State private var details: CinemaDetails?
    var body: some View {
        if let current = hall.current {
            let media = current.media, info = hall.knownItem(media.ref)
            TimelineView(.periodic(from: .now, by: 15)) { context in
                let now = context.date.timeIntervalSince1970 * 1000
                let onAir = media.isLive ? hall.onAir(media.ref, now: now) : nil
                let next = media.isLive ? hall.upNext(media.ref, now: now) : nil
                HStack(alignment: .top, spacing: 10) {
                    thumbnail(media, info: info)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 5) {
                            if let number = info?.number { Text("\(number)").font(.caption.monospacedDigit().bold()).padding(.horizontal, 4).background(Palette.raised, in: RoundedRectangle(cornerRadius: 4)) }
                            Text(titles.display(media)).font(.subheadline.bold()).lineLimit(2)
                            if let info { HallBadges(badges: info.badges) }
                        }
                        if let onAir {
                            Text(onAir.title).font(.caption.weight(.semibold)).lineLimit(1)
                            Text("\(HallRecipes.timeRange(onAir)) · \(HallRecipes.minutesLabel(ms: onAir.stop - now)) kaldı").font(.caption2).foregroundStyle(.secondary)
                            ProgressView(value: HallRecipes.share(of: onAir, now: now)).tint(.red).accessibilityHidden(true)
                        } else {
                            Text(detailLine(current)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        if let next { Text("Sıradaki · \(HallRecipes.clock(ms: next.start)) \(next.title)").font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                        else if let upNext = hall.upcoming.first { Text("Sırada: \(titles.display(upNext.media))").font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .trailing, spacing: 8) {
                        HallViewerStack(chat: chat, viewers: hall.viewers)
                        if hall.canEnd {
                            Button("Salonu kapat") { hall.run(.end) }.font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                                .accessibilityHint("Yayını herkes için kapatır")
                        }
                    }
                }.padding(.horizontal, 12).padding(.vertical, 10)
            }
            .task(id: media.ref ?? media.videoId) {
                details = nil
                if media.isLive, let ref = media.ref { hall.wantGuides([ref]) }
                else if media.isCommunity, let ref = media.ref { details = try? await hall.details(ref) }
                else if let id = media.videoId, YouTubeLink.placeholder(media.title) { titles.want([id]) }
            }
        }
    }
    @ViewBuilder private func thumbnail(_ media: ActivityMedia, info: CinemaItem?) -> some View {
        if media.isCommunity {
            HallArtView(hall: hall, art: media.art ?? info?.art ?? details?.item.art, title: media.title, shape: media.isLive ? .logo : .poster)
                .frame(width: 44, height: media.isLive ? 44 : 64).clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            AsyncImage(url: media.videoId.flatMap(YouTubeLink.thumbnail)) { $0.resizable().scaledToFill() } placeholder: { Palette.raised }
                .frame(width: 64, height: 36).clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
    private func detailLine(_ item: ActivityQueueItem) -> String {
        let opened = HallRecipes.did(hall.name(item.addedBy), "açtı")
        if item.media.isLive { return "Canlı yayın" }
        if !item.media.isCommunity { return "YouTube · \(opened)" }
        return [details?.item.year.map(String.init), details?.genre, details?.durationSec.map { HallRecipes.minutesLabel(ms: $0 * 1000) }, opened].compactMap { $0 }.joined(separator: " · ")
    }
}

struct HallViewerStack: View {
    @ObservedObject var chat: ChatController
    let viewers: [ActivityParticipant]
    var body: some View {
        if !viewers.isEmpty {
            HStack(spacing: -7) {
                ForEach(viewers.prefix(3)) { person in ChatAvatarView(chat: chat, userID: person.userId, name: person.displayName, size: 24) }
                if viewers.count > 3 { Text("+\(viewers.count - 3)").font(.caption2.weight(.semibold)).foregroundStyle(.secondary).padding(.leading, 10) }
            }
            .accessibilityElement(children: .ignore).accessibilityLabel(HallRecipes.viewerLabel(viewers.count))
        }
    }
}

/// Shown where the screen is when nothing plays: what to do, and what is on now, one tap away.
private struct HallWelcome: View {
    @ObservedObject var hall: HallModel
    @State private var candidates: [CinemaItem] = []
    var body: some View {
        let now = Date().timeIntervalSince1970 * 1000
        let picks = candidates.filter { hall.onAir($0.ref, now: now) != nil }.prefix(6)
        VStack(spacing: 10) {
            Image(systemName: "popcorn.fill").font(.title2).foregroundStyle(Palette.accent)
            Text("Bu akşam ne izliyoruz?").font(.headline)
            Text(lead).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button { hall.searchOpen = true } label: { Label("Aç…", systemImage: "magnifyingglass") }.buttonStyle(.borderedProminent)
                if hall.status.connected {
                    Button { hall.tab = .live } label: { Label("Canlı TV", systemImage: "tv") }.buttonStyle(.bordered)
                    Button { hall.tab = .movies } label: { Label("Filmler", systemImage: "film") }.buttonStyle(.bordered)
                } else {
                    Button { hall.tab = .youtube } label: { Label("YouTube", systemImage: "play.rectangle") }.buttonStyle(.bordered)
                }
            }.font(.footnote.weight(.semibold))
            if hall.primary == nil, hall.connected {
                if hall.room?.canStart(hall.me) ?? true {
                    Button("Salonu aç, birlikte seçelim") { hall.run(.start(activity: "hall", title: HallRecipes.title)) }.font(.caption.weight(.semibold))
                } else {
                    Text("Bu salonda etkinlik başlatma iznin yok; açık olduğunda izleyebilirsin.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if !picks.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 5) { HallLiveDot(); Text("ŞU AN YAYINDA").font(.caption2.weight(.heavy)).foregroundStyle(.red) }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) { ForEach(Array(picks)) { item in pick(item, now: now) } }
                    }
                }.padding(.top, 4)
            }
        }
        .padding(16).frame(maxWidth: .infinity)
        .background(LinearGradient(colors: [Palette.accent.opacity(0.22), Palette.rail], startPoint: .top, endPoint: .bottom))
        .task(id: hall.status.connected) {
            guard hall.status.connected, let page = try? await hall.items(.live, category: nil, limit: 60) else { return }
            candidates = Array(page.items.filter { $0.hasGuide == true }.prefix(12))
            hall.wantGuides(candidates.map(\.ref))
        }
    }
    private var lead: String {
        if hall.status.connected { return "Açtığın şey salondaki herkes için aynı anda oynar." }
        return hall.status.isOwner ? "Sunucunun IPTV hesabını masaüstünden bağlayınca kanallar ve filmler burada olacak. YouTube şimdiden açılabilir." : "Sahip henüz bir kaynak bağlamadı. Şimdilik YouTube açabilirsin."
    }
    private func pick(_ item: CinemaItem, now: Double) -> some View {
        let onAir = hall.onAir(item.ref, now: now)
        return Button { Task { await hall.openItem(item) } } label: {
            HStack(spacing: 8) {
                HallArtView(hall: hall, art: item.art, title: item.title).frame(width: 40, height: 40).clipShape(RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(.caption.weight(.semibold)).lineLimit(1)
                    Text(onAir?.title ?? "").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    ProgressView(value: HallRecipes.share(of: onAir, now: now)).tint(.red).accessibilityHidden(true)
                }.frame(width: 120, alignment: .leading)
            }.padding(8).background(Palette.surface, in: RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain).accessibilityLabel("\(item.title), şu an \(onAir?.title ?? "yayında")").accessibilityHint(hall.steers ? "Salonda açar" : "Sıraya önerir")
    }
}

// MARK: Panels

/// The hall is a real channel: its chat stays after the show. It borrows the app's single open
/// conversation and gives it back when the panel closes (desktop `HallChat`).
private struct HallChatPanel: View {
    @ObservedObject var hall: HallModel
    @ObservedObject var chat: ChatController
    let model: RoomsModel
    private var channel: TextChannel? { chat.channels.first { $0.id == hall.id } }
    var body: some View {
        Group {
            if chat.selected?.id == hall.id { ChatConversationView(chat: chat, currentUserID: hall.me, channelID: hall.id) }
            else if channel == nil && !chat.catalogLoading {
                HallMessage(icon: "bubble.left.and.bubble.right", title: "Salon sohbeti açılamadı", detail: "Kanal listesi yenilendiğinde yeniden dene.", action: ("Yeniden dene", { chat.retryCatalog() }))
            } else { ProgressView("Sohbet açılıyor…").font(.footnote).frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .onAppear { openHallChat() }
        .onChange(of: chat.channels.map(\.id)) { _, _ in openHallChat() }
        .onDisappear { restore() }
    }
    private func openHallChat() { if let channel, chat.selected?.id != hall.id { chat.open(channel) } }
    private func restore() {
        guard chat.selected?.id == hall.id else { return }
        guard let id = model.conversationPath.last, let previous = chat.channels.first(where: { $0.id == id }) else { chat.close(); return }
        chat.open(previous)
        // Back on screen once the hall is minimized or closed; still hidden under the hall otherwise.
        if !model.cinema.expanded { chat.setConversationVisible(true, channelID: id) }
    }
}

/// The shared queue (desktop `HallQueue`): the remote holder selects, reorders and clears; anyone
/// removes what they added.
private struct HallQueuePanel: View {
    @ObservedObject var hall: HallModel
    @ObservedObject private var titles = YouTubeTitles.shared
    @State private var confirming = false
    @State private var confirmReset: Task<Void, Never>?
    var body: some View {
        let queue = hall.primary == nil ? [] : hall.room?.queue ?? []
        let current = hall.current, currentIndex = queue.firstIndex { $0.id == current?.id }
        let others = queue.filter { $0.id != current?.id }.count
        if queue.isEmpty {
            ScrollView { HallMessage(icon: "film.stack", title: "Sıra boş", detail: "Üstteki büyüteçle bir kanal, film ya da YouTube videosu ekle.") }
        } else {
            List {
                if others > 0 {
                    Section {
                        HStack {
                            Text("\(queue.count) öğe").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button(role: .destructive) { clear() } label: { Label(confirming ? "\(others) öğeyi kaldır" : "Sırayı temizle", systemImage: "trash").font(.caption.weight(.semibold)) }
                                .disabled(!hall.canDirect).accessibilityHint(confirming ? "Oynayan dışındaki her şeyi kaldırır" : "İki kez dokun")
                        }
                        if !hall.canDirect { Text("Sırayı yalnızca kumandayı tutan temizler. \(hall.directReason)").font(.caption2).foregroundStyle(.secondary) }
                    }.listRowBackground(Palette.surface)
                }
                Section {
                    ForEach(Array(queue.enumerated()), id: \.element.id) { index, item in
                        row(item, index: index, queue: queue, playing: item.id == current?.id, watched: currentIndex.map { index < $0 } ?? false)
                    }
                    .onMove { source, destination in move(queue, from: source, to: destination) }
                }
            }
            .listStyle(.plain).scrollContentBackground(.hidden)
            .task(id: queue.map(\.id)) { titles.want(queue.filter { YouTubeLink.placeholder($0.media.title) }.compactMap(\.media.videoId)) }
        }
    }
    private func row(_ item: ActivityQueueItem, index: Int, queue: [ActivityQueueItem], playing: Bool, watched: Bool) -> some View {
        let removable = !playing && (item.addedBy == hall.me || hall.canDirect)
        return Button {
            guard !playing else { return }
            if hall.canDirect { hall.run(.select(itemID: item.id, play: true)) } else { hall.show(hall.directReason) }
        } label: {
            HStack(spacing: 10) {
                thumb(item.media).frame(width: 64, height: 36).clipShape(RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 2) {
                    Text(titles.display(item.media)).font(.footnote.weight(.semibold)).lineLimit(2).foregroundStyle(.primary)
                    if playing { HStack(spacing: 4) { if item.media.isLive { HallLiveDot() }; Text("Şimdi oynuyor") }.font(.caption2.weight(.bold)).foregroundStyle(Palette.accent) }
                    else { Text(HallRecipes.did(hall.name(item.addedBy), "ekledi")).font(.caption2).foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, alignment: .leading)
                if !playing && hall.canDirect { Image(systemName: "play.circle").foregroundStyle(Palette.accent) }
            }.opacity(watched ? 0.55 : 1).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(playing ? Palette.accent.opacity(0.12) : Color.clear)
        .moveDisabled(!hall.canDirect || playing)
        .swipeActions(edge: .trailing) {
            if removable { Button(role: .destructive) { hall.run(.remove(itemID: item.id)) } label: { Label("Kaldır", systemImage: "trash") } }
        }
        .contextMenu {
            if hall.canDirect, !playing {
                Button("Yukarı taşı", systemImage: "arrow.up") { move(queue, from: IndexSet(integer: index), to: index - 1) }.disabled(index == 0)
                Button("Aşağı taşı", systemImage: "arrow.down") { move(queue, from: IndexSet(integer: index), to: index + 2) }.disabled(index == queue.count - 1)
            }
            if removable { Button("Sıradan kaldır", systemImage: "trash", role: .destructive) { hall.run(.remove(itemID: item.id)) } }
        }
        .accessibilityHint(playing ? "Şu an oynuyor" : hall.canDirect ? "Şimdi açar" : hall.directReason)
    }
    @ViewBuilder private func thumb(_ media: ActivityMedia) -> some View {
        if media.isCommunity { HallArtView(hall: hall, art: media.art, title: media.title, shape: media.isLive ? .logo : .wide) }
        else { AsyncImage(url: media.videoId.flatMap(YouTubeLink.thumbnail)) { $0.resizable().scaledToFill() } placeholder: { Palette.raised } }
    }
    private func move(_ queue: [ActivityQueueItem], from source: IndexSet, to destination: Int) {
        guard hall.canDirect, destination >= 0 else { return }
        guard let ids = HallRecipes.reorder(queue, current: hall.current?.id, from: source, to: destination) else {
            // The service keeps the playing item where it is; say so instead of silently refusing.
            if HallRecipes.reorder(queue, current: nil, from: source, to: destination) != nil { hall.show("Şu an oynayan öğe yerinde kalır.") }
            return
        }
        hall.run(.reorder(itemIDs: ids))
    }
    /// A second tap within a few seconds confirms; nothing else asks first.
    private func clear() {
        guard hall.canDirect else { return }
        if !confirming {
            confirming = true; confirmReset?.cancel()
            confirmReset = Task { try? await Task.sleep(for: .seconds(4)); if !Task.isCancelled { confirming = false } }
            return
        }
        confirming = false; confirmReset?.cancel(); hall.run(.clear)
    }
}

/// Who is watching and who steers (desktop `HallPeople`).
private struct HallPeoplePanel: View {
    @ObservedObject var hall: HallModel
    @ObservedObject var chat: ChatController
    var body: some View {
        let people = hall.viewers, hostOnly = hall.primary?.hostOnly == true
        if people.isEmpty {
            ScrollView { HallMessage(icon: "person.2", title: "Salonda şu an kimse yok", detail: "Bir şey açtığında izleyenler burada görünür.") }
        } else {
            List {
                Section {
                    Picker("Kumanda", selection: Binding(get: { hostOnly }, set: { value in if value != hostOnly { hall.run(.sessionControl(hostOnly: value)) } })) {
                        Text("Herkes yönetir").tag(false); Text("Ev sahibi yönetir").tag(true)
                    }.pickerStyle(.segmented).disabled(!hall.isHost)
                    Text(hostOnly ? "Oynatmayı ev sahibi ve kumanda verdikleri yönetir. Diğerleri sıraya öneri ekler." : "Salondaki herkes kanal değiştirebilir, oynatıp durdurabilir.")
                        .font(.caption).foregroundStyle(.secondary)
                    if !hall.isHost { Text("Kumanda ayarını yalnızca ev sahibi değiştirir.").font(.caption2).foregroundStyle(.secondary) }
                }.listRowBackground(Palette.surface)
                Section(HallRecipes.viewerLabel(people.count)) {
                    ForEach(people) { person in row(person, hostOnly: hostOnly) }
                }.listRowBackground(Palette.surface)
            }.scrollContentBackground(.hidden)
        }
    }
    private func row(_ person: ActivityParticipant, hostOnly: Bool) -> some View {
        let host = hall.primary?.hostUserId == person.userId
        let remote = !host && hostOnly && (hall.primary?.controllers ?? []).contains(person.userId)
        return HStack(spacing: 10) {
            ChatAvatarView(chat: chat, userID: person.userId, name: person.displayName, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(person.userId == hall.me ? "\(person.displayName) (sen)" : person.displayName).font(.subheadline).lineLimit(1)
                Group {
                    if host { Label("Ev sahibi", systemImage: "crown.fill") }
                    else if remote { Label("Kumandası var", systemImage: "gamecontroller.fill") }
                    else { Text("İzliyor") }
                }.font(.caption2).foregroundStyle(host ? .yellow : .secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if hall.isHost, person.userId != hall.me {
                Menu {
                    if hostOnly {
                        Button(remote ? "Kumandayı geri al" : "Kumandayı ver", systemImage: remote ? "person.badge.minus" : "person.badge.plus") { hall.run(.sessionPermit(userID: person.userId, allowed: !remote)) }
                    }
                    Button("Ev sahipliğini devret", systemImage: "crown") { hall.run(.sessionHost(userID: person.userId)) }.disabled(!person.canControl)
                    if !person.canControl { Text("Bu kişinin salonda yönetme izni yok.") }
                } label: { Image(systemName: "ellipsis").frame(width: 40, height: 40) }
                    .accessibilityLabel("\(person.displayName) için seçenekler")
            }
        }
    }
}

// MARK: Mini player and notices

/// The hall's screen in a corner while browsing; a tap brings the stage back.
struct HallMiniPlayer: View {
    @ObservedObject var hall: HallModel
    var onExpand: () -> Void
    var onClose: (() -> Void)? = nil
    @ObservedObject private var titles = YouTubeTitles.shared
    var body: some View {
        // System Picture in Picture already shows the stream; the corner player steps aside meanwhile.
        HiddenDuringPictureInPicture(player: hall.player) { corner }
    }
    private var corner: some View {
        VStack(spacing: 0) {
            HallPlayerSurface(player: hall.player, style: .mini).aspectRatio(16 / 9, contentMode: .fit).background(Color.black)
                .contentShape(Rectangle()).onTapGesture(perform: onExpand)
            HStack(spacing: 4) {
                if hall.current?.media.isLive == true { HallLiveDot().padding(.leading, 8) }
                Text(hall.current.map { titles.display($0.media) } ?? "Sinema").font(.caption2).lineLimit(1).padding(.leading, hall.current?.media.isLive == true ? 0 : 8)
                Spacer(minLength: 0)
                Button(action: onExpand) { Image(systemName: "arrow.up.left.and.arrow.down.right").font(.caption).frame(width: 36, height: 36) }.accessibilityLabel("Salonu büyüt")
                if let onClose { Button(action: onClose) { Image(systemName: "xmark").font(.caption).frame(width: 36, height: 36) }.accessibilityLabel("Salondan çık") }
            }.frame(height: 36).background(Palette.raised)
        }
        .frame(width: 196).clipShape(RoundedRectangle(cornerRadius: 13)).overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(Palette.accent.opacity(0.4)))
        .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
        .accessibilityElement(children: .contain).accessibilityAction(named: "Salonu büyüt", onExpand)
    }
}
private struct HiddenDuringPictureInPicture<Content: View>: View {
    @ObservedObject var player: HallPlayerController
    @ViewBuilder var content: Content
    var body: some View { if !player.pictureInPictureActive { content } }
}
struct HallToast: View {
    let text: String
    var body: some View {
        Text(text).font(.footnote.weight(.semibold)).multilineTextAlignment(.center).padding(.horizontal, 14).padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule()).padding(.top, 8).padding(.horizontal, 16)
            .transition(.move(edge: .top).combined(with: .opacity))
    }
}
