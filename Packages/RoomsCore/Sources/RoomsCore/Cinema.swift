import Foundation

// The community cinema ("Sinema salonu"): public shapes of the cinema service (desktop
// `packages/community-cinema/src/types.ts`). Nothing here carries a provider URL or credential;
// items use opaque refs and artwork uses opaque ids the service resolves.

public enum CinemaKind: String, Codable, Sendable, CaseIterable {
    case live, movie, series
}
public enum CinemaSort: String, Sendable {
    case standard = "default", name, added, rating
}
public enum CinemaRef {
    /// `l-` live, `m-` movie, `s-` series, `e-` episode (desktop `CINEMA_REF_PATTERN`).
    public static func valid(_ ref: String) -> Bool { ref.range(of: "^[a-z]-[A-Za-z0-9_-]{1,120}$", options: .regularExpression) != nil }
    public static func validArt(_ id: String) -> Bool { id.range(of: "^[a-f0-9]{16,64}$", options: .regularExpression) != nil }
    public static func validCategory(_ id: String) -> Bool { id.range(of: "^[a-z][A-Za-z0-9_-]{1,100}$", options: .regularExpression) != nil }
}

public struct CinemaStatus: Codable, Equatable, Sendable {
    public struct Catalog: Codable, Equatable, Sendable {
        public let live: Int
        public let movies: Int
        public let series: Int
        public let programmes: Int
        public let importedAt: Double?
        public let guideImportedAt: Double?
    }
    public struct Import: Codable, Equatable, Sendable {
        /// `connecting`, `live`, `movies`, `series`, `guide`, `completed` or `failed`.
        public let step: String
        public let error: String?
        public let startedAt: Double
        public let finishedAt: Double?
        public var running: Bool { step != "completed" && step != "failed" }
    }
    public let communityId: String
    /// The text channel the owner marked as the hall, or nil when the community has none.
    public let hallChannelId: String?
    public let isOwner: Bool
    public let connected: Bool
    public let catalog: Catalog
    public let importing: Import?
    public let relaySlots: Int
    public var importRunning: Bool { importing?.running ?? false }
}

public struct CinemaCategory: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let kind: CinemaKind
    /// Label without the country marker; `flag` holds the emoji when known.
    public let label: String
    public let flag: String?
    public let count: Int
}

public struct CinemaItem: Codable, Equatable, Sendable, Identifiable {
    public let ref: String
    public let kind: CinemaKind
    public let title: String
    /// Quality badges parsed by the service (`FHD`, `4K`, `H265`…).
    public let badges: [String]
    public let categoryId: String?
    public let number: Int?
    public let art: String?
    public let year: Int?
    /// 0–10.
    public let rating: Double?
    /// Epoch ms when the provider added it.
    public let addedAt: Double?
    /// Live: whether a guide is matched.
    public let hasGuide: Bool?
    public var id: String { ref }
    public init(ref: String, kind: CinemaKind, title: String, badges: [String] = [], categoryId: String? = nil, number: Int? = nil,
                art: String? = nil, year: Int? = nil, rating: Double? = nil, addedAt: Double? = nil, hasGuide: Bool? = nil) {
        self.ref = ref; self.kind = kind; self.title = title; self.badges = badges; self.categoryId = categoryId; self.number = number
        self.art = art; self.year = year; self.rating = rating; self.addedAt = addedAt; self.hasGuide = hasGuide
    }
    /// The hall queue's media for this item.
    public var media: ActivityMedia { .community(ref: ref, title: title, live: kind == .live, art: art) }
}
public struct CinemaItemPage: Codable, Equatable, Sendable {
    public let items: [CinemaItem]
    public let total: Int
}

public struct CinemaProgramme: Codable, Equatable, Sendable {
    /// Epoch ms.
    public let start: Double
    public let stop: Double
    public let title: String
    public let subTitle: String?
    public let description: String?
    public let category: String?
}

public struct CinemaEpisode: Codable, Equatable, Sendable, Identifiable {
    public let ref: String
    public let season: Int
    public let episode: Int
    public let title: String
    public let plot: String?
    public let durationSec: Double?
    public let art: String?
    public var id: String { ref }
}
public struct CinemaDetails: Codable, Equatable, Sendable {
    public struct Season: Codable, Equatable, Sendable, Identifiable {
        public let season: Int
        public let episodes: [CinemaEpisode]
        public var id: Int { season }
    }
    /// The same title in another quality; its own badges are on `item`.
    public struct Version: Codable, Equatable, Sendable, Identifiable {
        public let ref: String
        public let badges: [String]
        public var id: String { ref }
    }
    public let item: CinemaItem
    public let plot: String?
    public let genre: String?
    public let cast: String?
    public let director: String?
    public let durationSec: Double?
    public let backdrop: String?
    public let seasons: [Season]
    public let versions: [Version]?
}

public struct CinemaAudioTrack: Codable, Equatable, Sendable, Identifiable {
    /// Position among the source's audio streams.
    public let index: Int
    public let label: String
    public var id: Int { index }
}
/// A relay session for the hall's current item (`POST /watch`).
public struct CinemaWatch: Codable, Equatable, Sendable {
    /// 32 hex characters.
    public let session: String
    public let ticket: String
    /// Server clock; renew by the local clock with `ttlMs` instead.
    public let expiresAt: Double
    public let itemRef: String
    public let live: Bool
    /// VOD only.
    public let durationSec: Double?
    /// VOD: the work position the relay started from.
    public let offsetSec: Double
    public let epoch: Int
    public let ttlMs: Double
    /// EXT-X-PROGRAM-DATE-TIME (epoch ms) of relay output time 0, or nil while unknown.
    /// Work position = offsetSec + (playing date − originPdtMs) / 1000, for live and VOD.
    public let originPdtMs: Double?
    public let audioTracks: [CinemaAudioTrack]
    public let audioTrack: Int?
}
/// A renewed relay ticket (`POST /sessions/:session/ticket`).
public struct CinemaTicket: Codable, Equatable, Sendable {
    public let ticket: String
    public let expiresAt: Double
    public let ttlMs: Double
}

/// A cinema service refusal, with the desktop's Turkish text (`cinema-bridge.ts`).
public struct CinemaError: Error, LocalizedError, Equatable, Sendable {
    public let code: String
    public init(code: String) { self.code = code }
    /// The running relay is gone (session ended, file expired, audio changed): call `watch` again.
    public var needsNewWatch: Bool { ["CINEMA_SESSION_ENDED", "CINEMA_RELAY_GONE"].contains(code) }
    /// A relay file was refused for an expired ticket: renew it and retry once.
    public var ticketExpired: Bool { code == "CINEMA_TICKET_EXPIRED" }
    public var errorDescription: String? {
        switch code {
        case "CINEMA_OWNER_REQUIRED": "Bunu yalnızca topluluk sahibi yapabilir."
        case "CINEMA_HALL_REQUIRED": "Bu toplulukta henüz bir sinema salonu seçilmedi."
        case "CINEMA_ACCESS_DENIED": "Sinema salonunu görme iznin yok."
        case "CINEMA_NOT_CONNECTED": "Sunucuya bağlı bir IPTV hesabı yok."
        case "CINEMA_SOURCE_INVALID": "Bilgiler eksik ya da hatalı. Sunucu adresini ve hesabı kontrol et."
        case "CINEMA_PROVIDER_DENIED": "Sağlayıcı bu hesabı kabul etmedi. Kullanıcı adını ve şifreyi kontrol et."
        case "CINEMA_PROVIDER_UNREACHABLE": "Sağlayıcıya ulaşılamadı. Yayın kaynağı şu an kapalı olabilir."
        case "CINEMA_ACCOUNT_EXPIRED": "IPTV hesabının süresi dolmuş. Sahibin hesabı yenilemesi gerekiyor."
        case "CINEMA_IMPORT_RUNNING": "Katalog şu an yükleniyor. Bitince yeniden dene."
        case "CINEMA_ITEM_NOT_FOUND": "Bu içerik artık katalogda yok."
        case "CINEMA_NOTHING_SELECTED": "Salonda şu an açık bir şey yok."
        case "CINEMA_RELAY_BUSY": "Hesabın aynı anda açabileceği yayın sınırı dolu."
        case "CINEMA_CODEC_UNSUPPORTED": "Bu kanalın görüntü biçimi salonda oynatılamıyor. Başka bir kanal dene."
        case "CINEMA_STREAM_FAILED": "Yayın açılamadı. Biraz sonra yeniden dene."
        case "CINEMA_SESSION_ENDED", "CINEMA_RELAY_GONE": "Salondaki yayın değişti. Yeniden bağlanılıyor…"
        case "CINEMA_RATE_LIMITED": "Çok hızlı istek gönderildi. Birkaç saniye sonra yeniden dene."
        default: "Sinema servisi şu an yanıt vermiyor. Biraz sonra yeniden dene."
        }
    }
}
