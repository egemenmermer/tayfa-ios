import Foundation

// MARK: Sign-in with a second factor, and invite redemption
//
// Stoat (`POST /api/auth/session/login`) answers an account with MFA with
// `{"result":"MFA","ticket":"…","allowed_methods":["Totp","Recovery",…]}` instead of a session token.
// The second step posts the same endpoint with `mfa_ticket` and an `mfa_response`
// (`{"totp_code":"123456"}` or `{"recovery_code":"…"}`).
//
// Invitations follow the desktop adapter (`packages/stoat-adapter`, `acceptInvite`): a Tayfa token
// (32+ characters, 64 hex for broker links) is redeemed through the access service at
// `/rooms-access/v1/auth/invites/<code>/join`; a short upstream Stoat code uses `POST /api/invites/<code>`.

/// Second-factor methods Stoat can offer for a login ticket.
public enum MFAMethod: String, Equatable, Sendable {
    case totp = "Totp", recovery = "Recovery", password = "Password"
}

/// Result of the first sign-in step.
public enum LoginStep: Equatable, Sendable {
    case success(token: String)
    case mfa(ticket: String, methods: [MFAMethod])
}

/// The second factor the person typed.
public enum MFAResponse: Equatable, Sendable {
    case totp(String), recovery(String)
}

public enum LoginError: Error, LocalizedError, Equatable, Sendable {
    case invalidCredentials, unverifiedAccount, accountDisabled, refused, mfaUnsupported, invalidMFACode, invalidCodeFormat, rateLimited, unavailable, invalidResponse
    public var errorDescription: String? {
        switch self {
        case .invalidCredentials: "E-posta veya şifre hatalı."
        case .unverifiedAccount: "Önce e-posta adresini doğrulaman gerekiyor."
        case .accountDisabled: "Bu hesap devre dışı bırakılmış."
        case .refused: "Bu hesapla şu anda giriş yapılamıyor. Biraz sonra tekrar dene."
        case .mfaUnsupported: "Bu hesabın ek doğrulama yöntemi telefondan desteklenmiyor. Doğrulama uygulaması kodu veya kurtarma kodu gerekir."
        case .invalidMFACode: "Kod kabul edilmedi ya da doğrulama süresi doldu. Kodu kontrol edip tekrar dene; olmazsa geri dönüp yeniden giriş yap."
        case .invalidCodeFormat: "Kodu kontrol et."
        case .rateLimited: "Çok fazla deneme var. Biraz sonra tekrar dene."
        case .unavailable: "Bağlantı kurulamadı. Tekrar dene."
        case .invalidResponse: "Sunucu yanıtı okunamadı."
        }
    }
}

public enum InviteError: Error, LocalizedError, Equatable, Sendable {
    case invalidLink, otherServer, notFound, expired, revoked, full, refused, sessionExpired, rateLimited, unavailable, invalidResponse
    public var errorDescription: String? {
        switch self {
        case .invalidLink: "Davet bağlantısı veya kodu tanınmadı. Bağlantıyı olduğu gibi yapıştır."
        case .otherServer: "Bu davet başka bir sunucuya ait."
        case .notFound: "Davet bulunamadı. Süresi dolmuş ya da iptal edilmiş olabilir."
        case .expired: "Bu davetin süresi dolmuş. Yeni bir bağlantı iste."
        case .revoked: "Bu davet iptal edilmiş. Yeni bir bağlantı iste."
        case .full: "Bu davet bağlantısının kullanım hakkı bitmiş. Yeni bir bağlantı iste."
        case .refused: "Bu topluluğa katılamıyorsun."
        case .sessionExpired: "Oturum sona erdi. Yeniden giriş yap."
        case .rateLimited: "Çok fazla deneme var. Biraz sonra tekrar dene."
        case .unavailable: "Bağlantı kurulamadı. Tekrar dene."
        case .invalidResponse: "Sunucu yanıtı okunamadı."
        }
    }
}

public struct InviteRedemption: Equatable, Sendable {
    /// Community name when the server reports it.
    public let communityName: String?
}

/// Reads what a person pastes into "Davet kodu gir": a share link, an app link or a bare code.
public enum InviteInput {
    private static let token = "^[a-f0-9]{64}$"
    private static let code = "^[A-Za-z0-9_-]{2,128}$"
    private static func matches(_ value: String, _ pattern: String) -> Bool { value.range(of: pattern, options: .regularExpression) != nil }
    private static func sameServer(_ other: URL, as origin: URL) -> Bool {
        other.scheme == origin.scheme && other.host?.lowercased() == origin.host?.lowercased() && (other.port ?? 443) == (origin.port ?? 443)
    }

    /// Returns the invitation code. `https://<server>/davet/<64 hex>` and
    /// `rooms://invite?server=…&code=…` must name this app's server; a bare code is taken as is.
    public static func code(from raw: String, origin: URL) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
        guard !value.isEmpty, value.count <= 4096 else { throw InviteError.invalidLink }
        if matches(value, code) { return value }
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased(),
              url.user == nil, url.password == nil else { throw InviteError.invalidLink }
        if scheme == "https" {
            // Messengers append tracking parameters or a fragment; only the path token matters.
            let parts = url.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard parts.count == 2, parts[0] == "davet", matches(parts[1], token) else { throw InviteError.invalidLink }
            guard sameServer(url, as: origin) else { throw InviteError.otherServer }
            return parts[1]
        }
        if scheme == "rooms" {
            guard url.host == "invite", let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { throw InviteError.invalidLink }
            let servers = items.filter { $0.name == "server" }, codes = items.filter { $0.name == "code" }
            guard servers.count == 1, codes.count == 1, let server = servers[0].value, let invite = codes[0].value, matches(invite, code),
                  let serverURL = URL(string: server) else { throw InviteError.invalidLink }
            guard sameServer(serverURL, as: origin) else { throw InviteError.otherServer }
            return invite
        }
        throw InviteError.invalidLink
    }
}

extension APIClient {
    /// First step: email and password. Returns a token, or an MFA ticket when the account needs a second factor.
    public static func loginStep(origin: URL, email: String, password: String, session: URLSession? = nil) async throws -> LoginStep {
        let api = APIClient(origin: origin, session: session)
        return try parseLogin(await api.loginRequest(["email": .string(email), "password": .string(password), "friendly_name": .string("ROOMS iPhone")]))
    }

    /// Second step: the ticket from `loginStep` plus a TOTP or recovery code.
    public static func completeMFA(origin: URL, ticket: String, response: MFAResponse, session: URLSession? = nil) async throws -> String {
        guard !ticket.isEmpty, ticket.count <= 512 else { throw LoginError.invalidResponse }
        let answer: JSONValue
        switch response {
        case .totp(let value):
            let digits = value.filter { !$0.isWhitespace }
            guard digits.count >= 6, digits.count <= 8, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber) else { throw LoginError.invalidCodeFormat }
            answer = .object(["totp_code": .string(digits)])
        case .recovery(let value):
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.count <= 64 else { throw LoginError.invalidCodeFormat }
            answer = .object(["recovery_code": .string(trimmed)])
        }
        let api = APIClient(origin: origin, session: session)
        let step = try parseLogin(await api.loginRequest(["mfa_ticket": .string(ticket), "mfa_response": answer, "friendly_name": .string("ROOMS iPhone")]), second: true)
        guard case .success(let token) = step else { throw LoginError.invalidResponse }
        return token
    }

    private func loginRequest(_ body: [String: JSONValue]) async throws -> (Int, JSONValue) {
        try Task.checkCancellation()
        guard let url = URL(string: "/api/auth/session/login", relativeTo: origin)?.absoluteURL, url.host == origin.host else { throw LoginError.unavailable }
        var request = URLRequest(url: url); request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(JSONValue.object(body))
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch { if Task.isCancelled { throw CancellationError() }; throw LoginError.unavailable }
        guard let http = response as? HTTPURLResponse, data.count <= 65536 else { throw LoginError.invalidResponse }
        return (http.statusCode, (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .null)
    }

    private static func parseLogin(_ reply: (Int, JSONValue), second: Bool = false) throws -> LoginStep {
        let (status, body) = reply
        guard (200..<300).contains(status) else {
            let type = body["type"].string ?? ""
            switch status {
            case 429: throw LoginError.rateLimited
            case 401 where type == "UnverifiedAccount": throw LoginError.unverifiedAccount
            case 401: throw second ? LoginError.invalidMFACode : LoginError.invalidCredentials
            case 400 where second: throw LoginError.invalidMFACode
            case 403: throw type == "Disabled" ? LoginError.accountDisabled : LoginError.refused
            case 500...599: throw LoginError.unavailable
            default: throw second ? LoginError.invalidMFACode : LoginError.refused
            }
        }
        if let token = body["token"].string, !token.isEmpty { return .success(token: token) }
        if body["result"].string == "Disabled" { throw LoginError.accountDisabled }
        guard !second, let ticket = body["ticket"].string, !ticket.isEmpty else { throw LoginError.invalidResponse }
        let methods = body["allowed_methods"].array.compactMap { $0.string.flatMap(MFAMethod.init(rawValue:)) }
        guard methods.contains(.totp) || methods.contains(.recovery) else { throw LoginError.mfaUnsupported }
        return .mfa(ticket: ticket, methods: methods)
    }

    /// Joins the community behind an invitation, as the desktop does (`InviteInput.code(from:origin:)` first).
    public func redeemInvite(code: String) async throws -> InviteRedemption {
        guard code.range(of: "^[A-Za-z0-9_-]{2,128}$", options: .regularExpression) != nil else { throw InviteError.invalidLink }
        let broker = code.count >= 32
        let (status, body) = try await inviteRequest(path: broker ? "/rooms-access/v1/auth/invites/\(code)/join" : "/api/invites/\(code)", broker: broker)
        // Stoat refuses a second join with 409 AlreadyInServer; for the person that is the goal reached.
        if status == 409, body["type"].string == "AlreadyInServer" { return InviteRedemption(communityName: nil) }
        guard (200..<300).contains(status) else { throw Self.inviteError(status: status, body: body) }
        // Broker: {space:{name}}; upstream Stoat: {type:"Server", server:{name}}.
        let name = body["space"]["name"].string ?? body["server"]["name"].string
        return InviteRedemption(communityName: name?.isEmpty == false ? name : nil)
    }

    private func inviteRequest(path: String, broker: Bool) async throws -> (Int, JSONValue) {
        try Task.checkCancellation()
        guard let token, let url = URL(string: path, relativeTo: origin)?.absoluteURL, url.host == origin.host else { throw InviteError.sessionExpired }
        var request = URLRequest(url: url, timeoutInterval: 20); request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if broker { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") } else { request.setValue(token, forHTTPHeaderField: "x-session-token") }
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch { if Task.isCancelled { throw CancellationError() }; throw InviteError.unavailable }
        guard let http = response as? HTTPURLResponse, data.count <= 2_097_152 else { throw InviteError.invalidResponse }
        return (http.statusCode, (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .null)
    }

    static func inviteError(status: Int, body: JSONValue) -> InviteError {
        // The access service answers `{error: CODE}`; Stoat answers `{type: Name}`.
        switch body["error"].string ?? body["type"].string ?? "" {
        case "INVITE_NOT_FOUND", "NotFound": return .notFound
        case "INVITE_EXPIRED": return .expired
        case "INVITE_REVOKED": return .revoked
        case "INVITE_ALREADY_CLAIMED": return .full
        case "INVITE_UNAVAILABLE", "Banned", "TooManyServers": return .refused
        default: break
        }
        switch status {
        case 401: return .sessionExpired
        case 404: return .notFound
        case 403: return .refused
        case 429: return .rateLimited
        default: return .unavailable
        }
    }
}
