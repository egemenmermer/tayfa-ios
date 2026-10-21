import Foundation

/// Shared room DJ (the ROOMS music bot), mirroring the desktop music contract.
public struct MusicTrack: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let durationSec: Double
}

public struct MusicSearchResult: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let durationSec: Double
    public var url: String { "https://www.youtube.com/watch?v=\(id)" }
}

public struct MusicSnapshot: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case disconnected, connecting, playing, paused, error }
    public struct Candidates: Codable, Equatable, Sendable {
        public let query: String
        public let candidates: [MusicSearchResult]
    }
    public let channelId: String
    public let identity: String
    public let status: Status
    public let queue: [MusicTrack]
    public let currentId: String?
    public let positionSec: Double
    public let error: String?
    public let matchCandidates: Candidates?
    public var current: MusicTrack? { queue.first { $0.id == currentId } }
    public var currentIndex: Int? { queue.firstIndex { $0.id == currentId } }
}

public enum MusicCommand: Equatable, Sendable {
    case add(url: String, playNow: Bool)
    case play, pause, next, previous, stop
    case seek(id: String, positionSec: Double)
    case select(id: String)
    case remove(id: String)
    /// A saved playlist into the queue (`add-list`), optionally starting it.
    case addList(tracks: [PlaylistTrack], playNow: Bool)
    /// A history session back into the queue, from `trackID` if given.
    case restore(sessionID: String, trackID: String?)
    /// A full permutation of the queue's ids.
    case reorder(ids: [String])

    var json: JSONValue {
        switch self {
        case let .add(url, playNow):
            var body: [String: JSONValue] = ["type": .string("add"), "url": .string(url), "offerCandidates": .bool(true)]
            if playNow { body["playNow"] = .bool(true) }
            return .object(body)
        case .play: return .object(["type": .string("play")])
        case .pause: return .object(["type": .string("pause")])
        case .next: return .object(["type": .string("next")])
        case .previous: return .object(["type": .string("previous")])
        case .stop: return .object(["type": .string("stop")])
        case let .seek(id, position):
            return .object(["type": .string("seek"), "id": .string(id), "positionSec": .number(min(7200, max(0, position)))])
        case let .select(id): return .object(["type": .string("select"), "id": .string(id)])
        case let .remove(id): return .object(["type": .string("remove"), "id": .string(id)])
        case let .addList(tracks, playNow):
            var body: [String: JSONValue] = ["type": .string("add-list"), "tracks": .array(tracks.prefix(100).map(\.json))]
            if playNow { body["playNow"] = .bool(true) }
            return .object(body)
        case let .restore(session, track):
            var body: [String: JSONValue] = ["type": .string("restore"), "sessionId": .string(session)]
            if let track { body["trackId"] = .string(track) }
            return .object(body)
        case let .reorder(ids): return .object(["type": .string("reorder"), "ids": .array(ids.prefix(100).map(JSONValue.string))])
        }
    }
}

/// Input in the DJ box: a link is added directly, plain text searches YouTube.
public enum MusicInput: Equatable, Sendable {
    case link(String), search(String), invalid
    public init(_ raw: String) {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: value), url.scheme == "https", url.host != nil, url.user == nil, url.password == nil, value.count <= 2048 {
            self = .link(value)
        } else if value.count >= 2, value.count <= 200, !value.contains(where: { $0.isNewline }),
                  value.range(of: #"^\w+:|^www\."#, options: [.regularExpression, .caseInsensitive]) == nil {
            self = .search(value)
        } else { self = .invalid }
    }
}

public struct MusicError: LocalizedError, Equatable, Sendable {
    public let code: String
    private static let messages: [String: String] = [
        "MUSIC_SPOTIFY_PLAYLIST_UNAVAILABLE": "Spotify listesi okunamadı. Listenin herkese açık olduğundan emin olup yeniden dene.",
        "MUSIC_SPOTIFY_PLAYLIST_EMPTY": "Spotify listesinin herkese açık görünümünde şarkı bulunamadı.",
        "MUSIC_SPOTIFY_PLAYLIST_LIMIT": "Spotify bu listenin tamamını göstermeyebilir. 100 parçadan az bir liste kullan.",
        "MUSIC_QUEUE_CHANGED": "Kuyruk değişti. Güncel sırayla yeniden dene.",
        "MUSIC_SEARCH_BUSY": "Arama meşgul. Biraz sonra yeniden dene.",
        "MUSIC_SEARCH_UNAVAILABLE": "Arama şu anda kullanılamıyor. Yeniden dene.",
        "MUSIC_SEEK_INVALID": "Bu parçanın süresi doğrulanmadı veya seçilen konum geçersiz.",
        "MUSIC_YOUTUBE_ACCESS_REQUIRED": "Sunucunun YouTube ses erişimi doğrulanamadı. DJ şu anda bu kaynaktan çalamıyor.",
        "MUSIC_YOUTUBE_UNAVAILABLE": "YouTube parçası şu anda alınamıyor. Yeniden dene.",
        "MUSIC_SOURCE_TIMEOUT": "Parça yüklenmesi zaman aşımına uğradı. Yeniden dene.",
        "MUSIC_NOT_CONFIGURED": "Müzik botu sunucuda yapılandırılmadı.",
        "MUSIC_SOURCE_FAILED": "Geçerli bir YouTube, Spotify, SoundCloud veya ses bağlantısı gir.",
        "MUSIC_MIRROR_NOT_FOUND": "Bu parçanın YouTube kaydı bulunamadı. Şarkı adını arayıp uygun sonucu seçebilirsin.",
        "MUSIC_MIRROR_SINGLE_TRACK_ONLY": "Spotify şarkısı veya herkese açık liste; SoundCloud için tek şarkı bağlantısı gir.",
        "MUSIC_JOIN_FIRST": "Önce ses odasına katıl.",
        "MUSIC_PERMISSION_DENIED": "Bu odada müzik kontrol yetkin yok.",
        "MUSIC_QUEUE_FULL": "Kuyruk dolu. En fazla 100 parça eklenebilir.",
        "MUSIC_TRANSPORT_UNAVAILABLE": "Müzik botu ses odasına bağlanamadı.",
        "MUSIC_CURRENT_ITEM": "Çalan parçayı kaldırmadan önce başka parçaya geç.",
        "MUSIC_SPOTIFY_PLAYLIST_INCOMPLETE": "Spotify listesindeki bazı kayıtların şarkı bilgisi okunamadı. Liste eklenmedi; yerel dosya veya podcast içermeyen bir liste dene.",
        "MUSIC_MIRROR_METADATA_UNAVAILABLE": "Şarkı bilgisi alınamadı. Herkese açık tek şarkı bağlantısını yeniden dene.",
        "MUSIC_CACHE_LIMIT": "Müzik dosyaları toplam boyut sınırını aştı.",
        "MUSIC_HISTORY_MISSING": "Geçmiş liste bulunamadı.",
        "MUSIC_HISTORY_UNAVAILABLE": "DJ geçmişi kaydedilemedi. Müzik bağlantısı korunuyor.",
        "MUSIC_PLAYLIST_CHANGED": "Liste başka biri tarafından değiştirildi. Yenileyip tekrar dene.",
        "MUSIC_PLAYLIST_EMPTY": "Kaydedilebilecek parça yok.",
        "MUSIC_PLAYLISTS_NOT_CONFIGURED": "Ortak listeler sunucuda henüz açılmadı.",
        "MUSIC_PLAYLIST_LIMIT": "Topluluğun liste sınırına ulaşıldı. Kullanılmayan listeleri veya parçaları kaldır.",
        "MUSIC_PLAYLIST_INVALID": "Liste bilgisi geçersiz. Desteklenen YouTube/Spotify bağlantılarını ve parça sınırını kontrol et.",
        "MUSIC_PLAYLIST_SOURCE_UNAVAILABLE": "Çalma listesi veya DJ geçmişi alınamadı. Kaynak erişimini kontrol edip yeniden dene.",
        "AUTH_REQUIRED": "Oturum doğrulanamadı. Bağlantıyı yenileyip yeniden dene.",
    ]
    public init(code: String) { self.code = code }
    public var errorDescription: String? { Self.messages[code] ?? "DJ sunucusu yanıt vermedi. Biraz sonra yeniden dene." }
}

public enum MusicClock {
    public static func format(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.isFinite ? seconds : 0))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
