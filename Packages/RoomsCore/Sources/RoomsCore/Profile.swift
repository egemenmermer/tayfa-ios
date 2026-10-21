import Foundation

/// Online status shown next to the name, the same four choices as desktop.
public enum Presence: String, CaseIterable, Identifiable, Sendable {
    case online = "Online", idle = "Idle", busy = "Busy", invisible = "Invisible"
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .online: "Çevrimiçi"
        case .idle: "Boşta"
        case .busy: "Rahatsız etmeyin"
        case .invisible: "Görünmez"
        }
    }
}

/// The signed-in person's own editable profile.
public struct OwnProfile: Equatable, Sendable {
    public var displayName: String
    public var bio: String
    public var statusText: String
    public var presence: Presence
    public let username: String
    public let avatarID: String?
    public init(displayName: String, bio: String = "", statusText: String = "", presence: Presence = .online, username: String, avatarID: String? = nil) {
        self.displayName = displayName; self.bio = bio; self.statusText = statusText; self.presence = presence
        self.username = username; self.avatarID = avatarID
    }
    public static let nameRange = 2...32, bioLimit = 2000, statusLimit = 128

    /// Why the edited fields cannot be saved yet, or `nil` when they can.
    public var problem: String? {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !Self.nameRange.contains(name.count) { return "Görünen ad 2–32 karakter olmalı." }
        if bio.count > Self.bioLimit { return "Hakkında en fazla \(Self.bioLimit) karakter olabilir." }
        if statusText.count > Self.statusLimit { return "Durum mesajı en fazla \(Self.statusLimit) karakter olabilir." }
        return nil
    }

    /// Stoat `PATCH /users/@me` body. Empty bio and status text are removed instead of saved blank.
    public func patchBody() throws -> JSONValue {
        if problem != nil { throw RoomsError.invalidMessage }
        let text = statusText.trimmingCharacters(in: .whitespacesAndNewlines)
        let about = bio.trimmingCharacters(in: .whitespacesAndNewlines)
        var status: [String: JSONValue] = ["presence": .string(presence.rawValue)]
        var remove: [JSONValue] = []
        if text.isEmpty { remove.append(.string("StatusText")) } else { status["text"] = .string(text) }
        var body: [String: JSONValue] = [
            "display_name": .string(displayName.trimmingCharacters(in: .whitespacesAndNewlines)),
            "status": .object(status),
        ]
        if about.isEmpty { remove.append(.string("ProfileContent")) } else { body["profile"] = .object(["content": .string(about)]) }
        body["remove"] = .array(remove)
        return .object(body)
    }
}

/// Avatar uploads follow desktop: PNG, JPEG or WebP up to 2 MB.
public enum AvatarPolicy {
    public static let maxBytes = 2_000_000
    public static let mimes: Set<String> = ["image/png", "image/jpeg", "image/webp"]
    public static func multipart(_ data: Data, mime: String, boundary: String) throws -> Data {
        guard !data.isEmpty, data.count <= maxBytes, mimes.contains(mime) else { throw RoomsError.fileTooLarge }
        let ext = mime == "image/png" ? "png" : mime == "image/webp" ? "webp" : "jpg"
        var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"avatar.\(ext)\"\r\nContent-Type: \(mime)\r\n\r\n".utf8)
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }
}
