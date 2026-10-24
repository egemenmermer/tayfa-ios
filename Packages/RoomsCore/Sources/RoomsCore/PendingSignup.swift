import Foundation
#if canImport(Security)
import Security
#endif

// MARK: Approved sign-up as this phone follows it
//
// Port of the desktop `PendingSignupBroker` (`apps/desktop/electron/signup-broker.ts`): the poll secret and, after
// approval, the single-use registration code are kept in the Keychain; the password lives only in memory and is never
// written down or sent before approval. A request the service forgets (3 × 404 in a row) is closed; a new request
// withdraws the one this phone followed before; a 409 for the same email withdraws it and asks once more.

/// What the waiting screen shows. `unknown` = not asked yet this launch, or a transient error.
public enum SignupPhase: String, Equatable, Sendable {
    case unknown, pending, approved, issued, rejected, expired, closed
    public var waiting: Bool { self == .pending || self == .unknown }
}

public struct PendingSignupSnapshot: Equatable, Sendable {
    public let email: String
    public let username: String
    public let createdAt: String?
    public let phase: SignupPhase
    /// The approval code is on this phone: the account can be created.
    public let ready: Bool
    /// The password typed with the request is still in memory (no need to ask for it).
    public let passwordKnown: Bool
    /// Whether the request survives an app restart (false: the Keychain refused it).
    public let persisted: Bool
    public let error: String?
}

/// The approved code (or a share link's code) plus the credentials, ready for `APIClient.register`.
public struct SignupRegistration: Equatable, Sendable {
    public let email: String
    public let password: String
    public let username: String
    public let inviteCode: String
}

/// Result of asking the service once.
public enum SignupProgress: Equatable, Sendable {
    /// No request on this phone.
    case none
    case waiting(PendingSignupSnapshot)
    /// The account exists; sign in with this token.
    case registered(token: String, email: String)
}

/// The access-service calls approved sign-up needs; `APIClient` provides them (`LiveSignupService`).
public protocol SignupService: Sendable {
    func requestSignup(email: String, username: String) async throws -> SignupTicket
    func signupStatus(requestId: String, pollSecret: String) async throws -> SignupPoll
    func cancelSignup(requestId: String, pollSecret: String) async throws
    func register(email: String, password: String, username: String, inviteCode: String) async throws -> String
}
extension APIClient: SignupService {}

/// Secret storage for the request record (Keychain on the phone, memory in tests).
public protocol SignupRecordStore: Sendable {
    func load() throws -> Data?
    func save(_ data: Data) throws
    func clear()
}

/// Consecutive "unknown request" answers before the waiting screen gives up on a request.
public let signupNotFoundLimit = 3

/// Poll cadence while the waiting screen is in the foreground: 30 s like desktop, doubling after failures up to 5 min.
public enum SignupPollSchedule {
    public static let base: TimeInterval = 30
    public static let maximum: TimeInterval = 300
    public static func delay(afterFailures failures: Int) -> TimeInterval {
        guard failures > 0 else { return base }
        return min(maximum, base * pow(2, Double(min(failures, 8))))
    }
}

struct SignupRecord: Codable, Equatable {
    var version = 1
    var origin: String
    var requestId: String
    var pollSecret: String
    var email: String
    var username: String
    var createdAt: String?
    /// Delivered by the service on approval; kept until the account exists.
    var inviteCode: String?
    var valid: Bool {
        version == 1 && SignupPattern.matches(requestId, SignupPattern.requestId) && SignupPattern.matches(pollSecret, SignupPattern.pollSecret)
            && SignupInput.email(email) != nil && SignupInput.username(username) != nil
            && (inviteCode.map { SignupPattern.matches($0, SignupPattern.approvalCode) } ?? true)
    }
}

public actor PendingSignupBroker {
    private let origin: URL
    private let store: SignupRecordStore
    private let service: SignupService
    private let now: @Sendable () -> Date
    private var current: SignupRecord?
    private var password: String?
    private var phase: SignupPhase = .unknown
    private var error: String?
    private var saved = false
    private var loaded = false
    private var notFound = 0

    public init(origin: URL, store: SignupRecordStore, service: SignupService, now: @escaping @Sendable () -> Date = Date.init) {
        self.origin = origin; self.store = store; self.service = service; self.now = now
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? store.load() else { return }
        guard let record = try? JSONDecoder().decode(SignupRecord.self, from: data), record.valid, record.origin == origin.absoluteString else {
            // Unreadable or for another server: it can never be followed from here.
            store.clear(); return
        }
        current = record; saved = true
        phase = record.inviteCode == nil ? .unknown : .approved
    }

    /// Writes the record (never the password); returns whether it is stored.
    @discardableResult private func persist() -> Bool {
        saved = false
        guard let current else { store.clear(); return false }
        do { try store.save(JSONEncoder().encode(current)); saved = true } catch {
            // Followed in memory only; the snapshot says so and the screen warns.
        }
        return saved
    }

    public func snapshot() -> PendingSignupSnapshot? {
        load()
        guard let current else { return nil }
        return PendingSignupSnapshot(email: current.email, username: current.username, createdAt: current.createdAt, phase: phase,
                                     ready: current.inviteCode != nil, passwordKnown: password != nil, persisted: saved, error: error)
    }

    /// Sends a new request. Inputs must already pass `SignupInput`.
    public func request(email: String, password: String, username: String) async throws -> PendingSignupSnapshot {
        load()
        let previous = current
        let sameEmail = previous.map { $0.email.lowercased() == email.lowercased() } ?? false
        let ticket: SignupTicket
        var withdrawn = false
        do { ticket = try await service.requestSignup(email: email, username: username) }
        catch SignupError.alreadyRequested where sameEmail {
            // One open request per address: free the one this phone holds and ask once more.
            await withdraw(previous!); withdrawn = true
            ticket = try await service.requestSignup(email: email, username: username)
        }
        // A newer request replaces the old one, which is withdrawn so nobody approves a code that can't be claimed.
        if let previous, !withdrawn { await withdraw(previous) }
        notFound = 0
        current = SignupRecord(origin: origin.absoluteString, requestId: ticket.requestId, pollSecret: ticket.pollSecret, email: email,
                               username: username, createdAt: ISO8601DateFormatter().string(from: now()), inviteCode: nil)
        self.password = password
        phase = .pending; error = nil
        persist()
        return snapshot()!
    }

    private func withdraw(_ record: SignupRecord) async {
        try? await service.cancelSignup(requestId: record.requestId, pollSecret: record.pollSecret)
    }

    /// Asks the service once. When approved and the password is still in memory, creates the account.
    public func check() async -> SignupProgress {
        load()
        guard let record = current else { return .none }
        if record.inviteCode == nil && phase != .closed {
            do {
                let poll = try await service.signupStatus(requestId: record.requestId, pollSecret: record.pollSecret)
                guard current == record else { return progress() }
                phase = SignupPhase(rawValue: poll.status.rawValue) ?? .unknown
                error = nil; notFound = 0
                if let created = poll.createdAt { current?.createdAt = created }
                if poll.status == .approved, let code = poll.inviteCode {
                    // Older services hand the code out once: store it before anything else.
                    current?.inviteCode = code
                    persist()
                }
            } catch {
                guard current == record else { return progress() }
                if error as? SignupError == .requestNotFound {
                    notFound += 1
                    phase = notFound >= signupNotFoundLimit ? .closed : .unknown
                    if phase == .closed { self.error = nil; return progress() }
                }
                if error is CancellationError { return progress() }
                self.error = (error as? LocalizedError)?.errorDescription ?? SignupError.unavailable.errorDescription
                return progress()
            }
        }
        guard let registration = registration() else { return progress() }
        do { return try await complete(registration) } catch { return progress() }
    }

    /// Creates the account after approval with the typed password (the app restarted since the request).
    public func complete(email: String?, password: String) async throws -> SignupProgress {
        guard let registration = registration(email: email, password: password) else { throw SignupError.requestNotFound }
        return try await complete(registration)
    }

    private func complete(_ registration: SignupRegistration) async throws -> SignupProgress {
        let token: String
        do { token = try await service.register(email: registration.email, password: registration.password, username: registration.username, inviteCode: registration.inviteCode) }
        catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? SignupError.unavailable.errorDescription
            // A wrong password guess is not kept for the next attempt.
            password = nil
            throw error
        }
        // The account exists and the code is spent: forget everything now, so a failed sign-in afterwards cannot leave
        // a request that only fails again.
        completed()
        return .registered(token: token, email: registration.email)
    }

    func registration(email: String? = nil, password typed: String? = nil) -> SignupRegistration? {
        load()
        guard var record = current, let code = record.inviteCode else { return nil }
        if let email = email.flatMap(SignupInput.email) { record.email = email; current?.email = email }
        if let typed, !typed.isEmpty { password = typed }
        guard let password else { return nil }
        return SignupRegistration(email: record.email, password: password, username: record.username, inviteCode: code)
    }

    private func progress() -> SignupProgress { snapshot().map(SignupProgress.waiting) ?? .none }

    /// The account exists: forget the request and the password.
    public func completed() {
        current = nil; password = nil; phase = .unknown; notFound = 0; error = nil
        persist()
    }

    /// Withdraws the request on the server (best effort) and forgets it here.
    public func cancel() async {
        load()
        let record = current
        completed()
        if let record { await withdraw(record) }
    }
}

#if canImport(Security)
/// The request record as one generic-password Keychain item, readable after first unlock on this device only.
/// Its own account name, so signing out (which clears the session item) never touches it.
public struct KeychainSignupStore: SignupRecordStore {
    private let service: String
    private let account: String
    public init(service: String, account: String = "signup-request-v1") { self.service = service; self.account = account }
    private var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    public func load() throws -> Data? {
        var query = base; query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw SignupError.unavailable }
        return data
    }
    public func save(_ data: Data) throws {
        let status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var query = base; query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else { throw SignupError.unavailable }
        } else if status != errSecSuccess { throw SignupError.unavailable }
    }
    public func clear() { SecItemDelete(base as CFDictionary) }
}
#endif
