import Foundation

// DJ history, the community's shared playlists and synced lyrics (desktop `MusicDJ.tsx`,
// `SharedPlaylists.tsx`, `MusicLyrics.tsx`; contracts in `packages/shared-contracts/src/music*.ts`).

/// One DJ listening session the music service remembers (at most 30, newest first).
public struct MusicHistorySession: Codable, Equatable, Sendable, Identifiable {
    public struct Track: Codable, Equatable, Sendable, Identifiable {
        public let id: String
        public let title: String
        public let durationSec: Double
        public let played: Bool
    }
    public let id: String
    public let startedAt: String
    public let endedAt: String?
    public let tracks: [Track]
    public var started: Date? { ChatMessage.isoDate(startedAt) }
}

/// A playlist entry: a YouTube video, or a Spotify track the DJ matches on YouTube when it plays.
public enum PlaylistTrack: Codable, Equatable, Sendable, Identifiable {
    case youtube(videoID: String, title: String, durationSec: Double)
    case spotify(trackID: String, title: String, durationSec: Double, artists: [String])
    public var id: String { switch self { case .youtube(let id, _, _): "yt:" + id; case .spotify(let id, _, _, _): "sp:" + id } }
    public var title: String { switch self { case .youtube(_, let title, _), .spotify(_, let title, _, _): title } }
    private enum Keys: String, CodingKey { case videoId, spotifyTrackId, title, durationSec, artists }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let title = try c.decode(String.self, forKey: .title), duration = try c.decode(Double.self, forKey: .durationSec)
        if let video = try c.decodeIfPresent(String.self, forKey: .videoId) { self = .youtube(videoID: video, title: title, durationSec: duration) }
        else { self = .spotify(trackID: try c.decode(String.self, forKey: .spotifyTrackId), title: title, durationSec: duration, artists: try c.decode([String].self, forKey: .artists)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .youtube(let id, let title, let duration): try c.encode(id, forKey: .videoId); try c.encode(title, forKey: .title); try c.encode(duration, forKey: .durationSec)
        case .spotify(let id, let title, let duration, let artists):
            try c.encode(id, forKey: .spotifyTrackId); try c.encode(title, forKey: .title); try c.encode(duration, forKey: .durationSec); try c.encode(artists, forKey: .artists)
        }
    }
    /// The strict protocol shape (titles 1–160 characters, durations 0–7200 s).
    public var json: JSONValue {
        let clean = { (value: String) in String(value.replacingOccurrences(of: "[\\x00-\\x1f]", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines).prefix(160)) }
        switch self {
        case .youtube(let id, let title, let duration):
            return .object(["videoId": .string(id), "title": .string(clean(title).isEmpty ? "YouTube parçası" : clean(title)), "durationSec": .number(min(7200, max(0, duration)))])
        case .spotify(let id, let title, let duration, let artists):
            return .object(["spotifyTrackId": .string(id), "title": .string(clean(title).isEmpty ? "Spotify parçası" : clean(title)), "durationSec": .number(min(7200, max(0, duration))),
                            "artists": .array(artists.prefix(8).map(clean).filter { !$0.isEmpty }.map(JSONValue.string))])
        }
    }
}
public struct SharedPlaylist: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let revision: Int
    public let name: String
    public let tracks: [PlaylistTrack]
    public let updatedAt: String
}
/// A change to the community's playlists; the service answers with the whole updated catalog.
public enum PlaylistChange: Equatable, Sendable {
    /// A new list (`id` nil) or an edit of `id` at `revision` (refused if someone saved in between).
    case save(id: String?, revision: Int?, name: String, tracks: [PlaylistTrack])
    /// The room's current queue, or a history session's tracks.
    case saveQueue(name: String, sessionID: String?)
    /// A YouTube or public Spotify playlist link.
    case importList(name: String, url: String)
    case remove(id: String, revision: Int)
    public var json: JSONValue {
        let named = { (name: String) in JSONValue.string(String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))) }
        switch self {
        case .save(let id, let revision, let name, let tracks):
            var value: [String: JSONValue] = ["op": .string("save"), "name": named(name), "tracks": .array(tracks.prefix(100).map(\.json))]
            if let id, let revision { value["id"] = .string(id); value["revision"] = .number(Double(revision)) }
            return .object(value)
        case .saveQueue(let name, let session):
            var value: [String: JSONValue] = ["op": .string("saveQueue"), "name": named(name)]
            if let session { value["sessionId"] = .string(session) }
            return .object(value)
        case .importList(let name, let url): return .object(["op": .string("import"), "name": named(name), "url": .string(url.trimmingCharacters(in: .whitespacesAndNewlines))])
        case .remove(let id, let revision): return .object(["op": .string("remove"), "id": .string(id), "revision": .number(Double(revision))])
        }
    }
}

/// Desktop `parseDJLink`: a YouTube video or playlist id from a link (radio mixes count as their video).
public enum DJLink: Equatable, Sendable {
    case video(String), playlist(String)
    public static func parse(_ raw: String) -> DJLink? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.range(of: "^[a-zA-Z0-9_-]{11}$", options: .regularExpression) != nil { return .video(value) }
        guard let parts = URLComponents(string: value), parts.scheme == "https", parts.user == nil, parts.password == nil, parts.port == nil,
              let host = parts.host, ["youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com", "youtu.be"].contains(host) else { return nil }
        let item = { (name: String) in parts.queryItems?.first { $0.name == name }?.value }
        let valid = { (id: String?) in id.map { $0.range(of: "^[a-zA-Z0-9_-]{11}$", options: .regularExpression) != nil } ?? false }
        if let list = item("list"), list.hasPrefix("RD"), let radio = item("v"), valid(radio) { return .video(radio) }
        if let list = item("list"), list.range(of: "^[a-zA-Z0-9_-]{10,128}$", options: .regularExpression) != nil { return .playlist(list) }
        let segments = parts.path.split(separator: "/").map(String.init)
        let id = host == "youtu.be" ? String(parts.path.dropFirst()) : item("v") ?? (segments.count >= 2 && ["shorts", "embed", "live"].contains(segments[0]) ? segments[1] : nil)
        return valid(id) ? .video(id!) : nil
    }
    /// Desktop `isPlaylistLink`: a YouTube playlist or a public Spotify playlist.
    public static func isPlaylist(_ raw: String) -> Bool {
        if case .playlist = parse(raw) { return true }
        guard let parts = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)), parts.scheme == "https", parts.user == nil, parts.password == nil, parts.port == nil,
              parts.host == "open.spotify.com" else { return false }
        return parts.path.range(of: "^/(?:intl-[a-z]{2}/)?playlist/[A-Za-z0-9]{22}/?$", options: .regularExpression) != nil
    }
}

/// Synced lyrics from LRCLIB, fetched only when asked; only the title and duration leave the phone (desktop `music-lyrics.ts`).
public enum MusicLyrics: Equatable, Sendable {
    public struct Line: Equatable, Sendable { public let time: Double; public let text: String }
    case unavailable, instrumental, found([Line])

    public static func load(title: String, durationSec: Double, fetcher: ExternalFetcher = .shared) async -> MusicLyrics {
        guard let request = request(title: title, durationSec: durationSec) else { return .unavailable }
        guard let data = try? await fetcher.data(request.url, allowedHosts: ["lrclib.net"], limit: 512 * 1024, headers: ["User-Agent": "ROOMS/1.0 (iPhone lyrics)"]) else { return .unavailable }
        return match(data, exact: request.exact, query: request.query, durationSec: durationSec)
    }
    /// `artist - title` asks for that exact record; anything else searches.
    public static func request(title: String, durationSec: Double) -> (url: URL, exact: Bool, query: String)? {
        guard !title.isEmpty, title.count <= 160, durationSec.isFinite, durationSec > 0, durationSec <= 7200 else { return nil }
        var query = title.replacingOccurrences(of: #"\s*· YouTube$"#, with: "", options: .regularExpression)
        query = query.replacingOccurrences(of: #"[\[(](?:official[^\])]*|lyrics?|audio|video)[\])]"#, with: "", options: [.regularExpression, .caseInsensitive]).trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = split(query)
        let exact = parts.count == 2 && parts.allSatisfy { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        var components = URLComponents(string: "https://lrclib.net/api/\(exact ? "get" : "search")")!
        components.queryItems = exact
            ? [URLQueryItem(name: "artist_name", value: parts[0].trimmingCharacters(in: .whitespaces)), URLQueryItem(name: "track_name", value: parts[1].trimmingCharacters(in: .whitespaces)), URLQueryItem(name: "duration", value: number(durationSec))]
            : [URLQueryItem(name: "q", value: query)]
        return components.url.map { ($0, exact, query) }
    }
    private static func split(_ text: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: #"\s+[-–—]\s+"#) else { return [text] }
        var parts: [String] = [], start = text.startIndex
        for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            parts.append(String(text[start..<range.lowerBound])); start = range.upperBound
        }
        return parts + [String(text[start...])]
    }
    /// JavaScript `String(number)` for the durations LRCLIB is asked about.
    private static func number(_ value: Double) -> String { value == value.rounded() ? String(Int(value)) : String(value) }
    /// Exactly one record of that artist and title within 2 seconds, or nothing.
    public static func match(_ data: Data, exact: Bool, query: String, durationSec: Double) -> MusicLyrics {
        guard let payload = try? JSONSerialization.jsonObject(with: data) else { return .unavailable }
        let records: [Any] = exact ? [payload] : (payload as? [Any] ?? [])
        guard records.count <= 100 else { return .unavailable }
        let wanted = normalize(query)
        let matching = records.compactMap { $0 as? [String: Any] }.filter { row in
            guard let track = row["trackName"] as? String, let artist = row["artistName"] as? String, let duration = (row["duration"] as? NSNumber)?.doubleValue else { return false }
            return abs(duration - durationSec) <= 2 && normalize("\(artist) \(track)") == wanted
        }
        guard matching.count == 1, let record = matching.first else { return .unavailable }
        if record["instrumental"] as? Bool == true { return .instrumental }
        guard let synced = record["syncedLyrics"] as? String, synced.count <= 100_000 else { return .unavailable }
        let lines = parse(synced: synced)
        return lines.isEmpty ? .unavailable : .found(lines)
    }
    /// LRC lines: every `[mm:ss.xx]` stamp of a row, sorted; at most 1000 lines up to two hours.
    public static func parse(synced: String) -> [Line] {
        guard let stamp = try? NSRegularExpression(pattern: #"\[(\d{1,3}):([0-5]\d)(?:[.:](\d{1,3}))?\]"#) else { return [] }
        var lines: [Line] = []
        for row in synced.components(separatedBy: "\n") {
            let text = String(row.replacingOccurrences(of: #"\[[^\]]*\]"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: "[\\x00-\\x1f<>]", with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines).prefix(1000))
            for match in stamp.matches(in: row, range: NSRange(row.startIndex..., in: row)) {
                let part = { (index: Int) in Range(match.range(at: index), in: row).map { String(row[$0]) } }
                guard let minutes = part(1).flatMap(Double.init), let seconds = part(2).flatMap(Double.init) else { continue }
                let time = minutes * 60 + seconds + (Double("0." + (part(3) ?? "0")) ?? 0)
                if time <= 7200 { lines.append(Line(time: time, text: text)) }
                if lines.count > 1000 { return [] }
            }
        }
        return lines.enumerated().sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }.map(\.element)
    }
    /// Desktop matching text: accents and punctuation folded away, dotless ı as i.
    public static func normalize(_ text: String) -> String {
        let folded = text.decomposedStringWithCompatibilityMapping.unicodeScalars.filter { !$0.properties.generalCategory.isMark }
        let lower = String(String.UnicodeScalarView(folded)).lowercased().replacingOccurrences(of: "ı", with: "i")
        return lower.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }
    /// The line being sung at `time` (the last one that has started).
    public static func activeLine(_ lines: [Line], at time: Double) -> Int? { lines.lastIndex { $0.time <= time } }
}

private extension Unicode.GeneralCategory {
    var isMark: Bool { self == .nonspacingMark || self == .spacingMark || self == .enclosingMark }
}
