import SwiftUI
import RoomsCore

// MARK: Shared pieces

enum HallArtShape { case logo, poster, wide }

/// Provider artwork through the cinema service, with a calm lettered tile when there is none (desktop `CinemaArt`).
struct HallArtView: View {
    let hall: HallModel
    let art: String?
    let title: String
    var shape = HallArtShape.logo
    @State private var image: UIImage?
    private var pixels: Int { shape == .logo ? 240 : 420 }
    var body: some View {
        ZStack {
            Palette.raised
            if let image {
                if shape == .logo { Image(uiImage: image).resizable().scaledToFit().padding(6) }
                else { Image(uiImage: image).resizable().scaledToFill() }
            } else {
                let letters = HallRecipes.initials(title, count: shape == .logo ? 2 : 3)
                Text(letters.isEmpty ? "·" : letters).font((shape == .logo ? Font.headline : .title3).weight(.bold)).foregroundStyle(.secondary)
            }
        }
        .clipped().accessibilityHidden(true)
        .task(id: art) {
            image = hall.art.cached(art, pixels: pixels)
            guard image == nil, art != nil else { return }
            // Fast scrolling only fetches what stays on screen.
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            image = await hall.art.image(art, pixels: pixels)
        }
    }
}
/// `FHD`-style quality badges, outlined like a TV guide.
struct HallBadges: View {
    let badges: [String]
    var max = 2
    @ScaledMetric(relativeTo: .caption2) private var badgeSize: CGFloat = 9
    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(badges.prefix(max)), id: \.self) { badge in
                Text(badge).font(.system(size: badgeSize, weight: .bold)).padding(.horizontal, 4).padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.secondary.opacity(0.6))).foregroundStyle(.secondary)
            }
        }
    }
}
/// Red marks only what is live.
struct HallLiveDot: View {
    var body: some View { Circle().fill(Color.red).frame(width: 7, height: 7).accessibilityHidden(true) }
}
struct HallNote: View {
    let text: String
    var icon = "info.circle"
    var body: some View {
        Label(text, systemImage: icon).font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            .padding(10).background(Palette.surface, in: RoundedRectangle(cornerRadius: 10))
    }
}
struct HallMessage: View {
    let icon: String
    let title: String
    let detail: String
    var action: (label: String, run: () -> Void)?
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.largeTitle).foregroundStyle(Palette.accent)
            Text(title).font(.headline).multilineTextAlignment(.center)
            Text(detail).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let action { Button(action.label, action: action.run).buttonStyle(.borderedProminent).padding(.top, 4) }
        }.padding(28).frame(maxWidth: .infinity)
    }
}

// MARK: Canlı TV

/// Live TV (desktop `LiveTab`): categories and a calm grid of channel tiles; a tap opens the channel
/// in the hall, or suggests it when someone else holds the remote.
struct HallLiveTab: View {
    @ObservedObject var hall: HallModel
    @State private var categories: [CinemaCategory]?
    @State private var categoryError: String?
    @State private var items: [CinemaItem] = []
    @State private var total = 0
    @State private var loading = false
    @State private var error: String?
    @State private var filter = ""
    @State private var loadToken = UUID()
    private static let page = 200
    private var list: [CinemaItem] { filter.trimmingCharacters(in: .whitespaces).isEmpty ? items : items.filter { HallRecipes.matches($0.title, filter: filter) } }
    var body: some View {
        VStack(spacing: 0) {
            chips
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Bu listede ara", text: $filter).textInputAutocapitalization(.never).autocorrectionDisabled().font(.subheadline)
                if !filter.isEmpty { Button { filter = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.accessibilityLabel("Filtreyi temizle") }
            }.padding(.horizontal, 12).frame(minHeight: 40).background(Palette.raised, in: RoundedRectangle(cornerRadius: 10)).padding(.horizontal, 12).padding(.bottom, 8)
            ScrollView {
                if !hall.steers { HallNote(text: hall.directReason, icon: "lock").padding(.horizontal, 12).padding(.bottom, 8) }
                if loading && items.isEmpty { ProgressView("Kanallar yükleniyor…").font(.footnote).padding(.top, 40) }
                else if let error, items.isEmpty { HallMessage(icon: "tv", title: "Kanallar alınamadı", detail: error, action: ("Yeniden dene", { Task { await load(reset: true) } })) }
                else if list.isEmpty { Text(filter.isEmpty ? "Bu kategoride kanal yok." : total > items.count ? "Yüklenen kanallarda bu ad yok. Daha fazlasını yükleyebilir ya da üstteki aramayı kullanabilirsin." : "Bu adla bir kanal yok.").font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(24) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 10)], spacing: 10) {
                    ForEach(list) { item in tile(item) }
                }.padding(.horizontal, 12)
                if items.count < total {
                    Button { Task { await load(reset: false) } } label: {
                        HStack { if loading { ProgressView() }; Text("Daha fazla (\(items.count)/\(total))") }.frame(maxWidth: .infinity, minHeight: 44)
                    }.disabled(loading).padding(12)
                }
            }
        }
        .task(id: hall.liveCategory) { await load(reset: true) }
        .task { await loadCategories() }
        .onChange(of: list.map(\.ref), initial: true) { _, _ in hall.zapList = list }
    }
    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(id: nil, flag: nil, label: "Tüm kanallar", count: categories?.reduce(0) { $0 + $1.count })
                ForEach(categories ?? []) { category in chip(id: category.id, flag: category.flag, label: category.label, count: category.count) }
                if categories == nil, categoryError == nil { ProgressView().padding(.horizontal, 8) }
                if categoryError != nil { Button("Kategoriler alınamadı · Yeniden dene") { Task { await loadCategories() } }.font(.caption) }
            }.padding(.horizontal, 12).padding(.vertical, 8)
        }
    }
    private func chip(id: String?, flag: String?, label: String, count: Int?) -> some View {
        let selected = hall.liveCategory == id
        return Button { hall.liveCategory = id } label: {
            HStack(spacing: 5) {
                if let flag { Text(flag) } else if id == nil { Image(systemName: "tv") }
                Text(label).lineLimit(1)
                if let count, count > 0 { Text("\(count)").foregroundStyle(.secondary) }
            }.font(.footnote.weight(.semibold)).padding(.horizontal, 12).frame(minHeight: 34)
                .background(selected ? Palette.accent.opacity(0.22) : Palette.raised, in: Capsule())
                .foregroundStyle(selected ? Palette.accent : Color.primary)
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
    private func tile(_ item: CinemaItem) -> some View {
        let playing = item.ref == hall.currentRef
        let onAir = item.hasGuide == true ? hall.onAir(item.ref)?.title : nil
        return Button {
            guard !playing else { hall.tab = .stage; return }
            Task { await hall.openItem(item) }
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HallArtView(hall: hall, art: item.art, title: item.title).frame(height: 54).clipShape(RoundedRectangle(cornerRadius: 8))
                Text(item.title).font(.caption.weight(.semibold)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 4) {
                    if playing { HallLiveDot(); Text("Salonda").font(.caption2.weight(.bold)).foregroundStyle(.red) }
                    else {
                        if let number = item.number { Text("\(number)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary) }
                        HallBadges(badges: item.badges, max: 1)
                        Spacer(minLength: 0)
                        Image(systemName: hall.steers ? "play.fill" : "text.badge.plus").font(.caption2).foregroundStyle(Palette.accent)
                    }
                }
                if let onAir { Text(onAir).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
            }
            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
            .background(playing ? Color.red.opacity(0.1) : Palette.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(playing ? Color.red.opacity(0.5) : Palette.separator))
        }
        .buttonStyle(.plain)
        .accessibilityLabel([item.number.map { "\($0)" }, item.title, onAir].compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint(playing ? "Bu kanal salonda açık" : hall.steers ? "Salonda açar" : "Sıraya önerir")
        .onAppear { if item.hasGuide == true { hall.wantGuides([item.ref]) } }
    }
    private func loadCategories() async {
        categoryError = nil
        do { categories = try await hall.categories(.live) } catch is CancellationError {} catch { categoryError = HallRecipes.errorText(error) }
    }
    private func load(reset: Bool) async {
        let category = hall.liveCategory, token = UUID()
        if reset { items = []; total = 0; error = nil }
        loadToken = token; loading = true
        // A cancelled load must not hide the spinner of the one that replaced it.
        defer { if loadToken == token { loading = false } }
        do {
            let page = try await hall.items(.live, category: category, offset: reset ? 0 : items.count, limit: Self.page)
            guard category == hall.liveCategory else { return }
            items = reset ? page.items : items + page.items.filter { new in !items.contains { $0.ref == new.ref } }
            total = page.total
        } catch is CancellationError {
        } catch { self.error = HallRecipes.errorText(error) }
    }
}

// MARK: Filmler / Diziler

/// Films or series (desktop `VodTab`): new arrivals and category rows, a full grid per category,
/// and the details sheet.
struct HallVodTab: View {
    @ObservedObject var hall: HallModel
    let kind: CinemaKind
    var body: some View {
        NavigationStack(path: kind == .movie ? $hall.moviePath : $hall.seriesPath) {
            HallVodHome(hall: hall, kind: kind)
                .navigationDestination(for: VodRoute.self) { route in HallVodGrid(hall: hall, kind: kind, route: route) }
                .toolbar(.hidden, for: .navigationBar)
        }
    }
}
private struct HallVodHome: View {
    @ObservedObject var hall: HallModel
    let kind: CinemaKind
    @State private var recent: [CinemaItem]?
    @State private var categories: [CinemaCategory] = []
    @State private var error: String?
    private var noun: String { kind == .movie ? "film" : "dizi" }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                if let error, recent == nil { HallMessage(icon: "film", title: "Katalog alınamadı", detail: error, action: ("Yeniden dene", { Task { await load() } })) }
                else if recent == nil { ProgressView("Yükleniyor…").font(.footnote).frame(maxWidth: .infinity).padding(.top, 40) }
                else if recent?.isEmpty == true { Text("Katalogda henüz \(noun) yok.").font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 40) }
                else {
                    HallPosterRow(hall: hall, kind: kind, title: "Yeni eklenenler", count: nil, items: recent, route: VodRoute(category: nil, label: kind == .movie ? "Tüm filmler" : "Tüm diziler"))
                    ForEach(categories.prefix(8)) { category in HallCategoryRow(hall: hall, kind: kind, category: category) }
                }
            }.padding(.vertical, 12)
        }
        .task { await load() }
    }
    private func load() async {
        error = nil
        do {
            recent = try await hall.items(kind, category: nil, sort: .added, limit: 24).items
            categories = (try? await hall.categories(kind)) ?? []
        } catch is CancellationError {} catch { self.error = HallRecipes.errorText(error) }
    }
}
/// A category row loads its first twenty items when it comes into view.
private struct HallCategoryRow: View {
    @ObservedObject var hall: HallModel
    let kind: CinemaKind
    let category: CinemaCategory
    @State private var items: [CinemaItem]?
    var body: some View {
        HallPosterRow(hall: hall, kind: kind, title: category.label, count: category.count, items: items, route: VodRoute(category: category.id, label: category.label))
            .task { if items == nil { items = (try? await hall.items(kind, category: category.id, limit: 20))?.items ?? [] } }
    }
}
private struct HallPosterRow: View {
    @ObservedObject var hall: HallModel
    let kind: CinemaKind
    let title: String
    let count: Int?
    let items: [CinemaItem]?
    let route: VodRoute
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.headline).lineLimit(1)
                if let count { Text("\(count)").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                NavigationLink(value: route) { HStack(spacing: 3) { Text("Tümünü gör"); Image(systemName: "chevron.right") }.font(.footnote.weight(.semibold)) }
            }.padding(.horizontal, 14)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 10) {
                    if let items { ForEach(items) { item in HallPoster(hall: hall, item: item).frame(width: 112) } }
                    else { ForEach(0..<5, id: \.self) { _ in RoundedRectangle(cornerRadius: 10).fill(Palette.raised).frame(width: 112, height: 168) } }
                }.padding(.horizontal, 14)
            }
        }
    }
}
struct HallPoster: View {
    @ObservedObject var hall: HallModel
    let item: CinemaItem
    @ScaledMetric(relativeTo: .caption2) private var badgeSize: CGFloat = 9
    var body: some View {
        Button { hall.details = HallDetailsRequest(ref: item.ref, kind: item.kind) } label: {
            VStack(alignment: .leading, spacing: 4) {
                HallArtView(hall: hall, art: item.art, title: item.title, shape: .poster).aspectRatio(2 / 3, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(alignment: .topLeading) {
                        if HallRecipes.isNew(addedAt: item.addedAt, now: Date().timeIntervalSince1970 * 1000) {
                            Text("Yeni").font(.system(size: badgeSize, weight: .heavy)).padding(.horizontal, 5).padding(.vertical, 2).background(Palette.accent, in: RoundedRectangle(cornerRadius: 4)).foregroundStyle(Palette.canvas).padding(6)
                        }
                    }
                Text(item.title).font(.caption.weight(.semibold)).lineLimit(2).foregroundStyle(.primary)
                let meta = [item.year.map(String.init), item.rating.map { "★ " + HallRecipes.rating($0) }].compactMap { $0 }.joined(separator: " · ")
                if !meta.isEmpty { Text(meta).font(.caption2).foregroundStyle(.secondary) }
            }
        }.buttonStyle(.plain).accessibilityLabel(item.title).accessibilityHint("Ayrıntıları açar")
    }
}
private struct HallVodGrid: View {
    @ObservedObject var hall: HallModel
    let kind: CinemaKind
    let route: VodRoute
    @State private var sort = CinemaSort.added
    @State private var items: [CinemaItem] = []
    @State private var total = 0
    @State private var loading = false
    @State private var error: String?
    @State private var loadToken = UUID()
    private static let page = 60
    var body: some View {
        ScrollView {
            if let error, items.isEmpty { HallMessage(icon: "film", title: "Liste alınamadı", detail: error, action: ("Yeniden dene", { Task { await load(reset: true) } })) }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 10)], spacing: 14) {
                ForEach(items) { item in HallPoster(hall: hall, item: item).onAppear { if item.ref == items.last?.ref, items.count < total { Task { await load(reset: false) } } } }
            }.padding(14)
            if loading { ProgressView().padding() }
        }
        .navigationTitle(route.label).navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar).toolbarBackground(Palette.rail, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sırala", selection: $sort) {
                        Text("Yeni eklenen").tag(CinemaSort.added); Text("Ada göre").tag(CinemaSort.name)
                        Text("Puana göre").tag(CinemaSort.rating); Text("Sağlayıcının sırası").tag(CinemaSort.standard)
                    }
                } label: { Label("Sırala", systemImage: "arrow.up.arrow.down") }
            }
        }
        .task(id: sort) { await load(reset: true) }
    }
    private func load(reset: Bool) async {
        guard !loading || reset else { return }
        let order = sort, token = UUID()
        if reset { items = []; total = 0; error = nil }
        loadToken = token; loading = true
        defer { if loadToken == token { loading = false } }
        do {
            let page = try await hall.items(kind, category: route.category, sort: order, offset: reset ? 0 : items.count, limit: Self.page)
            guard order == sort else { return }
            items = reset ? page.items : items + page.items.filter { new in !items.contains { $0.ref == new.ref } }
            total = page.total
        } catch is CancellationError {} catch { self.error = HallRecipes.errorText(error) }
    }
}

// MARK: Details

/// A film or a series: credits, the same title in other qualities, and seasons with their episodes
/// (desktop `VodDetails`).
struct HallDetailsView: View {
    @ObservedObject var hall: HallModel
    let request: HallDetailsRequest
    /// Called after something was opened or suggested, so the caller can close.
    var onDone: () -> Void = {}
    @ScaledMetric(relativeTo: .caption2) private var badgeSize: CGFloat = 9
    @State private var ref: String?
    @State private var data: CinemaDetails?
    @State private var error: String?
    @State private var season: Int?
    var body: some View {
        ScrollView {
            if let data { content(data) }
            else if let error { HallMessage(icon: "film", title: "Ayrıntılar alınamadı", detail: error, action: ("Yeniden dene", { Task { await load() } })) }
            else { ProgressView("Yükleniyor…").font(.footnote).frame(maxWidth: .infinity).padding(.top, 60) }
        }
        .background(Palette.rail.ignoresSafeArea())
        .navigationTitle(data?.item.title ?? "Ayrıntılar").navigationBarTitleDisplayMode(.inline)
        .task(id: ref ?? request.ref) { await load() }
    }
    private func load() async {
        let wanted = ref ?? request.ref
        error = nil; data = hall.cachedDetails(wanted)
        guard data == nil else { return }
        do { let value = try await hall.details(wanted); if wanted == ref ?? request.ref { data = value } }
        catch is CancellationError {} catch { self.error = HallRecipes.errorText(error) }
    }
    @ViewBuilder private func content(_ data: CinemaDetails) -> some View {
        let item = data.item
        VStack(alignment: .leading, spacing: 14) {
            ZStack(alignment: .bottomLeading) {
                HallArtView(hall: hall, art: data.backdrop ?? item.art, title: item.title, shape: .wide).frame(height: 190).frame(maxWidth: .infinity)
                    .overlay(LinearGradient(colors: [.clear, Palette.rail], startPoint: .center, endPoint: .bottom))
                HStack(alignment: .bottom, spacing: 12) {
                    HallArtView(hall: hall, art: item.art, title: item.title, shape: .poster).frame(width: 84, height: 126).clipShape(RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(request.kind == .series ? "DİZİ" : "FİLM").font(.caption2.weight(.heavy)).foregroundStyle(Palette.accent)
                        Text(item.title).font(.title3.bold()).lineLimit(3)
                    }
                }.padding(.horizontal, 14)
            }
            meta(data).padding(.horizontal, 14)
            if let plot = data.plot, !plot.isEmpty { Text(plot).font(.subheadline).foregroundStyle(.secondary).padding(.horizontal, 14) }
            VStack(alignment: .leading, spacing: 4) {
                if let director = data.director, !director.isEmpty { credit("Yönetmen", director) }
                if let cast = data.cast, !cast.isEmpty { credit("Oyuncular", cast) }
            }.padding(.horizontal, 14)
            if let versions = data.versions, !versions.isEmpty { qualities(item: item, versions: versions).padding(.horizontal, 14) }
            if request.kind != .series { playButton(item).padding(.horizontal, 14) }
            else { episodes(data) }
        }.padding(.bottom, 24)
    }
    private func meta(_ data: CinemaDetails) -> some View {
        let parts = [data.item.year.map(String.init), data.genre, data.durationSec.map { HallRecipes.minutesLabel(ms: $0 * 1000) }, data.seasons.isEmpty ? nil : "\(data.seasons.count) sezon"].compactMap { $0 }
        return HStack(spacing: 8) {
            if let rating = data.item.rating { Label(HallRecipes.rating(rating), systemImage: "star.fill").foregroundStyle(.yellow) }
            Text(parts.joined(separator: " · ")).foregroundStyle(.secondary)
            HallBadges(badges: data.item.badges)
        }.font(.caption)
    }
    private func credit(_ label: String, _ value: String) -> some View {
        (Text(label + ": ").bold() + Text(value).foregroundStyle(.secondary)).font(.caption).lineLimit(3)
    }
    private func qualities(item: CinemaItem, versions: [CinemaDetails.Version]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Kalite").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach([QualityChoice(ref: item.ref, badges: item.badges)] + versions.map { QualityChoice(ref: $0.ref, badges: $0.badges) }) { version in
                        let selected = version.ref == item.ref
                        Button { if !selected { season = nil; ref = version.ref } } label: {
                            Text(version.badges.isEmpty ? "Standart" : version.badges.joined(separator: " ")).font(.footnote.weight(.semibold))
                                .padding(.horizontal, 12).frame(minHeight: 34)
                                .background(selected ? Palette.accent.opacity(0.22) : Palette.raised, in: Capsule())
                                .foregroundStyle(selected ? Palette.accent : Color.primary)
                        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
            }
        }
    }
    private func playButton(_ item: CinemaItem) -> some View {
        let playing = hall.currentRef == item.ref
        return Button {
            Task { await hall.openItem(item); if hall.steers { hall.tab = .stage }; onDone() }
        } label: {
            Label(playing ? "Salonda açık" : hall.steers ? "Salonda oynat" : "Sıraya öner", systemImage: hall.steers ? "play.fill" : "text.badge.plus")
                .font(.headline).frame(maxWidth: .infinity, minHeight: 48)
        }.buttonStyle(.borderedProminent).disabled(playing)
    }
    @ViewBuilder private func episodes(_ data: CinemaDetails) -> some View {
        let active = data.seasons.first { $0.season == season } ?? data.seasons.first
        if let active {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(data.seasons) { value in
                        let selected = value.season == active.season
                        Button { season = value.season } label: {
                            Text("\(value.season). Sezon").font(.footnote.weight(.semibold)).padding(.horizontal, 12).frame(minHeight: 34)
                                .background(selected ? Palette.accent.opacity(0.22) : Palette.raised, in: Capsule()).foregroundStyle(selected ? Palette.accent : Color.primary)
                        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }.padding(.horizontal, 14)
            }
            if !hall.steers { HallNote(text: hall.directReason, icon: "lock").padding(.horizontal, 14) }
            LazyVStack(spacing: 10) {
                ForEach(active.episodes) { episode in
                    let playing = hall.currentRef == episode.ref
                    Button {
                        Task { await hall.openEpisode(series: data.item, episode: episode); if hall.steers { hall.tab = .stage }; onDone() }
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            HallArtView(hall: hall, art: episode.art, title: episode.title, shape: .wide).frame(width: 118, height: 66).clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(alignment: .bottomLeading) { Text("S\(episode.season) B\(episode.episode)").font(.system(size: badgeSize, weight: .bold)).padding(3).background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4)).padding(4) }
                                .overlay { Image(systemName: playing ? "speaker.wave.2.fill" : hall.steers ? "play.fill" : "text.badge.plus").foregroundStyle(.white).shadow(radius: 3) }
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(episode.episode). \(episode.title)").font(.footnote.weight(.semibold)).lineLimit(2).foregroundStyle(.primary)
                                if let duration = episode.durationSec { Text(HallRecipes.minutesLabel(ms: duration * 1000)).font(.caption2).foregroundStyle(.secondary) }
                                if let plot = episode.plot, !plot.isEmpty { Text(plot).font(.caption2).foregroundStyle(.secondary).lineLimit(2) }
                                if playing { Text("Salonda açık").font(.caption2.weight(.bold)).foregroundStyle(Palette.accent) }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.padding(8).background(playing ? Palette.accent.opacity(0.12) : Palette.surface, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain).disabled(playing)
                    .accessibilityLabel("\(episode.episode). bölüm, \(episode.title)").accessibilityHint(playing ? "Salonda açık" : hall.steers ? "Salonda oynatır" : "Sıraya önerir")
                }
            }.padding(.horizontal, 14)
        } else {
            Text("Bu dizinin bölümleri sağlayıcıda listelenmiyor.").font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 14)
        }
    }
}
private struct QualityChoice: Identifiable {
    let ref: String
    let badges: [String]
    var id: String { ref }
}
/// The details page as a sheet over the hall.
struct HallDetailsSheet: View {
    @ObservedObject var hall: HallModel
    let request: HallDetailsRequest
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            HallDetailsView(hall: hall, request: request) { dismiss() }
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Kapat") { dismiss() } } }
                .toolbarBackground(Palette.rail, for: .navigationBar)
        }
        .overlay(alignment: .top) { if let notice = hall.notice { HallToast(text: notice) } }
    }
}

// MARK: YouTube

/// YouTube in the hall (desktop `YouTubeTab`): paste a link, see what plays, and the hall's YouTube
/// queue. The service's official player plays whatever is opened.
struct HallYouTubeTab: View {
    @ObservedObject var hall: HallModel
    @ObservedObject private var titles = YouTubeTitles.shared
    @State private var text = ""
    @State private var busy = false
    @State private var error: String?
    private var videoID: String? { YouTubeLink.videoID(text) }
    var body: some View {
        let all = hall.room?.queue ?? [], currentIndex = all.firstIndex { $0.id == hall.current?.id }
        let queue = all.filter { $0.media.kind == "youtube" && $0.media.videoId != nil }
        let playing = queue.first { $0.id == hall.current?.id }
        // One pass over the whole queue instead of a `firstIndex(of:)` scan per item.
        let positions = Dictionary(all.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        let upcoming = queue.filter { item in item.id != playing?.id && (currentIndex.map { (positions[item.id] ?? 0) > $0 } ?? true) }
        let watched = queue.filter { item in currentIndex.map { (positions[item.id] ?? 0) < $0 } ?? false }
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    TextField("YouTube bağlantısını yapıştır", text: $text).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL).submitLabel(.go)
                        .onSubmit { Task { await submit() } }
                        .padding(.horizontal, 12).frame(minHeight: 44).background(Palette.raised, in: RoundedRectangle(cornerRadius: 10))
                    Button { Task { await submit() } } label: {
                        Label(hall.steers ? "Salonda aç" : "Sıraya öner", systemImage: hall.steers ? "play.fill" : "text.badge.plus").font(.footnote.weight(.semibold)).frame(minHeight: 44)
                    }.buttonStyle(.borderedProminent).disabled(text.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                }
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
                if let videoID, error == nil { feature(videoID: videoID, eyebrow: "Bulunan video", title: foundTitle(videoID), detail: hall.steers ? "Salonda aç'a bas; herkes aynı anda izler." : "Ev sahibine öneri olarak sıraya eklenir.", live: false) }
                else if let playing, let id = playing.media.videoId { feature(videoID: id, eyebrow: "Salonda oynuyor", title: titles.display(playing.media), detail: HallRecipes.did(hall.name(playing.addedBy), "ekledi"), live: true) }
                if !upcoming.isEmpty { grid("Sırada", upcoming) }
                if !watched.isEmpty { grid("İzlenenler", watched) }
                if queue.isEmpty && videoID == nil {
                    HallMessage(icon: "play.rectangle", title: "YouTube", detail: "Bir YouTube bağlantısı yapıştır; video salondaki herkes için aynı anda oynar. Üstteki büyüteçle de açabilirsin.")
                }
            }.padding(14)
        }
        .onChange(of: text) { _, _ in error = nil; if let videoID { Task { _ = await titles.lookup(videoID) } } }
        .task(id: queue.map(\.id)) { titles.want(queue.filter { YouTubeLink.placeholder($0.media.title) }.compactMap(\.media.videoId)) }
    }
    private func foundTitle(_ id: String) -> String {
        switch titles.titles[id] {
        case .title(let title)?: return title
        case .unavailable?: return "Bu video gizli ya da kaldırılmış."
        case .unknown?: return "YouTube videosu"
        case nil: return "Başlık aranıyor…"
        }
    }
    private func feature(videoID: String, eyebrow: String, title: String, detail: String, live: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            AsyncImage(url: YouTubeLink.thumbnail(videoID)) { $0.resizable().scaledToFill() } placeholder: { Palette.raised }
                .frame(width: 128, height: 72).clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) { if live { HallLiveDot() }; Text(eyebrow.uppercased(with: Locale(identifier: "tr_TR"))).font(.caption2.weight(.heavy)).foregroundStyle(live ? .red : Palette.accent) }
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(3)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
    }
    private func grid(_ title: String, _ items: [ActivityQueueItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text(title).font(.headline); Text("\(items.count)").font(.caption).foregroundStyle(.secondary) }
            if !hall.canDirect { Text(hall.directReason).font(.caption).foregroundStyle(.secondary) }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 12) {
                ForEach(items) { item in
                    Button { hall.run(.select(itemID: item.id, play: true)) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            AsyncImage(url: item.media.videoId.flatMap(YouTubeLink.thumbnail)) { $0.resizable().scaledToFill() } placeholder: { Palette.raised }
                                .aspectRatio(16 / 9, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 8))
                            Text(titles.display(item.media)).font(.caption.weight(.semibold)).lineLimit(2).foregroundStyle(.primary)
                            Text(HallRecipes.did(hall.name(item.addedBy), "ekledi")).font(.caption2).foregroundStyle(.secondary)
                        }
                    }.buttonStyle(.plain).disabled(!hall.canDirect).accessibilityHint(hall.canDirect ? "Şimdi açar" : hall.directReason)
                }
            }
        }
    }
    private func submit() async {
        guard let videoID else { error = "Bu bir YouTube bağlantısına benzemiyor."; return }
        busy = true; defer { busy = false }
        let found = await titles.lookup(videoID)
        if found == .unavailable { error = "Bu video gizli ya da kaldırılmış."; return }
        let title = switch found { case .title(let value): value; default: "YouTube videosu" }
        await hall.open(.youtube(videoID: videoID, title: title))
        text = ""
    }
}

// MARK: Aç… (search)

/// One box for channels, films, series and pasted YouTube links (desktop `OpenPalette`).
struct HallSearchSheet: View {
    @ObservedObject var hall: HallModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var results: [CinemaItem] = []
    @State private var searching = false
    @State private var error: String?
    @State private var path: [HallDetailsRequest] = []
    var body: some View {
        let videoID = YouTubeLink.videoID(text)
        NavigationStack(path: $path) {
            List {
                if let videoID {
                    Section("YouTube") {
                        Button { open(youtube: videoID) } label: {
                            HStack(spacing: 10) {
                                AsyncImage(url: YouTubeLink.thumbnail(videoID)) { $0.resizable().scaledToFill() } placeholder: { Palette.raised }.frame(width: 72, height: 40).clipShape(RoundedRectangle(cornerRadius: 6))
                                Text(hall.steers ? "YouTube videosunu salonda aç" : "YouTube videosunu sıraya öner").foregroundStyle(.primary)
                            }
                        }
                    }
                } else {
                    if let error { Text(error).font(.footnote).foregroundStyle(.secondary) }
                    if !hall.status.connected { Text("Sunucuya bağlı bir IPTV hesabı yok. YouTube bağlantısı yapıştırabilirsin.").font(.footnote).foregroundStyle(.secondary) }
                    if searching && results.isEmpty { ProgressView().frame(maxWidth: .infinity) }
                    if !searching, !text.trimmingCharacters(in: .whitespaces).isEmpty, results.isEmpty, error == nil, hall.status.connected { Text("Sonuç yok.").font(.footnote).foregroundStyle(.secondary) }
                    ForEach([CinemaKind.live, .movie, .series], id: \.self) { kind in
                        let items = results.filter { $0.kind == kind }
                        if !items.isEmpty { Section(kind == .live ? "Kanallar" : kind == .movie ? "Filmler" : "Diziler") { ForEach(items) { row($0) } } }
                    }
                }
            }
            .scrollContentBackground(.hidden).background(Palette.rail)
            .searchable(text: $text, placement: .navigationBarDrawer(displayMode: .always), prompt: "Kanal, film, dizi ya da YouTube bağlantısı")
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .navigationTitle("Salonda aç").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Kapat") { dismiss() } } }
            .navigationDestination(for: HallDetailsRequest.self) { request in HallDetailsView(hall: hall, request: request) { dismiss() } }
            .task(id: text) { await search() }
        }
        .overlay(alignment: .top) { if let notice = hall.notice { HallToast(text: notice) } }
    }
    private func row(_ item: CinemaItem) -> some View {
        let onAir = item.kind == .live ? hall.onAir(item.ref)?.title : nil
        return HStack(spacing: 10) {
            Button { choose(item) } label: {
                HStack(spacing: 10) {
                    HallArtView(hall: hall, art: item.art, title: item.title, shape: item.kind == .live ? .logo : .poster)
                        .frame(width: item.kind == .live ? 52 : 36, height: item.kind == .live ? 34 : 54).clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) { Text(item.title).foregroundStyle(.primary).lineLimit(2); HallBadges(badges: item.badges, max: 1) }
                        let meta = [item.kind == .live ? item.number.map { "\($0)" } : item.year.map(String.init), onAir].compactMap { $0 }.joined(separator: " · ")
                        if !meta.isEmpty { Text(meta).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: item.kind == .series ? "chevron.right" : hall.steers ? "play.fill" : "text.badge.plus").font(.caption).foregroundStyle(Palette.accent)
                }
            }.buttonStyle(.plain)
            if item.kind == .movie {
                Button { path.append(HallDetailsRequest(ref: item.ref, kind: item.kind)) } label: { Image(systemName: "info.circle").frame(width: 36, height: 36) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("\(item.title) ayrıntıları")
            }
        }
        .accessibilityElement(children: .contain)
        .onAppear { if item.kind == .live, item.hasGuide == true { hall.wantGuides([item.ref]) } }
    }
    private func choose(_ item: CinemaItem) {
        if item.kind == .series { path.append(HallDetailsRequest(ref: item.ref, kind: item.kind)); return }
        Task { await hall.openItem(item); if hall.steers { hall.tab = .stage }; dismiss() }
    }
    private func open(youtube id: String) {
        Task {
            let found = await YouTubeTitles.shared.lookup(id)
            if found == .unavailable { error = "Bu YouTube videosu gizli ya da kaldırılmış."; text = ""; return }
            let title = switch found { case .title(let value): value; default: "YouTube videosu" }
            await hall.open(.youtube(videoID: id, title: title))
            if hall.steers { hall.tab = .stage }
            dismiss()
        }
    }
    private func search() async {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, YouTubeLink.videoID(query) == nil, hall.status.connected else { results = []; searching = false; return }
        searching = true
        do {
            try await Task.sleep(for: .milliseconds(120))
            let found = try await hall.search(query)
            guard query == text.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
            results = found; error = nil; searching = false
        } catch is CancellationError {
        } catch { self.error = HallRecipes.errorText(error); searching = false }
    }
}
