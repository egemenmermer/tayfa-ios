import Foundation

public enum RoomsError: Error, LocalizedError, Equatable, Sendable {
    case invalidEndpoint, invalidResponse, expired, denied, unavailable, rateLimited, timeout, invalidCredentials, additionalAuthentication, invalidMessage, duplicateMessage, fileTooLarge, filesUnavailable
    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "Sunucu adresi geçersiz."
        case .invalidResponse: "Sunucu yanıtı okunamadı."
        case .expired: "Oturum sona erdi. Yeniden giriş yap."
        case .denied: "Bu odaya erişim iznin yok."
        case .unavailable: "Bağlantı kurulamadı. Tekrar dene."
        case .rateLimited: "Çok fazla istek var. Biraz sonra tekrar dene."
        case .timeout: "İşlem tamamlanamadı. Tekrar dene."
        case .invalidCredentials: "E-posta veya şifre hatalı."
        case .fileTooLarge: "Dosya en fazla 25 MB olabilir."
        case .filesUnavailable: "Dosya servisi şu anda kullanılamıyor."
        case .duplicateMessage: "Sunucu bu gönderimi tekrar olarak reddetti. Sohbeti yenile; mesaj görünmüyorsa yeni mesaj olarak yaz."
        case .invalidMessage: "Mesaj gönderilemedi. Metni kontrol edip tekrar dene."
        case .additionalAuthentication: "Bu hesap ek doğrulama istiyor. Stoat girişini tamamla."
        }
    }
}
public enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else { self = .array(try c.decode([JSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    public subscript(_ key: String) -> JSONValue { if case .object(let v) = self { return v[key] ?? .null }; return .null }
    public var string: String? { if case .string(let v) = self { return v }; return nil }
    public var object: [String: JSONValue]? { if case .object(let v) = self { return v }; return nil }
    public var array: [JSONValue] { if case .array(let v) = self { return v }; return [] }
}
public struct RoomsUser: Codable, Sendable, Equatable {
    public let id: String
    public let username: String
    public let displayName: String?
    enum CodingKeys: String, CodingKey { case id = "_id", username, displayName = "display_name" }
    public var name: String { displayName ?? username }
}
public struct VoiceRoom: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let community: String
    public init(id: String, name: String, community: String) { self.id = id; self.name = name; self.community = community }
    public static func fromReady(_ packet: JSONValue) -> [VoiceRoom] {
        let servers = Dictionary(packet["servers"].array.compactMap { v -> (String, String)? in
            guard let id = v["_id"].string else { return nil }; return (id, v["name"].string ?? "Topluluk")
        }, uniquingKeysWith: { _, last in last })
        return packet["channels"].array.compactMap { c in
            guard let id = c["_id"].string, let server = c["server"].string,
                  c["channel_type"].string == "VoiceChannel" || c["voice"] != .null else { return nil }
            return VoiceRoom(id: id, name: c["name"].string ?? "Ses odası", community: servers[server] ?? "Topluluk")
        }.sorted { ($0.community, $0.name, $0.id) < ($1.community, $1.name, $1.id) }
    }
}
public struct MediaGrant: Codable, Sendable {
    public let serverUrl: String
    public let roomName: String
    public let token: String
    public let expiresAt: String
}
public struct Directory: Codable, Sendable {
    public struct Occupant: Codable, Sendable {
        public let id: String; public let name: String; public let muted: Bool; public let screen: Bool?; public let deafened: Bool?
        public init(id: String, name: String, muted: Bool, screen: Bool? = nil, deafened: Bool? = nil) { self.id = id; self.name = name; self.muted = muted; self.screen = screen; self.deafened = deafened }
    }
    public struct Entry: Codable, Sendable { public let channelId: String; public let participants: [Occupant] }
    public let rooms: [Entry]
}
public enum EndpointPolicy {
    public static func origin(_ value: String) throws -> URL {
        guard let c = URLComponents(string: value), c.scheme == "https", c.host != nil,
              c.user == nil, c.password == nil, c.query == nil, c.fragment == nil,
              c.path.isEmpty || c.path == "/", let url = c.url else { throw RoomsError.invalidEndpoint }
        return url
    }
    public static func gateway(_ value: String, origin: URL) throws -> URL {
        guard var c = URLComponents(string: value), c.scheme == "wss", c.host == origin.host,
              c.port == origin.port, c.user == nil, c.password == nil, c.fragment == nil else { throw RoomsError.invalidEndpoint }
        c.queryItems = [URLQueryItem(name: "format", value: "json"), URLQueryItem(name: "version", value: "1")]
        guard let url = c.url else { throw RoomsError.invalidEndpoint }; return url
    }
    public static func media(_ value: String) throws -> String {
        guard let c = URLComponents(string: value), c.scheme == "wss", c.host != nil,
              c.user == nil, c.password == nil, c.query == nil, c.fragment == nil else { throw RoomsError.invalidEndpoint }
        return value
    }
    public static func id(_ value: String) throws -> String {
        guard value.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil else { throw RoomsError.invalidResponse }
        return value
    }
}
/// An operation may update state only while it owns the current generation.
public struct OperationEpoch: Sendable {
    private var value: UInt64 = 0
    public init() {}
    @discardableResult public mutating func advance() -> UInt64 { value &+= 1; return value }
    public func advanceForRead() -> UInt64 { value }
    public func owns(_ ticket: UInt64) -> Bool { value == ticket }
}
public struct ScreenSelection: Sendable, Equatable {
    public enum State: Sendable { case idle, loading, playing, ended, failed }
    public private(set) var id: String?
    public private(set) var state: State = .idle
    public init() {}
    public mutating func select(_ id: String?) { self.id = id; state = id == nil ? .idle : .loading }
    public mutating func reconcile(available: Set<String>, subscribed: Set<String>) {
        guard let id else { return }
        if !available.contains(id) { self.id = nil; state = .ended }
        else if subscribed.contains(id) { state = .playing }
    }
    public mutating func fail() { id = nil; state = .failed }
    public func wants(source: String, publicationID: String, presenterScreenID: String?, foreground: Bool) -> Bool {
        if source == "microphone" { return true }
        return foreground && id != nil && presenterScreenID == id && ["screen_share", "screen_share_audio"].contains(source)
    }
}

public func withTimeout<T: Sendable>(seconds: Double = 25, operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask { try await Task.sleep(for: .seconds(seconds)); throw RoomsError.timeout }
        defer { group.cancelAll() }
        guard let result = try await group.next() else { throw CancellationError() }; return result
    }
}
