import Foundation

/// A mention run in rendered message text: the mentioned user id, or "" for a typed `@word`.
public enum MentionAttribute: AttributedStringKey { public typealias Value = String; public static let name = "rooms.mention" }
/// A custom server emoji run (`:ULID:` in the message); the value is the emoji id.
public enum CustomEmojiAttribute: AttributedStringKey { public typealias Value = String; public static let name = "rooms.customEmoji" }

/// How message text is shown: desktop links and mentions (`RealSocial.tsx` `messageText`) plus inline markdown.
public enum MessageMarkup {
    /// Desktop `isGifMessage`: a KLIPY CDN GIF sent as the whole message is shown as the picture itself.
    public static func gifURL(_ content: String) -> URL? {
        let value = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.range(of: #"^https://static\.klipy\.com/[^\s]+\.(?:gif|webp)$"#, options: [.regularExpression, .caseInsensitive]) != nil,
              let url = URL(string: value), url.host?.lowercased() == GifPolicy.mediaHost, url.user == nil, url.password == nil else { return nil }
        return url
    }

    /// Links as desktop finds them: `http(s)://` up to whitespace or `<>`, without trailing sentence punctuation.
    public static func links(in text: String) -> [(range: Range<String.Index>, url: URL)] {
        guard let expression = try? NSRegularExpression(pattern: #"https?://[^\s<>]+"#, options: [.caseInsensitive]) else { return [] }
        let whole = NSRange(text.startIndex..., in: text)
        return expression.matches(in: text, range: whole).compactMap { match in
            guard var range = Range(match.range, in: text) else { return nil }
            while range.lowerBound < range.upperBound, let last = text[range].last, ".,!?;:)]}'\"".contains(last) {
                range = range.lowerBound..<text.index(before: range.upperBound)
            }
            guard range.lowerBound < range.upperBound, let url = URL(string: String(text[range])), let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https", url.host != nil else { return nil }
            return (range, url)
        }
    }

    /// The message as styled text: inline markdown (bold, italic, code, strikethrough), the desktop's
    /// links and `<@id>` mentions, and `:id:` custom emoji runs. Markdown never creates links or images,
    /// so the visible text always shows where a link goes. Falls back to plain text when parsing fails.
    public static func render(_ raw: String, name: (String) -> String) -> AttributedString {
        enum Token { case link(String, URL), mention(String), emoji(String) }
        // The placeholders below are private-use characters; typed ones are never taken for them.
        let content = raw.replacingOccurrences(of: "\u{E000}", with: "\u{FFFD}").replacingOccurrences(of: "\u{E001}", with: "\u{FFFD}")
        var tokens: [Token] = []
        var source = ""
        // Protect links, mentions and emoji ids from markdown with private-use placeholders.
        var cursor = content.startIndex
        for piece in protectedRanges(content) {
            source += escapedMarkdown(String(content[cursor..<piece.range.lowerBound]))
            source += "\u{E000}\(tokens.count)\u{E001}"
            switch piece.kind {
            case .link(let url): tokens.append(.link(String(content[piece.range]), url))
            case .mention(let id): tokens.append(.mention(id))
            case .emoji(let id): tokens.append(.emoji(id))
            }
            cursor = piece.range.upperBound
        }
        source += escapedMarkdown(String(content[cursor...]))
        let options = AttributedString.MarkdownParsingOptions(allowsExtendedAttributes: false, interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        var result: AttributedString
        if let parsed = try? AttributedString(markdown: source, options: options) {
            result = parsed
            // Markdown links and images (incl. bare `www.` autolinks) are never trusted.
            for run in result.runs where run.link != nil || run.imageURL != nil { result[run.range].link = nil; result[run.range].imageURL = nil }
        } else { result = AttributedString(source) }
        // Put the protected text back (scalar search: a placeholder never merges with a combining mark).
        while let start = result.unicodeScalars.firstIndex(of: "\u{E000}") {
            guard let end = result.unicodeScalars[start...].firstIndex(of: "\u{E001}") else { break }
            let digits = String(String.UnicodeScalarView(result.unicodeScalars[result.unicodeScalars.index(after: start)..<end]))
            let range = start..<result.unicodeScalars.index(after: end)
            guard let index = Int(digits), tokens.indices.contains(index) else { result.replaceSubrange(range, with: AttributedString(digits)); continue }
            var replacement: AttributedString
            switch tokens[index] {
            case .link(let text, let url): replacement = AttributedString(text); replacement.link = url
            case .mention(let id): replacement = AttributedString("@" + name(id)); replacement[MentionAttribute.self] = id
            case .emoji(let id): replacement = AttributedString(":\(id):"); replacement[CustomEmojiAttribute.self] = id
            }
            // Keep emphasis around a protected piece (e.g. a link inside **…**).
            replacement.inlinePresentationIntent = result[range].runs.first?.inlinePresentationIntent
            result.replaceSubrange(range, with: replacement)
        }
        markTypedMentions(&result)
        return result
    }

    private enum Piece { case link(URL), mention(String), emoji(String) }
    /// Links, `<@id>` mentions and `:ULID:` custom emoji, in order and without overlap.
    private static func protectedRanges(_ text: String) -> [(range: Range<String.Index>, kind: Piece)] {
        var found: [(range: Range<String.Index>, kind: Piece)] = links(in: text).map { ($0.range, .link($0.url)) }
        for match in matches(#"<@([A-Za-z0-9_-]{1,128})>"#, in: text) where !found.contains(where: { $0.range.overlaps(match.range) }) {
            found.append((match.range, .mention(match.capture)))
        }
        for match in matches(#":([0-9A-HJKMNP-TV-Z]{26}):"#, in: text) where !found.contains(where: { $0.range.overlaps(match.range) }) {
            found.append((match.range, .emoji(match.capture)))
        }
        return found.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }
    private static func matches(_ pattern: String, in text: String) -> [(range: Range<String.Index>, capture: String)] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        return expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let range = Range(match.range, in: text), let capture = Range(match.range(at: 1), in: text) else { return nil }
            return (range, String(text[capture]))
        }
    }
    /// `[` (links, images) and `&` (entities) are literal outside code spans, as on desktop.
    static func escapedMarkdown(_ text: String) -> String {
        var output = "", index = text.startIndex
        while index < text.endIndex {
            if text[index] == "`" {
                var run = index
                while run < text.endIndex, text[run] == "`" { run = text.index(after: run) }
                let fence = String(text[index..<run])
                // A code span ends at the next backtick run of the same length; its content stays verbatim.
                var search = run, closed: String.Index?
                while let candidate = text[search...].range(of: fence) {
                    var after = candidate.upperBound
                    while after < text.endIndex, text[after] == "`" { after = text.index(after: after) }
                    if text.distance(from: candidate.lowerBound, to: after) == fence.count { closed = after; break }
                    search = after
                }
                if let closed { output += text[index..<closed]; index = closed } else { output += fence; index = run }
                continue
            }
            let character = text[index]
            if character == "[" || character == "&" { output += "\\" }
            output.append(character)
            index = text.index(after: index)
        }
        return output
    }
    /// Desktop highlights a typed `@word` too; never inside a link.
    private static func markTypedMentions(_ text: inout AttributedString) {
        let plain = String(text.characters)
        for match in matches(#"@([\p{L}\p{N}_-]+)"#, in: plain) {
            let lower = plain.distance(from: plain.startIndex, to: match.range.lowerBound), count = plain.distance(from: match.range.lowerBound, to: match.range.upperBound)
            let start = text.characters.index(text.startIndex, offsetBy: lower), end = text.characters.index(start, offsetBy: count)
            guard text[start..<end].runs.allSatisfy({ $0.link == nil && $0[MentionAttribute.self] == nil }) else { continue }
            text[start..<end][MentionAttribute.self] = ""
        }
    }
}

/// Reaction keys as Stoat v0.15.5 stores them: the emoji itself or a custom emoji id.
/// Legacy codepoint keys (`2764`, `1f44d-1f3fd`) are still shown and turned into the emoji (desktop `reactions.ts`).
public enum ReactionKey {
    /// The key to send upstream; Stoat rejects codepoint ids with 400 (desktop `reactionEmoji`).
    public static func upstream(_ key: String) -> String {
        guard key.range(of: "^[0-9a-f]{4,6}(?:-[0-9a-f]{4,6})*$", options: .regularExpression) != nil else { return key }
        let scalars = key.split(separator: "-").compactMap { UInt32($0, radix: 16).flatMap(Unicode.Scalar.init) }
        return scalars.count == key.split(separator: "-").count ? String(String.UnicodeScalarView(scalars)) : key
    }
    /// Codepoints without variation selectors, so `❤`, `❤️`, `2764` and `2764-fe0f` are one reaction (desktop `reactionCodepoints`).
    public static func codepoints(_ key: String) -> String {
        let emoji = upstream(key)
        guard !emoji.unicodeScalars.allSatisfy(\.isASCII) else { return key }
        return emoji.unicodeScalars.filter { $0.value != 0xFE0F }.map { String($0.value, radix: 16) }.joined(separator: "-")
    }
    public static func same(_ left: String, _ right: String) -> Bool { codepoints(left) == codepoints(right) }
    /// A custom server emoji id (ULID).
    public static func isCustom(_ key: String) -> Bool { key.range(of: "^[0-9A-HJKMNP-TV-Z]{26}$", options: .regularExpression) != nil }
    /// The Unicode emoji to draw, or nil for a custom emoji or an unreadable key.
    public static func symbol(_ key: String) -> String? {
        guard !isCustom(key) else { return nil }
        let emoji = upstream(key)
        return validEmoji(emoji) ? emoji : nil
    }
    /// What the service accepts (`SOCIAL_REACTION_PATTERN`): a custom emoji id or 1–16 emoji code points.
    public static func valid(_ key: String) -> Bool { isCustom(key) || validEmoji(key) }
    private static func validEmoji(_ value: String) -> Bool {
        let scalars = value.unicodeScalars
        guard (1...16).contains(scalars.count), scalars.contains(where: { !$0.isASCII }) else { return false }
        return scalars.allSatisfy { scalar in
            let v = scalar.value
            return scalar.properties.isEmoji || scalar.properties.isEmojiModifier || v == 0x200D || v == 0xFE0F || v == 0x20E3 || (0x1F1E6...0x1F1FF).contains(v) || (0xE0020...0xE007F).contains(v)
        }
    }
    /// The path segment for `/reactions/{key}`.
    public static func pathComponent(_ key: String) throws -> String {
        let value = upstream(key)
        guard valid(value), let encoded = value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")) else { throw RoomsError.invalidMessage }
        return encoded
    }
}

/// A community's own emoji (Stoat custom emoji).
public struct CustomEmoji: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let animated: Bool
    public init(id: String, name: String, animated: Bool) { self.id = id; self.name = name; self.animated = animated }
    static func parse(_ raw: JSONValue, serverID: String) -> CustomEmoji? {
        guard let id = raw["_id"].string, ReactionKey.isCustom(id), raw["parent"]["id"].string == serverID else { return nil }
        return CustomEmoji(id: id, name: String((raw["name"].string ?? "emoji").prefix(32)), animated: raw["animated"] == .bool(true))
    }
}
