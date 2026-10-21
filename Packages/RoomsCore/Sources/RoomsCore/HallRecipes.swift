import Foundation

/// The community cinema hall's command recipes and labels (desktop `cinema/hall-model.ts`, `use-hall.ts`).
public enum HallRecipes {
    public static let title = "Sinema salonu"
    /// The activities service refuses `queue.add` past this many items.
    public static let queueLimit = 100
    /// Repeated channel steps settle this long before the hall switches (desktop `ARROW_ZAP_MS`).
    public static let zapDelay: Duration = .milliseconds(550)
    /// Items added within this many days carry the "Yeni" badge.
    public static let newDays: Double = 14

    // MARK: Queue

    /// The playing item and what follows it; nothing plays unless the hall activity runs.
    public static func progress(_ room: ActivityRoom?) -> (current: ActivityQueueItem?, upcoming: [ActivityQueueItem]) {
        guard let room, room.primary?.activity == "hall" else { return (nil, []) }
        guard let index = room.queue.firstIndex(where: { $0.id == room.timeline.itemId }) else { return (nil, room.queue) }
        return (room.queue[index], Array(room.queue[(index + 1)...]))
    }
    /// Items before the playing one were already watched in this session.
    public static func watched(_ room: ActivityRoom?) -> [ActivityQueueItem] {
        guard let room, room.primary?.activity == "hall", let index = room.queue.firstIndex(where: { $0.id == room.timeline.itemId }) else { return [] }
        return Array(room.queue[..<index])
    }

    /// The queue entry for a catalog item; titles keep the protocol's 240 characters.
    public static func media(_ item: CinemaItem) -> ActivityMedia {
        let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return .community(ref: item.ref, title: String((title.isEmpty ? "Adsız" : title).prefix(240)), live: item.kind == .live,
                          art: item.art.flatMap { CinemaRef.validArt($0) ? $0 : nil })
    }
    /// `Dizi · 2. Sezon 5. Bölüm`.
    public static func episodeTitle(series: String, season: Int, episode: Int) -> String {
        String("\(series) · \(season). Sezon \(episode). Bölüm".prefix(240))
    }
    public static func episodeMedia(series: CinemaItem, episode: CinemaEpisode) -> ActivityMedia {
        .community(ref: episode.ref, title: episodeTitle(series: series.title, season: episode.season, episode: episode.episode), live: false,
                   art: episode.art.flatMap { CinemaRef.validArt($0) ? $0 : nil })
    }
    /// The same catalog item or the same video.
    public static func same(_ a: ActivityMedia, _ b: ActivityMedia) -> Bool {
        guard a.kind == b.kind else { return false }
        switch a.kind {
        case "community-media": return a.ref != nil && a.ref == b.ref
        case "youtube": return a.videoId != nil && a.videoId == b.videoId
        default: return false
        }
    }

    /// Commands that open `media` for everyone now. A live channel replaces the previous live
    /// channel instead of piling up in the queue, so zapping never fills it; a full queue drops
    /// its oldest watched items first.
    public static func openNow(_ room: ActivityRoom?, media: ActivityMedia, itemID: String) -> [ActivityCommand] {
        var commands: [ActivityCommand] = []
        let running = room?.primary != nil
        if !running { commands.append(.start(activity: "hall", title: title)) }
        let existing = running ? room?.queue.first { same($0.media, media) } : nil
        let current = progress(room).current
        if let existing {
            if existing.id != current?.id { commands.append(.select(itemID: existing.id, play: true)) }
        } else {
            let queue = running ? room?.queue ?? [] : []
            let watched = queue.prefix(max(0, queue.firstIndex { $0.id == current?.id } ?? 0))
            for item in watched.prefix(max(0, queue.count - (queueLimit - 1))) { commands.append(.remove(itemID: item.id)) }
            commands.append(.addMedia(itemID: itemID, media: media, start: true))
        }
        if running, let current, current.media.isLive, current.id != existing?.id { commands.append(.remove(itemID: current.id)) }
        return commands
    }
    /// Without the remote: start the hall if nothing runs, then only add to the queue.
    public static func suggest(_ room: ActivityRoom?, media: ActivityMedia, itemID: String) -> [ActivityCommand] {
        (room?.primary == nil ? [.start(activity: "hall", title: title)] : []) + [.addMedia(itemID: itemID, media: media, start: false)]
    }
    /// Whoever steers opens now; anyone may open the first thing in an idle hall. Others suggest.
    public static func opensNow(_ room: ActivityRoom?, canDirect: Bool) -> Bool { canDirect || room?.primary == nil }
    /// Steering needs a reachable hall, the role permission and, in host mode, the host's remote.
    public static func canDirect(_ room: ActivityRoom?, me: String?, connected: Bool) -> Bool { connected && (room?.directs(me) ?? false) }
    /// Why a member cannot steer (desktop `directReason`).
    public static func directReason(connected: Bool, roleControl: Bool) -> String {
        !connected ? "Salon hizmeti bağlı değil." : !roleControl ? "Bu salonda oynatmayı yönetme iznin yok." : "Kumanda ev sahibinde. Sıraya öneri ekleyebilirsin."
    }
    /// A reorder that keeps the playing item where it is (the service refuses anything else).
    public static func reorder(_ queue: [ActivityQueueItem], current: String?, from source: IndexSet, to destination: Int) -> [String]? {
        var ids = queue.map(\.id)
        guard !source.isEmpty, source.allSatisfy({ $0 < ids.count }), (0...ids.count).contains(destination) else { return nil }
        // Same semantics as SwiftUI's `move(fromOffsets:toOffset:)`.
        let moving = source.map { ids[$0] }, before = source.filter { $0 < destination }.count
        for index in source.reversed() { ids.remove(at: index) }
        ids.insert(contentsOf: moving, at: destination - before)
        guard ids != queue.map(\.id) else { return nil }
        if let current, ids.firstIndex(of: current) != queue.firstIndex(where: { $0.id == current }) { return nil }
        return ids
    }
    /// The step-th neighbour of `ref` in `list`, wrapping around (desktop `neighbour`).
    public static func neighbour(_ list: [CinemaItem], ref: String?, step: Int) -> CinemaItem? {
        guard !list.isEmpty else { return nil }
        guard let ref, let index = list.firstIndex(where: { $0.ref == ref }) else { return step > 0 ? list.first : list.last }
        return list[((index + step) % list.count + list.count) % list.count]
    }

    // MARK: Guide

    public static func programme(at now: Double, in list: [CinemaProgramme]?) -> CinemaProgramme? { list?.first { $0.start <= now && $0.stop > now } }
    public static func programme(after now: Double, in list: [CinemaProgramme]?) -> CinemaProgramme? { list?.first { $0.start > now } }
    public static func share(of programme: CinemaProgramme?, now: Double) -> Double {
        guard let programme, programme.stop > programme.start else { return 0 }
        return min(1, max(0, (now - programme.start) / (programme.stop - programme.start)))
    }

    // MARK: Labels

    /// `45 dk`, `1 sa 50 dk`, `2 sa`.
    public static func minutesLabel(ms: Double) -> String {
        let total = max(1, Int((ms / 60_000).rounded())), hours = total / 60, minutes = total % 60
        if hours == 0 { return "\(minutes) dk" }
        return minutes == 0 ? "\(hours) sa" : "\(hours) sa \(minutes) dk"
    }
    /// `20:30` in the Turkish clock style.
    public static func clock(ms: Double, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "tr_TR"); formatter.timeZone = timeZone; formatter.dateFormat = "HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: ms / 1000))
    }
    public static func timeRange(_ programme: CinemaProgramme, timeZone: TimeZone = .current) -> String {
        "\(clock(ms: programme.start, timeZone: timeZone))–\(clock(ms: programme.stop, timeZone: timeZone))"
    }
    public static func viewerLabel(_ count: Int) -> String { "\(count) kişi izliyor" }
    /// `Ece açtı`, but `Sen açtın` (the verb agrees with the person).
    public static func did(_ name: String, _ verb: String) -> String { name == "Sen" ? "Sen \(verb)n" : "\(name) \(verb)" }
    public static func isNew(addedAt: Double?, now: Double) -> Bool {
        guard let addedAt else { return false }
        return now - addedAt < newDays * 86_400_000
    }
    /// The lettered tile shown without artwork: quality words dropped, up to `count` initials.
    public static func initials(_ title: String, count: Int) -> String {
        let words = title.split(whereSeparator: \.isWhitespace).filter { !["HD", "FHD", "UHD", "4K", "TV"].contains($0.uppercased()) }
        return String(words.compactMap(\.first).prefix(count)).uppercased(with: Locale(identifier: "tr_TR"))
    }
    /// Every whitespace-separated term appears in the title, compared in Turkish lowercase.
    public static func matches(_ title: String, filter: String) -> Bool {
        let locale = Locale(identifier: "tr_TR"), name = title.lowercased(with: locale)
        return filter.lowercased(with: locale).split(whereSeparator: \.isWhitespace).allSatisfy { name.contains($0) }
    }
    public static func rating(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0...1)).locale(Locale(identifier: "tr_TR"))) }
    /// Hall wording for a refusal (desktop `cinemaErrorText`).
    public static func errorText(_ error: Error) -> String {
        if let error = error as? CinemaError { return error.localizedDescription }
        if let error = error as? ActivityError {
            switch error.code {
            case "LIVE_PLAYBACK_FIXED": return "Canlı yayın herkes için aynı anda akar; sarılamaz."
            case "SESSION_HOST_CONTROL": return "Kumanda ev sahibinde."
            case "ACTIVITY_CONTROL_DENIED": return "Bu salonda oynatmayı yönetme iznin yok."
            case "QUEUE_FULL": return "Sıra dolu. Önce birkaç öğeyi kaldır."
            default: return error.localizedDescription
            }
        }
        if let error = error as? RoomsError { return error.localizedDescription }
        return "Bir şeyler ters gitti. Yeniden dene."
    }
}

/// A YouTube video's public title from oEmbed (desktop `rooms:youtube-details`).
public enum YouTubeTitle: Equatable, Sendable {
    case title(String)
    /// Private or removed.
    case unavailable
    /// No answer, or embedding is off; the shared player may still try.
    case unknown
}
extension YouTubeLink {
    /// Queue names given to videos added without a title.
    public static func placeholder(_ title: String) -> Bool { title.range(of: "^YouTube(?: videosu| · [A-Za-z0-9_-]+)?$", options: .regularExpression) != nil }
    public static func oEmbedURL(_ id: String) -> URL? {
        // Encoded like the desktop's URLSearchParams; the id is already [A-Za-z0-9_-].
        guard valid(id) else { return nil }
        return URL(string: "https://www.youtube.com/oembed?url=https%3A%2F%2Fwww.youtube.com%2Fwatch%3Fv%3D\(id)&format=json")
    }
    public static func oEmbedTitle(status: Int, data: Data) -> YouTubeTitle {
        switch status {
        case 200:
            guard let title = (try? JSONDecoder().decode(JSONValue.self, from: data))?["title"].string?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return .unknown }
            return .title(String(title.prefix(240)))
        case 404: return .unavailable
        default: return .unknown
        }
    }
}
