import Foundation

// MARK: Sign-up: approved requests and invitation registration
//
// Mirrors the desktop adapter (`packages/stoat-adapter`, `requestSignup` / `signupStatus` / `cancelSignup` /
// `register`) against the access service:
// - `GET  /rooms-access/v1/auth/signup` → `{enabled}`; 404 on services from before approved sign-up.
// - `POST /rooms-access/v1/auth/signup-requests` `{email, username}` → `{requestId, pollSecret}`. No account exists yet.
// - `GET  /rooms-access/v1/auth/signup-requests/<id>` with `Authorization: Bearer <pollSecret>` →
//   `{status, inviteCode?, createdAt, expiresAt}`. Approved requests carry a single-use 64-hex registration code.
// - `DELETE /rooms-access/v1/auth/signup-requests/<id>` with the same bearer withdraws the request.
// - `POST /rooms-access/v1/auth/register` `{email, password, username, inviteCode}` → `{token}` (a Stoat session token).
// The service validates bodies strictly: extra keys are refused with 400 INVALID_INPUT.

public enum SignupError: Error, LocalizedError, Equatable, Sendable {
    /// The server does not accept requests without an invitation (or predates approved sign-up).
    case notOffered
    /// This email already has an open request (409).
    case alreadyRequested
    case busy, queueFull
    /// The service does not know this request (404): withdrawn, pruned or lost.
    case requestNotFound
    /// The email already has an account.
    case emailTaken
    /// The account may or may not exist (timeout or a dropped connection during registration).
    case uncertain
    case invalidInput, weakPassword, invalidUsername, provisioningUnavailable
    case invite(InviteError)
    case rateLimited, unavailable, invalidResponse

    public var errorDescription: String? {
        switch self {
        case .notOffered: "Bu sunucu davetsiz kaydı açmamış. Topluluktan bir davet bağlantısı iste."
        case .alreadyRequested: "Bu e-posta adresi için onay bekleyen bir kayıt isteği zaten var."
        case .busy: "Şu anda çok kişi kayıt oluyor. Biraz sonra tekrar dene."
        case .queueFull: "Onay bekleyen çok fazla kayıt isteği var. Biraz sonra tekrar dene."
        case .requestNotFound: "Bu kayıt isteği artık açık değil."
        case .emailTaken: "Bu e-posta adresinin zaten bir hesabı var. Onunla giriş yap ya da başka bir e-posta adresi kullan."
        case .uncertain: "Hesap oluşturma doğrulanamadı. Yeniden denemeden önce bu e-posta ve şifreyle giriş yapmayı dene."
        case .invalidInput: "Bilgileri kontrol edip tekrar dene."
        case .weakPassword: "Bu şifre kabul edilmedi. Daha uzun ve tahmin edilmesi zor bir şifre seç."
        case .invalidUsername: "Kullanıcı adı 2–32 karakter olmalı; harf, rakam, nokta, alt çizgi ve tire kullanabilirsin."
        case .provisioningUnavailable: "Bu sunucuda hesap oluşturma şu anda kullanılamıyor. Yöneticine haber ver."
        case .invite(let error): error.errorDescription
        case .rateLimited: "Çok fazla deneme var. Biraz sonra tekrar dene."
        case .unavailable: "Bağlantı kurulamadı. Tekrar dene."
        case .invalidResponse: "Sunucu yanıtı okunamadı."
        }
    }
}

/// Where a request stands on the server.
public enum SignupStatus: String, Equatable, Sendable, Codable {
    case pending, approved, issued, rejected, expired
}

public struct SignupTicket: Equatable, Sendable {
    public let requestId: String
    public let pollSecret: String
}

public struct SignupPoll: Equatable, Sendable {
    public let status: SignupStatus
    /// The single-use registration code; only with `approved`.
    public let inviteCode: String?
    public let createdAt: String?
    public let expiresAt: String?
}

/// Client-side checks matching the access service, so a typo never spends one of the 3 hourly requests.
public enum SignupInput {
    public static let minimumPassword = 8
    public static func email(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count <= 254, value.range(of: #"^[^@\s]+@[^@\s]+\.[^@\s]+$"#, options: .regularExpression) != nil else { return nil }
        return value
    }
    public static func username(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (2...32).contains(value.count), value.range(of: #"^[\p{L}\p{N}_.-]+$"#, options: .regularExpression) != nil else { return nil }
        return value
    }
    public static func password(_ raw: String) -> Bool { raw.count >= minimumPassword && raw.count <= 256 }
}

enum SignupPattern {
    static let requestId = "^[a-f0-9]{32}$"
    static let pollSecret = "^[A-Za-z0-9_-]{43}$"
    static let approvalCode = "^[a-f0-9]{64}$"
    static let inviteCode = "^[A-Za-z0-9_-]{2,128}$"
    static func matches(_ value: String, _ pattern: String) -> Bool { value.range(of: pattern, options: .regularExpression) != nil }
}

extension APIClient {
    /// Whether this server takes sign-up requests without an invitation link. Old services answer 404 → false.
    public func signupAvailable() async throws -> Bool {
        let (status, body) = try await signupCall("/rooms-access/v1/auth/signup")
        if status == 404 { return false }
        guard (200..<300).contains(status) else { throw Self.signupError(status: status, body: body) }
        return body["enabled"] == .bool(true)
    }

    /// Queues a request for an admin. Never retried automatically: the service allows 3 per address per hour.
    public func requestSignup(email: String, username: String) async throws -> SignupTicket {
        let (status, body) = try await signupCall("/rooms-access/v1/auth/signup-requests", method: "POST", body: .object(["email": .string(email), "username": .string(username)]))
        if status == 404 { throw SignupError.notOffered }
        guard (200..<300).contains(status) else { throw Self.signupError(status: status, body: body) }
        guard let id = body["requestId"].string, SignupPattern.matches(id, SignupPattern.requestId),
              let secret = body["pollSecret"].string, SignupPattern.matches(secret, SignupPattern.pollSecret) else { throw SignupError.invalidResponse }
        return SignupTicket(requestId: id, pollSecret: secret)
    }

    public func signupStatus(requestId: String, pollSecret: String) async throws -> SignupPoll {
        guard SignupPattern.matches(requestId, SignupPattern.requestId) else { throw SignupError.requestNotFound }
        let (status, body) = try await signupCall("/rooms-access/v1/auth/signup-requests/\(requestId)", secret: pollSecret)
        guard (200..<300).contains(status) else { throw Self.signupError(status: status, body: body) }
        guard let state = body["status"].string.flatMap(SignupStatus.init(rawValue:)) else { throw SignupError.invalidResponse }
        var code: String?
        if state == .approved {
            guard let value = body["inviteCode"].string, SignupPattern.matches(value, SignupPattern.approvalCode) else { throw SignupError.invalidResponse }
            code = value
        }
        return SignupPoll(status: state, inviteCode: code, createdAt: body["createdAt"].string, expiresAt: body["expiresAt"].string)
    }

    public func cancelSignup(requestId: String, pollSecret: String) async throws {
        guard SignupPattern.matches(requestId, SignupPattern.requestId) else { throw SignupError.requestNotFound }
        let (status, body) = try await signupCall("/rooms-access/v1/auth/signup-requests/\(requestId)", method: "DELETE", secret: pollSecret)
        guard (200..<300).contains(status) else { throw Self.signupError(status: status, body: body) }
    }

    /// Creates the account with an invitation (a share link's code or an approved request's code) and returns its
    /// session token. The service also joins the invitation's community. Uses the 60 s session: the server creates
    /// the account, signs in, onboards and joins before it answers.
    public func register(email: String, password: String, username: String, inviteCode: String) async throws -> String {
        guard SignupPattern.matches(inviteCode, SignupPattern.inviteCode) else { throw SignupError.invite(.invalidLink) }
        let body: JSONValue = .object(["email": .string(email), "password": .string(password), "username": .string(username), "inviteCode": .string(inviteCode)])
        let (status, reply) = try await signupCall("/rooms-access/v1/auth/register", method: "POST", body: body, long: true)
        guard (200..<300).contains(status) else { throw Self.signupError(status: status, body: reply, registering: true) }
        guard let token = reply["token"].string, !token.isEmpty, token.count <= 4096 else { throw SignupError.invalidResponse }
        return token
    }

    private func signupCall(_ path: String, method: String = "GET", body: JSONValue? = nil, secret: String? = nil, long: Bool = false) async throws -> (Int, JSONValue) {
        try Task.checkCancellation()
        guard let url = URL(string: path, relativeTo: origin)?.absoluteURL, url.host == origin.host else { throw SignupError.unavailable }
        var request = URLRequest(url: url); request.httpMethod = method
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        if let secret {
            guard SignupPattern.matches(secret, SignupPattern.pollSecret) else { throw SignupError.requestNotFound }
            request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        }
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await (long ? fileSession : session).data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch {
            if Task.isCancelled { throw CancellationError() }
            // Registration may have created the account before the connection dropped.
            throw long ? SignupError.uncertain : SignupError.unavailable
        }
        guard let http = response as? HTTPURLResponse, data.count <= 65536 else { throw SignupError.invalidResponse }
        return (http.statusCode, (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .null)
    }

    static func signupError(status: Int, body: JSONValue, registering: Bool = false) -> SignupError {
        switch body["error"].string ?? "" {
        case "SIGNUP_UNAVAILABLE", "SIGNUP_NOT_ENABLED": return .notOffered
        case "SIGNUP_ALREADY_REQUESTED": return .alreadyRequested
        case "SIGNUP_BUSY", "REGISTRATION_BUSY": return .busy
        case "SIGNUP_QUEUE_FULL": return .queueFull
        case "SIGNUP_REQUEST_NOT_FOUND": return .requestNotFound
        // Upstream answers OperationFailed when the email already has an account.
        case "OperationFailed", "REGISTRATION_REQUIRES_SIGN_IN", "EmailInUse": return .emailTaken
        case "CompromisedPassword", "ShortPassword": return .weakPassword
        case "InvalidUsername", "UsernameTaken": return .invalidUsername
        case "INVALID_INPUT": return .invalidInput
        case "INVITE_PROVISIONING_UNAVAILABLE": return .provisioningUnavailable
        case "INVITE_NOT_FOUND": return .invite(.notFound)
        case "INVITE_EXPIRED": return .invite(.expired)
        case "INVITE_REVOKED": return .invite(.revoked)
        // A retry after a lost answer finds its own single-use code spent: the account may already exist.
        case "INVITE_ALREADY_CLAIMED": return registering ? .uncertain : .invite(.full)
        case "RATE_LIMITED": return .rateLimited
        default: break
        }
        switch status {
        case 400: return .invalidInput
        case 404: return registering ? .invite(.notFound) : .requestNotFound
        case 409: return registering ? .emailTaken : .alreadyRequested
        case 429: return .rateLimited
        case 501: return registering ? .provisioningUnavailable : .notOffered
        default: return .unavailable
        }
    }
}
