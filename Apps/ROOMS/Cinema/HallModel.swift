import UIKit
import Combine
import ImageIO
import RoomsCore

enum HallTab: String, CaseIterable, Identifiable {
    case stage = "Salon", live = "Canlı TV", movies = "Filmler", series = "Diziler", youtube = "YouTube"
    var id: String { rawValue }
}
enum HallPanelTab: String, CaseIterable, Identifiable {
    case chat = "Sohbet", queue = "Sıra", people = "İzleyenler"
    var id: String { rawValue }
}
/// A films or series list opened from the tab's home.
struct VodRoute: Hashable {
    let category: String?
    let label: String
}
/// The details sheet for a film or a series (also reached from search).
struct HallDetailsRequest: Identifiable, Hashable {
    let ref: String
    let kind: CinemaKind
    var id: String { ref }
}

/// One open community cinema hall (desktop `useHallState` + `CinemaHall`): the hall activity, the
/// shared player, catalog caches and the commands every hall view shares.
@MainActor final class HallModel: ObservableObject, Identifiable {
    let id: String
    let communityID: String
    let api: APIClient
    let me: String
    let activity: WatchTogetherModel
    let player: HallPlayerController
    let art: CinemaArtLoader
    @Published private(set) var status: CinemaStatus
    @Published var tab = HallTab.stage
    @Published var panel = HallPanelTab.chat
    @Published var liveCategory: String?
    @Published var moviePath: [VodRoute] = []
    @Published var seriesPath: [VodRoute] = []
    @Published var details: HallDetailsRequest?
    @Published var searchOpen = false
    @Published private(set) var notice: String?
    /// Programmes by live ref, around now (desktop `guide-cache.ts`).
    @Published private(set) var guides: [String: [CinemaProgramme]] = [:]
    /// The live list on screen, so ↑/↓ on the player reaches its neighbours.
    var zapList: [CinemaItem] = []
    /// Items seen in any list, so the now bar can show a channel's number and badges.
    private(set) var known: [String: CinemaItem] = [:]
    private var isOpen = false
    private var joining = false
    private var opening: String?
    private var observers: Set<AnyCancellable> = []
    private var noticeTask: Task<Void, Never>?
    private var pendingZap: (target: CinemaItem, task: Task<Void, Never>)?
    private var categoryCache: [CinemaKind: [CinemaCategory]] = [:]
    private var pageCache: [String: CinemaItemPage] = [:]
    private var detailCache: [String: CinemaDetails] = [:]
    private var detailTasks: [String: Task<CinemaDetails, Error>] = [:]
    private var zapFallback: [CinemaItem] = []
    private var guideQueue: Set<String> = []
    private var guidePending: Set<String> = []
    private var guideFetched: [String: Date] = [:]
    private var guideFlush: Task<Void, Never>?

    init(api: APIClient, me: String, communityID: String, status: CinemaStatus, activity: WatchTogetherModel) {
        self.id = status.hallChannelId ?? activity.roomID; self.communityID = communityID; self.api = api; self.me = me; self.status = status; self.activity = activity
        player = HallPlayerController(api: api, hallID: activity.roomID, activity: activity)
        art = CinemaArtLoader(api: api, hallID: activity.roomID)
        player.onZap = { [weak self] step in self?.zap(step) }
        activity.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observers)
        activity.$room.sink { [weak self] room in self?.roomChanged(room) }.store(in: &observers)
    }

    // MARK: Session

    func open() {
        isOpen = true; activity.start(); player.start(); roomChanged(activity.room)
        // ↑/↓ on the player works before the Canlı TV tab was ever opened.
        if status.connected { Task { await loadZapFallback() } }
    }
    /// Stops the player and, unless the session is gone, gives up the seat (desktop leaves with the page).
    func close(sendLeave: Bool) {
        guard isOpen else { return }
        isOpen = false; player.stop(); pendingZap?.task.cancel(); pendingZap = nil; guideFlush?.cancel()
        if sendLeave, joined { let activity = activity; Task { try? await activity.send(.leave) } }
    }
    func update(status: CinemaStatus) {
        // A new import replaces the catalog; lists and details are read again.
        guard status != self.status else { return }
        if status.catalog.importedAt != self.status.catalog.importedAt { categoryCache = [:]; pageCache = [:]; detailCache = [:]; zapFallback = [] }
        self.status = status
    }
    /// Watching means taking a seat: join while something runs (desktop `CinemaHall` L182-194).
    private func roomChanged(_ room: ActivityRoom?) {
        guard isOpen, !joining, let room, room.primary != nil, room.participant(me) == nil else { return }
        joining = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.joining = false }
            try? await self.activity.send(.join)
        }
    }

    // MARK: State

    var room: ActivityRoom? { activity.room }
    var primary: ActivityPrimary? { room?.primary }
    var connected: Bool { activity.reachable && room != nil }
    var joined: Bool { room?.participant(me) != nil }
    var roleControl: Bool { room?.participant(me)?.canControl ?? true }
    var canDirect: Bool { HallRecipes.canDirect(room, me: me, connected: connected) }
    /// Opening now (rather than suggesting) is allowed.
    var steers: Bool { HallRecipes.opensNow(room, canDirect: canDirect) }
    var isHost: Bool { primary?.hostUserId == me }
    var canEnd: Bool { connected && (room?.ends(me) ?? false) }
    var directReason: String { HallRecipes.directReason(connected: connected, roleControl: roleControl) }
    var current: ActivityQueueItem? { HallRecipes.progress(room).current }
    var upcoming: [ActivityQueueItem] { HallRecipes.progress(room).upcoming }
    var currentRef: String? { current.flatMap { $0.media.isCommunity ? $0.media.ref : nil } }
    var viewers: [ActivityParticipant] { primary == nil ? [] : room?.participants ?? [] }
    func name(_ userID: String) -> String { userID == me ? "Sen" : room?.participant(userID)?.displayName ?? "Biri" }
    func knownItem(_ ref: String?) -> CinemaItem? { ref.flatMap { known[$0] } }

    // MARK: Commands

    func show(_ text: String) {
        notice = text; noticeTask?.cancel()
        UIAccessibility.post(notification: .announcement, argument: text)
        noticeTask = Task { [weak self] in try? await Task.sleep(for: .seconds(3)); if !Task.isCancelled { self?.notice = nil } }
    }
    func run(_ command: ActivityCommand) {
        Task { do { try await activity.send(command) } catch { show(HallRecipes.errorText(error)) } }
    }
    /// Opens for everyone, or suggests to the queue when someone else holds the remote.
    func open(_ media: ActivityMedia, label: String? = nil) async {
        let key = media.ref ?? media.videoId ?? ""
        guard opening != key else { return }
        guard room != nil else { show(activity.failure ?? "Salon hazırlanıyor. Birazdan yeniden dene."); return }
        opening = key; defer { opening = nil }
        do {
            if HallRecipes.opensNow(room, canDirect: canDirect) {
                for command in HallRecipes.openNow(room, media: media, itemID: Self.newID()) { try await activity.send(command) }
            } else {
                for command in HallRecipes.suggest(room, media: media, itemID: Self.newID()) { try await activity.send(command) }
                show("\(label ?? media.title) sıraya önerildi.")
            }
        } catch { show(HallRecipes.errorText(error)) }
    }
    func openItem(_ item: CinemaItem) async { await open(HallRecipes.media(item), label: item.title) }
    func openEpisode(series: CinemaItem, episode: CinemaEpisode) async { await open(HallRecipes.episodeMedia(series: series, episode: episode)) }
    private static func newID() -> String { UUID().uuidString.lowercased() }

    /// The player's ↑/↓: repeated steps settle before the hall switches (desktop `zap`).
    func zap(_ step: Int) {
        guard canDirect else { show("Kumanda ev sahibinde"); return }
        let list = zapList.isEmpty ? zapFallback : zapList
        guard let target = HallRecipes.neighbour(list, ref: pendingZap?.target.ref ?? currentRef, step: step) else {
            show("Kanal listesi yükleniyor…"); Task { await loadZapFallback() }; return
        }
        let onAir = HallRecipes.programme(at: Date().timeIntervalSince1970 * 1000, in: guides[target.ref])?.title
        show([target.number.map(String.init), target.title, onAir].compactMap { $0 }.joined(separator: " · "))
        pendingZap?.task.cancel()
        pendingZap = (target, Task { [weak self] in
            try? await Task.sleep(for: HallRecipes.zapDelay)
            guard !Task.isCancelled, let self else { return }
            self.pendingZap = nil
            await self.openItem(target)
        })
    }
    private func loadZapFallback() async {
        guard zapFallback.isEmpty, let page = try? await items(.live, category: nil, limit: 200) else { return }
        zapFallback = page.items
    }

    // MARK: Catalog

    private func remember(_ items: [CinemaItem]) { for item in items { known[item.ref] = item } }
    func categories(_ kind: CinemaKind) async throws -> [CinemaCategory] {
        if let cached = categoryCache[kind] { return cached }
        let value = try await api.cinemaCategories(hall: id, kind: kind)
        categoryCache[kind] = value; return value
    }
    func items(_ kind: CinemaKind, category: String?, sort: CinemaSort = .standard, offset: Int = 0, limit: Int) async throws -> CinemaItemPage {
        let key = "\(kind.rawValue):\(category ?? "*"):\(sort.rawValue):\(offset):\(limit)"
        if let cached = pageCache[key] { return cached }
        let page = try await api.cinemaItems(hall: id, kind: kind, category: category, sort: sort, offset: offset, limit: limit)
        remember(page.items); pageCache[key] = page; return page
    }
    func cachedDetails(_ ref: String) -> CinemaDetails? { detailCache[ref] }
    func details(_ ref: String) async throws -> CinemaDetails {
        if let cached = detailCache[ref] { return cached }
        if let task = detailTasks[ref] { return try await task.value }
        let api = api, hall = id
        let task = Task { try await api.cinemaDetails(hall: hall, ref: ref) }
        detailTasks[ref] = task
        defer { detailTasks[ref] = nil }
        let value = try await task.value
        remember([value.item]); detailCache[ref] = value; return value
    }
    func search(_ text: String) async throws -> [CinemaItem] {
        let result = try await api.cinemaSearch(hall: id, query: text)
        remember(result); return result
    }

    // MARK: Guide

    /// Asks for the programmes of live refs that are missing or older than ten minutes; requests
    /// arriving together are sent in batches of 40, around now (−3 h … +26 h).
    func wantGuides(_ refs: [String]) {
        let now = Date()
        let missing = refs.filter { ref in CinemaRef.valid(ref) && !guidePending.contains(ref) && (guideFetched[ref].map { now.timeIntervalSince($0) > 600 } ?? true) }
        guard !missing.isEmpty, isOpen else { return }
        guideQueue.formUnion(missing); guidePending.formUnion(missing)
        guard guideFlush == nil else { return }
        guideFlush = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, !Task.isCancelled else { return }
            await self.flushGuides()
        }
    }
    private func flushGuides() async {
        let refs = Array(guideQueue); guideQueue = []; guideFlush = nil
        let now = Date().timeIntervalSince1970 * 1000
        for start in stride(from: 0, to: refs.count, by: 40) {
            let batch = Array(refs[start..<min(start + 40, refs.count)])
            var found: [String: [CinemaProgramme]] = [:]
            do {
                let result = try await api.cinemaGuide(hall: id, refs: batch, from: now - 3 * 3_600_000, to: now + 26 * 3_600_000)
                for ref in batch { found[ref] = (result[ref] ?? []).sorted { $0.start < $1.start } }
            } catch {
                // A missing guide shows nothing; a stale one stays.
                for ref in batch where guides[ref] == nil { found[ref] = [] }
            }
            guides.merge(found) { $1 }
            for ref in batch { guideFetched[ref] = Date(); guidePending.remove(ref) }
        }
    }
    func onAir(_ ref: String?, now: Double = Date().timeIntervalSince1970 * 1000) -> CinemaProgramme? { ref.flatMap { HallRecipes.programme(at: now, in: guides[$0]) } }
    func upNext(_ ref: String?, now: Double = Date().timeIntervalSince1970 * 1000) -> CinemaProgramme? { ref.flatMap { HallRecipes.programme(after: now, in: guides[$0]) } }
}

/// Hall artwork through the cinema service: the request carries the session token, so image views
/// cannot load the URL themselves (desktop `CinemaArt` through `rooms-cinema:`).
@MainActor final class CinemaArtLoader {
    private let api: APIClient
    private let hallID: String
    private let cache = NSCache<NSString, UIImage>()
    private var missing: Set<String> = []
    init(api: APIClient, hallID: String) { self.api = api; self.hallID = hallID; cache.totalCostLimit = 48_000_000 }
    func cached(_ art: String?, pixels: Int) -> UIImage? { art.flatMap { cache.object(forKey: "\($0)@\(pixels)" as NSString) } }
    func image(_ art: String?, pixels: Int) async -> UIImage? {
        guard let art, CinemaRef.validArt(art), !missing.contains(art) else { return nil }
        if let image = cached(art, pixels: pixels) { return image }
        do {
            let data = try await api.cinemaArt(hall: hallID, art: art)
            let image = await Task.detached(priority: .utility) { Self.decode(data, pixels: pixels) }.value
            if let image { cache.setObject(image, forKey: "\(art)@\(pixels)" as NSString, cost: image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0) } else { missing.insert(art) }
            return image
        } catch {
            if (error as? CinemaError)?.code == "CINEMA_ITEM_NOT_FOUND" { missing.insert(art) }
            return nil
        }
    }
    nonisolated private static func decode(_ data: Data, pixels: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: pixels, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}

/// Public YouTube titles by video id, looked up once per session (desktop `rooms:youtube-details`).
@MainActor final class YouTubeTitles: ObservableObject {
    static let shared = YouTubeTitles()
    @Published private(set) var titles: [String: YouTubeTitle] = [:]
    private var pending: Set<String> = []
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest = 6; config.timeoutIntervalForResource = 8
        return URLSession(configuration: config, delegate: RefuseRedirects(), delegateQueue: nil)
    }()
    func lookup(_ id: String) async -> YouTubeTitle {
        if let known = titles[id], known != .unknown { return known }
        guard let url = YouTubeLink.oEmbedURL(id) else { return .unknown }
        var request = URLRequest(url: url); request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let answer = try? await session.data(for: request), let http = answer.1 as? HTTPURLResponse, answer.0.count <= 65_536 else { return .unknown }
        let result = YouTubeLink.oEmbedTitle(status: http.statusCode, data: answer.0)
        titles[id] = result; return result
    }
    /// Real titles for queue items that were added without one, looked up one at a time.
    func want(_ ids: [String]) {
        let missing = ids.filter { titles[$0] == nil && !pending.contains($0) }.prefix(60)
        guard !missing.isEmpty else { return }
        pending.formUnion(missing)
        Task { for id in missing { _ = await lookup(id); pending.remove(id) } }
    }
    func display(_ media: ActivityMedia) -> String {
        guard media.kind == "youtube", YouTubeLink.placeholder(media.title), let id = media.videoId, case .title(let title)? = titles[id] else { return media.title }
        return title
    }
}
private final class RefuseRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}
