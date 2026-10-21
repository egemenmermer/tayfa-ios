import Foundation

public struct ChatAttachment: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let size: Int
    public let mime: String
    public init(id: String, name: String, size: Int, mime: String) { self.id = id; self.name = name; self.size = size; self.mime = mime }
    public static func parse(_ raw: JSONValue) throws -> ChatAttachment {
        guard let id = raw["_id"].string, case .number(let size) = raw["size"], size.isFinite, size >= 0, size <= Double(Int32.max) else { throw RoomsError.invalidResponse }
        return ChatAttachment(id: try EndpointPolicy.id(id), name: FilePolicy.safeName(raw["filename"].string ?? "Dosya"), size: Int(size), mime: raw["content_type"].string ?? "application/octet-stream")
    }
}
public struct LocalAttachment: Identifiable, Equatable, Sendable {
    public let id: String
    public let url: URL
    public let name: String
    public let mime: String
    public let size: Int
    public init(id: String, url: URL, name: String, mime: String, size: Int) { self.id = id; self.url = url; self.name = name; self.mime = mime; self.size = size }
}
public struct AttachmentDraft: Identifiable, Equatable, Sendable {
    public enum State: Equatable, Sendable { case uploading, ready, failed }
    public var id: String { file.id }
    public let file: LocalAttachment
    public var state: State = .uploading
    public var progress: Double = 0
    public var uploaded: ChatAttachment?
    public init(file: LocalAttachment) { self.file = file }
}
public struct UserProfile: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let username: String
    public let discriminator: String?
    public let status: String?
    public let bio: String?
    public let avatarID: String?
    public init(id: String, name: String, username: String, discriminator: String? = nil, status: String? = nil, bio: String? = nil, avatarID: String? = nil) {
        self.id = id; self.name = name; self.username = username; self.discriminator = discriminator; self.status = status; self.bio = bio; self.avatarID = avatarID
    }
}
public enum MessageAction: Equatable, Sendable {
    case edit(id: String, content: String)
    case delete(id: String)
    case reaction(id: String, emoji: String, remove: Bool)
    public var messageID: String { switch self { case .edit(let id, _), .delete(let id), .reaction(let id, _, _): id } }
}
public enum FilePolicy {
    public static let maxBytes = 25 * 1024 * 1024
    public static func safeName(_ name: String) -> String {
        let clean = name.replacingOccurrences(of: "[\\x00-\\x1f\\x7f\"/\\\\]", with: "_", options: .regularExpression)
        let result = String(clean.prefix(200)); return result.isEmpty || result == "." || result == ".." ? "Dosya" : result
    }
    public static func mime(_ value: String) throws -> String {
        guard value.range(of: "^[-A-Za-z0-9.+]+/[-A-Za-z0-9.+]+$", options: .regularExpression) != nil else { throw RoomsError.invalidResponse }; return value
    }
    public static func origin(_ value: String, trusted: URL) throws -> URL {
        guard let parts = URLComponents(string: value), parts.scheme == "https", parts.host == trusted.host, (parts.port ?? 443) == (trusted.port ?? 443),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil, let url = parts.url else { throw RoomsError.invalidEndpoint }
        return url
    }
    public static func assetURL(base: URL, category: String, id: String, name: String? = nil) throws -> URL {
        guard ["attachments", "avatars", "icons", "emojis"].contains(category) else { throw RoomsError.invalidEndpoint }
        var url = base.appendingPathComponent(category).appendingPathComponent(try EndpointPolicy.id(id))
        if let name { url = url.appendingPathComponent(safeName(name)) }; return url
    }
}
public enum FileStager {
    private static var root: URL { FileManager.default.temporaryDirectory.appendingPathComponent("rooms-mobile-files", isDirectory: true) }
    public static func directory() throws -> URL {
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true); return directory
    }
    public static func stage(source: URL, mime: String) throws -> LocalAttachment {
        guard source.isFileURL else { throw RoomsError.invalidEndpoint }
        let type = try FilePolicy.mime(mime), name = FilePolicy.safeName(source.lastPathComponent)
        let directory = try directory(), output = directory.appendingPathComponent(name)
        do {
            FileManager.default.createFile(atPath: output.path, contents: nil)
            let input = try FileHandle(forReadingFrom: source), writer = try FileHandle(forWritingTo: output)
            defer { try? input.close(); try? writer.close() }
            var size = 0
            while let chunk = try input.read(upToCount: 262144), !chunk.isEmpty {
                try Task.checkCancellation(); size += chunk.count
                guard size <= FilePolicy.maxBytes else { throw RoomsError.fileTooLarge }
                try writer.write(contentsOf: chunk)
            }
            guard size > 0 else { throw RoomsError.invalidMessage }
            return LocalAttachment(id: directory.lastPathComponent, url: output, name: name, mime: type, size: size)
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }
    public static func remove(_ url: URL) {
        let parent = url.deletingLastPathComponent().standardizedFileURL
        guard parent.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL, UUID(uuidString: parent.lastPathComponent) != nil else { return }
        try? FileManager.default.removeItem(at: parent)
    }
    public static func multipart(_ file: LocalAttachment, boundary: String) throws -> URL {
        guard file.size > 0, file.size <= FilePolicy.maxBytes, file.url.isFileURL,
              (try file.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) == file.size else { throw RoomsError.fileTooLarge }
        _ = try FilePolicy.mime(file.mime)
        let output = try directory().appendingPathComponent("multipart")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        do {
            let writer = try FileHandle(forWritingTo: output), reader = try FileHandle(forReadingFrom: file.url)
            defer { try? writer.close(); try? reader.close() }
            let header = "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(FilePolicy.safeName(file.name))\"\r\nContent-Type: \(file.mime)\r\n\r\n"
            try writer.write(contentsOf: Data(header.utf8))
            var copied = 0
            while let chunk = try reader.read(upToCount: 262144), !chunk.isEmpty {
                try Task.checkCancellation(); copied += chunk.count
                guard copied <= file.size, copied <= FilePolicy.maxBytes else { throw RoomsError.fileTooLarge }
                try writer.write(contentsOf: chunk)
            }
            guard copied == file.size else { throw RoomsError.invalidResponse }
            try writer.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8)); return output
        } catch { remove(output); throw error }
    }
}
public protocol RichChatTransport: SocialChatTransport {
    func sendRichMessage(channelID: String, content: String, nonce: String, attachments: [String], replyID: String?) async throws -> ChatMessage
    func editMessage(channelID: String, messageID: String, content: String) async throws -> ChatMessage
    func deleteMessage(channelID: String, messageID: String) async throws
    func react(channelID: String, messageID: String, emoji: String, remove: Bool) async throws -> ChatMessage
    func message(channelID: String, messageID: String) async throws -> ChatMessage
    func uploadAttachment(_ file: LocalAttachment, progress: @escaping @Sendable (Double) -> Void) async throws -> ChatAttachment
    func downloadAttachment(_ attachment: ChatAttachment, channelID: String, messageID: String, userID: String) async throws -> URL
    func imagePreview(_ attachment: ChatAttachment) async throws -> URL
    func profile(userID: String) async throws -> UserProfile
    func avatar(_ profile: UserProfile) async throws -> URL?
}

public struct MentionCandidate: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

/// Lists community members that can be offered while typing `@`.
public protocol MentionDirectoryTransport: RichChatTransport {
    func communityMembers(serverID: String) async throws -> [MentionCandidate]
}

/// Draft-side mention handling: the composer shows readable `@Name` tokens and
/// only tokens chosen from suggestions are converted to canonical `<@id>` on send.
public enum MentionDraft {
    public static let maxQueryLength = 32

    /// The `@query` the user is currently typing at the end of the draft, if any.
    public static func query(in draft: String) -> String? {
        guard let at = draft.lastIndex(of: "@") else { return nil }
        if at > draft.startIndex, !draft[draft.index(before: at)].isWhitespace { return nil }
        let query = draft[draft.index(after: at)...]
        guard query.count <= maxQueryLength, !query.contains(where: \.isWhitespace) else { return nil }
        return String(query)
    }

    public static func suggestions(_ query: String, from candidates: [MentionCandidate], limit: Int = 6) -> [MentionCandidate] {
        let needle = fold(query)
        let ranked = candidates.compactMap { candidate -> (Int, MentionCandidate)? in
            let name = fold(candidate.name)
            if needle.isEmpty || name.hasPrefix(needle) { return (0, candidate) }
            if name.contains(needle) { return (1, candidate) }
            return nil
        }
        return ranked.sorted { ($0.0, fold($0.1.name), $0.1.id) < ($1.0, fold($1.1.name), $1.1.id) }.prefix(limit).map(\.1)
    }

    /// Visible token; people sharing a display name get a short ID suffix so bindings stay unambiguous.
    public static func token(for candidate: MentionCandidate, among candidates: [MentionCandidate]) -> String {
        let name = candidate.name.components(separatedBy: .newlines).joined(separator: " ")
        let shared = candidates.contains { $0.id != candidate.id && $0.name == candidate.name }
        return "@" + name + (shared ? "#" + String(candidate.id.suffix(4)) : "")
    }

    /// Replaces bound tokens that still appear intact (followed by a boundary) with `<@id>`.
    public static func encode(_ content: String, bindings: [String: String]) -> (content: String, mentions: [String]) {
        var result = content
        var mentions: [String] = []
        for (token, id) in bindings.sorted(by: { $0.key.count > $1.key.count }) {
            var searchStart = result.startIndex
            while let range = result.range(of: token, range: searchStart..<result.endIndex) {
                let boundary = range.upperBound == result.endIndex || !(result[range.upperBound].isLetter || result[range.upperBound].isNumber)
                if boundary {
                    let replacement = "<@\(id)>"
                    result.replaceSubrange(range, with: replacement)
                    if !mentions.contains(id) { mentions.append(id) }
                    searchStart = result.index(range.lowerBound, offsetBy: replacement.count)
                } else {
                    searchStart = range.upperBound
                }
            }
        }
        return (result, mentions)
    }

    private static func fold(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "tr_TR"))
    }
}
