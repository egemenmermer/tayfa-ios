import Foundation

/// The relay's HLS media playlist (ffmpeg fMP4 output, desktop `apps/services/cinema/relay.ts`) as the
/// iPhone player needs it. Electron serves relay files under `rooms-cinema://` and swaps the ticket per
/// request; AVPlayer cannot, so every playlist reload is rewritten with the ticket of that moment and
/// the media segments load straight from the relay over HTTPS.
public enum CinemaPlaylist {
    /// What the player and the tests need to know about one playlist.
    public struct Summary: Equatable, Sendable {
        public let mediaSequence: Int
        public let durations: [Double]
        public let ended: Bool
        public let discontinuity: Bool
        /// PROGRAM-DATE-TIME (epoch ms) of the first listed segment, or nil.
        public let firstPdtMs: Double?
    }

    /// Relay file names: `init.mp4`, `segNNNNNN.m4s` (the playlist itself is `index.m3u8`).
    public static func validFile(_ name: String) -> Bool {
        name.range(of: "^[A-Za-z0-9_][A-Za-z0-9_.-]{0,63}$", options: .regularExpression) != nil && !name.contains("..")
    }

    /// Makes `#EXT-X-MAP` and every segment absolute under `base` (`…/rooms-cinema/v1/relay/<ticket>/`) and
    /// writes ffmpeg's `+0000` date offsets as `+00:00`; every other line is kept. Anything that is not a
    /// plain relay file name is refused, so the playlist can never point the player elsewhere.
    public static func rewrite(_ text: String, base: URL) throws -> String {
        guard base.scheme == "https", base.query == nil, base.absoluteString.hasSuffix("/") else { throw CinemaError(code: "CINEMA_STREAM_FAILED") }
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }).map(String.init)
        guard lines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })?.trimmingCharacters(in: .whitespaces) == "#EXTM3U" else {
            throw CinemaError(code: "CINEMA_STREAM_FAILED")
        }
        func absolute(_ name: String) throws -> String {
            guard validFile(name), let url = URL(string: name, relativeTo: base)?.absoluteURL, url.host == base.host else { throw CinemaError(code: "CINEMA_STREAM_FAILED") }
            return url.absoluteString
        }
        var output: [String] = []
        output.reserveCapacity(lines.count)
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { output.append(""); continue }
            if line.hasPrefix("#EXT-X-MAP:") {
                guard let range = line.range(of: #"URI="[^"]*""#, options: [.regularExpression, .caseInsensitive]) else { throw CinemaError(code: "CINEMA_STREAM_FAILED") }
                let name = String(line[range].dropFirst(5).dropLast())
                output.append(line.replacingCharacters(in: range, with: "URI=\"\(try absolute(name))\""))
            } else if line.hasPrefix("#EXT-X-PROGRAM-DATE-TIME:") {
                output.append("#EXT-X-PROGRAM-DATE-TIME:" + normalizedDate(String(line.dropFirst("#EXT-X-PROGRAM-DATE-TIME:".count))))
            } else if line.hasPrefix("#") {
                output.append(line)
            } else {
                output.append(try absolute(line))
            }
        }
        while output.last == "" { output.removeLast() }
        return output.joined(separator: "\n") + "\n"
    }

    /// ISO 8601 wants `+hh:mm`; ffmpeg writes `+hhmm`.
    public static func normalizedDate(_ value: String) -> String {
        let text = value.trimmingCharacters(in: .whitespaces)
        guard let range = text.range(of: #"[+-]\d{4}$"#, options: .regularExpression) else { return text }
        let offset = text[range]
        return "\(text[..<range.lowerBound])\(offset.prefix(3)):\(offset.suffix(2))"
    }

    /// Epoch ms of a PROGRAM-DATE-TIME value in either offset form, or nil.
    public static func dateMs(_ value: String) -> Double? {
        let text = normalizedDate(value)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date.timeIntervalSince1970 * 1000 }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text).map { $0.timeIntervalSince1970 * 1000 }
    }

    /// Media sequence, segment durations, end marker and the first segment's date (desktop `playlistSegments`).
    /// ffmpeg writes each segment's PROGRAM-DATE-TIME between its EXTINF and its URI, so the first one
    /// in the list belongs to the first listed segment.
    public static func summary(_ text: String) -> Summary {
        var sequence = 0, durations: [Double] = [], ended = false, discontinuity = false, firstPdt: Double?
        for raw in text.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") { sequence = Int(line.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count)) ?? 0 }
            else if line.hasPrefix("#EXTINF:") { durations.append(Double(line.dropFirst("#EXTINF:".count).prefix { $0 != "," }) ?? 0) }
            else if line == "#EXT-X-ENDLIST" { ended = true }
            else if line == "#EXT-X-DISCONTINUITY" { discontinuity = true }
            else if firstPdt == nil, line.hasPrefix("#EXT-X-PROGRAM-DATE-TIME:") { firstPdt = dateMs(String(line.dropFirst("#EXT-X-PROGRAM-DATE-TIME:".count))) }
        }
        return Summary(mediaSequence: sequence, durations: durations, ended: ended, discontinuity: discontinuity, firstPdtMs: firstPdt)
    }
}
