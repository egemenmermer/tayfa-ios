import Foundation

// Shared room activities (desktop "Birlikte izle"), protocol version 1 of the Activities service.

public struct ActivityParticipant: Codable, Equatable, Sendable, Identifiable {
    public let userId: String
    public let displayName: String
    public let joinedAt: Double?
    public let canControl: Bool
    public let canCreate: Bool?
    public var id: String { userId }
}
public struct ActivityPrimary: Codable, Equatable, Sendable {
    /// `youtube`, `cinema`, `hall` (the community cinema), `screen` or a game table; unknown kinds are shown but not played.
    public let activity: String
    public let title: String
    public let hostUserId: String
    public let startedAt: Double?
    public let controlMode: String?
    public let controllers: [String]?
    public var sharedPlayer: Bool { ["youtube", "cinema", "hall", "screen"].contains(activity) }
    /// The host's "only me and invited people steer" setting (`session.control`).
    public var hostOnly: Bool { controlMode == "host" }
    /// A Kıraathane table (`holdem`, `blackjack`, `batak`, `101`); its state is `ActivityRoom.game`.
    public var isGame: Bool { ["holdem", "blackjack", "batak", "101"].contains(activity) }
}
public struct ActivityTimeline: Codable, Equatable, Sendable {
    public let playing: Bool
    public let positionSec: Double
    public let rate: Double
    public let effectiveServerTimeMs: Double
    public let epoch: Int
    public let itemId: String?
}
/// A queue item's media: `youtube`, `independent-source` (own-file cinema) or `community-media` (a hall catalog item).
public struct ActivityMedia: Codable, Equatable, Sendable {
    public let kind: String
    public let videoId: String?
    public let title: String
    /// `community-media`: the opaque catalog ref (`l-`, `m-`, `s-`, `e-`), whether it is a live channel and its artwork id.
    public let ref: String?
    public let live: Bool?
    public let art: String?
    public let referenceId: String?
    public init(kind: String, videoId: String? = nil, title: String, ref: String? = nil, live: Bool? = nil, art: String? = nil, referenceId: String? = nil) {
        self.kind = kind; self.videoId = videoId; self.title = title; self.ref = ref; self.live = live; self.art = art; self.referenceId = referenceId
    }
    public static func youtube(videoID: String, title: String) -> ActivityMedia { ActivityMedia(kind: "youtube", videoId: videoID, title: title) }
    public static func community(ref: String, title: String, live: Bool, art: String?) -> ActivityMedia {
        ActivityMedia(kind: "community-media", title: title, ref: ref, live: live, art: art)
    }
    public var isCommunity: Bool { kind == "community-media" }
    public var isLive: Bool { isCommunity && live == true }
    /// The protocol's strict shape for `queue.add` (unknown kinds are never sent).
    public var json: JSONValue {
        let name = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(240))
        switch kind {
        case "community-media":
            var value: [String: JSONValue] = ["kind": .string(kind), "ref": .string(ref ?? ""), "title": .string(name.isEmpty ? "Sinema" : name), "live": .bool(live ?? false)]
            if let art, art.range(of: "^[a-f0-9]{16,64}$", options: .regularExpression) != nil { value["art"] = .string(art) }
            return .object(value)
        default:
            return .object(["kind": .string("youtube"), "videoId": .string(videoId ?? ""), "title": .string(name.isEmpty ? "YouTube videosu" : name)])
        }
    }
}
/// One whiteboard element on the shared 0–4096 canvas; only its author may change or remove it.
public struct WhiteboardElement: Codable, Equatable, Sendable, Identifiable {
    public struct Point: Codable, Equatable, Sendable {
        public let x: Double
        public let y: Double
        public init(x: Double, y: Double) { self.x = x; self.y = y }
        /// The protocol sends `[x, y]` pairs.
        public init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            x = try c.decode(Double.self); y = try c.decode(Double.self)
        }
        public func encode(to encoder: Encoder) throws { var c = encoder.unkeyedContainer(); try c.encode(x); try c.encode(y) }
    }
    public let id: String
    /// `stroke`, `text`, `rectangle` or `ellipse`.
    public let kind: String
    public let points: [Point]
    public let text: String?
    /// `#rrggbb`.
    public let color: String
    public let width: Double
    public let authorId: String?
    public init(id: String, kind: String, points: [Point], text: String? = nil, color: String, width: Double, authorId: String? = nil) {
        self.id = id; self.kind = kind; self.points = points; self.text = text; self.color = color; self.width = width; self.authorId = authorId
    }
    /// The `whiteboard.put` element, clamped to the protocol's limits (author is set by the service).
    public var json: JSONValue {
        let clamp = { (value: Double) in min(4096, max(0, value.isFinite ? value : 0)) }
        var value: [String: JSONValue] = [
            "id": .string(id), "kind": .string(kind), "color": .string(color), "width": .number(min(24, max(1, width))),
            "points": .array(points.prefix(500).map { .array([.number(clamp($0.x)), .number(clamp($0.y))]) }),
        ]
        if let text { value["text"] = .string(String(text.prefix(2000))) }
        return .object(value)
    }
}
public struct ActivityQueueItem: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let media: ActivityMedia
    public let addedBy: String
}
public struct ActivityPoll: Codable, Equatable, Sendable, Identifiable {
    public struct Option: Codable, Equatable, Sendable, Identifiable { public let id: String; public let label: String }
    public let id: String
    public let question: String
    public let options: [Option]
    /// Voter id → option id; one vote per person, changeable until the poll closes.
    public let votes: [String: String]
    public let createdBy: String
    public let closed: Bool
    public func count(_ optionID: String) -> Int { votes.values.filter { $0 == optionID }.count }
}
public struct ActivityRoom: Codable, Equatable, Sendable {
    public let roomId: String
    public let revision: Int
    public let participants: [ActivityParticipant]
    public let primary: ActivityPrimary?
    public let timeline: ActivityTimeline
    public let queue: [ActivityQueueItem]
    public let polls: [ActivityPoll]?
    public let whiteboard: [WhiteboardElement]?
    /// The room's game table as projected for this viewer (see `Games.swift`); nil without a table or if it cannot be read.
    public let game: GameState?
    /// The creator or anyone with room control may close a poll (as the service checks).
    public func closes(_ poll: ActivityPoll, _ userID: String?) -> Bool {
        poll.createdBy == userID || (participant(userID)?.canControl ?? true)
    }

    public var currentIndex: Int? { queue.firstIndex { $0.id == timeline.itemId } }
    public var current: ActivityQueueItem? { currentIndex.map { queue[$0] } }
    public var next: ActivityQueueItem? { currentIndex.flatMap { $0 + 1 < queue.count ? queue[$0 + 1] : nil } }
    public func participant(_ userID: String?) -> ActivityParticipant? { participants.first { $0.userId == userID } }

    /// Role permission plus the host's "only me and invited people steer" setting (desktop `directsSession`).
    public func directs(_ userID: String?) -> Bool {
        guard let userID, participant(userID)?.canControl ?? true else { return false }
        guard let primary, primary.controlMode == "host" else { return true }
        return primary.hostUserId == userID || (primary.controllers ?? []).contains(userID)
    }
    /// Ending a shared player for everyone is the host's call (desktop `endsActivity`).
    public func ends(_ userID: String?) -> Bool {
        guard let userID, participant(userID)?.canControl ?? true else { return false }
        guard let primary, primary.sharedPlayer else { return true }
        return primary.hostUserId == userID
    }
    public func canStart(_ userID: String?) -> Bool { participant(userID)?.canCreate ?? true }
}
extension ActivityRoom {
    /// A table this build cannot read never hides the rest of the room (queue, polls, whiteboard).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        roomId = try c.decode(String.self, forKey: .roomId)
        revision = try c.decode(Int.self, forKey: .revision)
        participants = try c.decode([ActivityParticipant].self, forKey: .participants)
        primary = try c.decodeIfPresent(ActivityPrimary.self, forKey: .primary)
        timeline = try c.decode(ActivityTimeline.self, forKey: .timeline)
        queue = try c.decode([ActivityQueueItem].self, forKey: .queue)
        polls = try c.decodeIfPresent([ActivityPoll].self, forKey: .polls)
        whiteboard = try c.decodeIfPresent([WhiteboardElement].self, forKey: .whiteboard)
        game = (try? c.decodeIfPresent(GameState.self, forKey: .game)) ?? nil
    }
}
public struct ActivityResponse: Codable, Sendable {
    public let protocolVersion: Int
    public let serverTimeMs: Double
    public let room: ActivityRoom
}

public enum ActivityCommand: Equatable, Sendable {
    case join, leave, end
    case startYouTube(title: String)
    case add(itemID: String, videoID: String, title: String, start: Bool)
    case select(itemID: String, play: Bool)
    case next(fromItemID: String, skip: Bool)
    case playback(playing: Bool, positionSec: Double)
    case remove(itemID: String)
    case pollCreate(pollID: String, question: String, options: [String])
    case pollVote(pollID: String, optionID: String)
    case pollClose(pollID: String)
    /// Any primary activity, e.g. `hall` with "Sinema salonu".
    case start(activity: String, title: String)
    /// `queue.add` for any media kind (`youtube` or `community-media`).
    case addMedia(itemID: String, media: ActivityMedia, start: Bool)
    /// Removes every queue item except the one playing (remote holder).
    case clear
    /// A full permutation of the queue's item ids (remote holder).
    case reorder(itemIDs: [String])
    /// Host only: `true` lets only the host and invited people steer.
    case sessionControl(hostOnly: Bool)
    case sessionPermit(userID: String, allowed: Bool)
    case sessionHost(userID: String)
    case whiteboardPut(WhiteboardElement)
    case whiteboardRemove(elementID: String)
    /// `game.create`, `game.sit`, `game.action` and the other table commands.
    case game(GameCommand)

    public var json: JSONValue {
        switch self {
        case .game(let command): return command.json
        case .join: return .object(["type": .string("join")])
        case .leave: return .object(["type": .string("leave")])
        case .end: return .object(["type": .string("end")])
        case .startYouTube(let title):
            return .object(["type": .string("start"), "activity": .string("youtube"), "title": .string(Self.text(title, fallback: "Birlikte izle"))])
        case .start(let activity, let title):
            return .object(["type": .string("start"), "activity": .string(activity), "title": .string(Self.text(title, fallback: "Birlikte izle"))])
        case .addMedia(let itemID, let media, let start):
            return .object(["type": .string("queue.add"), "itemId": .string(itemID), "start": .bool(start), "media": media.json])
        case .clear: return .object(["type": .string("queue.clear")])
        case .reorder(let ids): return .object(["type": .string("queue.reorder"), "itemIds": .array(ids.prefix(100).map(JSONValue.string))])
        case .sessionControl(let hostOnly): return .object(["type": .string("session.control"), "mode": .string(hostOnly ? "host" : "everyone")])
        case .sessionPermit(let userID, let allowed): return .object(["type": .string("session.permit"), "userId": .string(userID), "allowed": .bool(allowed)])
        case .sessionHost(let userID): return .object(["type": .string("session.host"), "userId": .string(userID)])
        case .whiteboardPut(let element): return .object(["type": .string("whiteboard.put"), "element": element.json])
        case .whiteboardRemove(let id): return .object(["type": .string("whiteboard.remove"), "elementId": .string(id)])
        case .add(let itemID, let videoID, let title, let start):
            return .object(["type": .string("queue.add"), "itemId": .string(itemID), "start": .bool(start),
                            "media": .object(["kind": .string("youtube"), "videoId": .string(videoID), "title": .string(Self.text(title, fallback: "YouTube videosu"))])])
        case .select(let itemID, let play): return .object(["type": .string("queue.select"), "itemId": .string(itemID), "play": .bool(play)])
        case .next(let from, let skip): return .object(["type": .string("queue.next"), "fromItemId": .string(from), "reason": .string(skip ? "skip" : "ended")])
        case .playback(let playing, let position):
            return .object(["type": .string("playback"), "playing": .bool(playing), "positionSec": .number(min(86400, max(0, position.isFinite ? position : 0))), "rate": .number(1)])
        case .remove(let itemID): return .object(["type": .string("queue.remove"), "itemId": .string(itemID)])
        case .pollCreate(let pollID, let question, let options):
            let labels = options.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.prefix(12)
            return .object(["type": .string("poll.create"), "pollId": .string(pollID), "question": .string(Self.text(question, fallback: "Anket")),
                            "options": .array(labels.enumerated().map { index, label in .object(["id": .string("o\(index + 1)"), "label": .string(String(label.prefix(240)))]) })])
        case .pollVote(let pollID, let optionID): return .object(["type": .string("poll.vote"), "pollId": .string(pollID), "optionId": .string(optionID)])
        case .pollClose(let pollID): return .object(["type": .string("poll.close"), "pollId": .string(pollID)])
        }
    }
    public static func envelope(_ command: ActivityCommand, commandID: UUID, expectedRevision: Int) -> JSONValue {
        .object(["protocolVersion": .number(1), "commandId": .string(commandID.uuidString.lowercased()),
                 "expectedRevision": .number(Double(max(0, expectedRevision))), "command": command.json])
    }
    private static func text(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return String((trimmed.isEmpty ? fallback : trimmed).prefix(240))
    }
}

/// A rejected activity command, with the desktop's Turkish text for its public code.
public struct ActivityError: Error, LocalizedError, Equatable, Sendable {
    public let code: String
    public init(code: String) { self.code = code }
    public var errorDescription: String? {
        switch code {
        case "PRIMARY_ACTIVITY_ACTIVE": "Odada başka bir etkinlik açık. Önce mevcut etkinliği bitirin."
        case "JOIN_ACTIVITY_FIRST": "Bu işlem için önce ortak etkinliğe katıl."
        case "ACTIVITY_CONTROL_DENIED": "Bu odada etkinliği yönetme iznin yok."
        case "ACTIVITY_CREATE_DENIED": "Bu odada etkinlik başlatma iznin yok."
        case "SHARED_PLAYER_REQUIRED": "Önce ortak Sinema veya YouTube etkinliğini başlat."
        case "MEDIA_SOURCE_REQUIRED": "Önce ortak sıradan bir medya seç."
        case "ROOM_FULL": "Bu oda dolu. Bir katılımcı ayrıldıktan sonra yeniden dene."
        case "QUEUE_FULL": "Ortak sıra dolu. Yeni içerik eklemek için bir öğeyi kaldır."
        case "QUEUE_ITEM_NOT_FOUND": "Bu öğe artık sırada değil. Güncel sıradan yeniden seç."
        case "QUEUE_END": "Sırada başka video yok."
        case "QUEUE_ACTIVE_ITEM_FIXED": "Şu an oynayan öğe kaldırılamaz veya taşınamaz."
        case "MEDIA_KIND_MISMATCH": "Bu içerik açık olan oturuma eklenemez. Önce oturumu değiştir."
        case "LIVE_PLAYBACK_FIXED": "Canlı yayın herkes için aynı anda akar; sarılamaz."
        case "WHITEBOARD_AUTHOR_REQUIRED": "Yalnızca kendi çizimini veya notunu değiştirebilirsin."
        case "WHITEBOARD_FULL": "Beyaz tahta dolu. Yeni çizim için eski çizimlerden birini sil."
        case "WHITEBOARD_ELEMENT_NOT_FOUND": "Bu öğe tahtada artık yok."
        case "SESSION_PARTICIPANT_NOT_FOUND": "Bu kişi şu an sinemada değil."
        case "SESSION_HOST_TARGET_DENIED": "Bu kişinin odada etkinlik yönetme izni yok; host yapılamaz."
        case "SESSION_HOST_ALREADY": "Bu kişi zaten oturumun hostu."
        case "SESSION_HOST_CONTROL": "Kumanda hostta. Oynatmayı host ve izin verdiği kişiler yönetiyor; sıraya öneri ekleyebilirsin."
        case "SESSION_HOST_REQUIRED": "Bunu yalnızca oturumun hostu yapabilir."
        case "REVISION_CONFLICT": "Oda bu sırada değişti. Yeniden dene."
        case "POLL_CLOSED": "Bu anket kapandı. Artık oy değiştirilemez."
        case "POLL_CONTROL_DENIED": "Anketi kapatma iznin yok."
        case "POLL_LIMIT": "Bu odada çok fazla anket var."
        // Game tables (desktop `i18n.ts` text).
        case "TABLE_OWNER_REQUIRED": "Bu işlemi yalnızca masa sahibi yapabilir."
        case "NOT_YOUR_TURN": "Şu anda sıra sende değil. Masa güncellendiğinde yeniden dene."
        case "MORE_SEATS_REQUIRED": "Bu oyunu başlatmak için daha fazla oyuncu veya bot gerekiyor."
        case "SEAT_UNAVAILABLE": "Bu koltuk artık uygun değil. Başka bir koltuk seç."
        case "TAKE_A_SEAT_FIRST": "Önce masada boş bir koltuğa otur."
        case "GAME_TABLE_REQUIRED": "Bu masanın etkinliği sona erdi. Yeni bir masa kur."
        case "HAND_FINISHED": "Bu el tamamlandı. Masa sahibi yeni eli başlatabilir."
        case "HAND_ALREADY_PLAYING": "Bir el zaten devam ediyor. Tamamlanmasını bekle."
        case "CHECK_UNAVAILABLE": "Karşılanmamış bahis var. Gör, artır veya eli bırak."
        case "INVALID_RAISE": "Artırma miktarı geçersiz. Mevcut bahis ile puanın arasındaki bir miktarı seç."
        case "RAISE_TOO_SMALL": "Artırma, masanın en düşük artırma miktarından küçük olamaz."
        case "BETTING_NOT_REOPENED": "Bu turda yeniden artırma hakkın yok."
        case "INVALID_VIRTUAL_BET": "En az 2 ve puanını aşmayan çift bir sanal bahis miktarı gir."
        case "DRAW_REQUIRED": "Önce bir taş çek."
        case "TILE_NOT_IN_HAND": "Seçilen taş elinde değil. Güncel elinden yeniden seç."
        case "KEEP_ONE_DISCARD_TILE": "Elini açarken atmak için bir taş bırakmalısın."
        case "PICKED_DISCARD_MUST_BE_USED": "Yerden aldığın taşı açarken veya işlerken kullanmalısın. Vazgeçmek için desteden taş çek."
        case "DISCARD_EMPTY": "Önceki oyuncunun alabileceğin bir taşı yok."
        case "OPENING_MODE_LOCKED": "Bu eldeki açılış türün zaten belirlendi. Aynı türle devam et."
        case "OPEN_AND_SELECT_MELD_FIRST": "İşlemek için önce elini aç ve masadan bir seri seç."
        case "PAIR_CANNOT_EXTEND": "Çift grubu uzatılamaz. İşlemek için bir seri seç."
        case "INVALID_MELD_EXTENSION": "Seçtiğin taşlar bu seriye işlenemiyor. Renk ve sırayı kontrol et."
        case "EXACT_JOKER_REPLACEMENT_REQUIRED": "Okeyi almak için temsil ettiği renk ve sayıdaki tek taşı koymalısın."
        case "REQUEST_SEAT_RETURN_FIRST": "Kontrolü geri almak için Masaya geri dön düğmesine bas."
        // Game codes the desktop catalog does not cover yet (iPhone text).
        case "PRIMARY_ACTIVITY_STALE": "Odadaki etkinlik bu sırada değişti. Güncel durumu kontrol edip yeniden dene."
        case "WAIT_FOR_NEXT_HAND": "El sürüyor. Bu masaya bir sonraki elde oturabilirsin."
        case "SPECTATORS_DISABLED": "Bu masa izleyiciye kapalı."
        case "ILLEGAL_CARD": "Bu kart şu an oynanamaz. Açılan renge uy, yükselebiliyorsan yüksel; rengin yoksa koz at."
        case "INVALID_BID": "Bu ihale geçersiz. Önceki ihaleden yüksek ve masanın sınırları içinde bir sayı seç."
        case "OPENING_TOO_LOW": "Açmak için en az 101 gerekiyor; katlamalı masada önceki en yüksek açılışı geçmelisin."
        default: "Etkinlik servisine ulaşılamıyor. Yeniden dene."
        }
    }
}

public enum WatchSync {
    /// Where the room's video should be now (desktop `expectedPosition`).
    public static func expectedPosition(_ timeline: ActivityTimeline, nowMs: Double, serverOffsetMs: Double) -> Double {
        timeline.positionSec + (timeline.playing ? max(0, nowMs + serverOffsetMs - timeline.effectiveServerTimeMs) / 1000 * timeline.rate : 0)
    }
    /// A local player that reaches the end well before the room only follows the room.
    public static func ranAhead(expected: Double, duration: Double?) -> Bool {
        guard let duration, duration > 0 else { return false }
        return expected < duration - 15
    }
}

public enum YouTubeLink {
    /// The 11-character video id from a pasted link or bare id (desktop `parseYouTubeVideo`).
    public static func videoID(_ value: String) -> String? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if valid(text) { return text }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              var host = url.host?.lowercased() else { return nil }
        for prefix in ["www.", "m.", "music."] where host.hasPrefix(prefix) { host.removeFirst(prefix.count) }
        let parts = url.path.split(separator: "/").map(String.init)
        if host == "youtu.be" { return parts.first.flatMap { valid($0) ? $0 : nil } }
        guard host == "youtube.com" || host == "youtube-nocookie.com" else { return nil }
        if let v = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "v" })?.value { return valid(v) ? v : nil }
        guard parts.count >= 2, ["shorts", "embed", "live", "v"].contains(parts[0]), valid(parts[1]) else { return nil }
        return parts[1]
    }
    public static func valid(_ id: String) -> Bool {
        id.count == 11 && id.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-" || $0 == "_" }
    }
    public static func thumbnail(_ id: String) -> URL? { valid(id) ? URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg") : nil }
}
