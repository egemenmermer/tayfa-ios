import Foundation

/// Reconnect delays for the gateway and the offline session restore: 1, 2, 4, 8 s, then the cap.
/// Retrying never stops on its own; only a sign-out, expiry or background stop ends it.
public enum ReconnectBackoff {
    public static let gatewayCap: Double = 10
    public static let restoreCap: Double = 30
    /// `failures` counts consecutive failed attempts (1 for the first failure).
    /// `jitter` in 0...1 shortens the delay by up to 20% so many phones do not reconnect in step.
    public static func delay(failures: Int, cap: Double = gatewayCap, jitter: Double = 0) -> Double {
        guard failures > 0 else { return 0 }
        let base = min(pow(2, Double(min(failures, 16) - 1)), cap)
        return base * (1 - 0.2 * min(max(jitter, 0), 1))
    }
}

/// What a failed cold-launch restore means for the saved session.
public enum SessionRestoreOutcome: Equatable, Sendable {
    /// The server rejected the token: forget it and show the login form.
    case signedOut
    /// The server could not be reached (or answered unusably): keep the token and retry.
    case retry
    public init(error: Error) {
        self = (error as? RoomsError) == .expired ? .signedOut : .retry
    }
}

/// A session the person signed out of while the server could not be reached. Its token stays in
/// the Keychain until the server confirms the session is gone, so the old account's push
/// subscription does not outlive the sign-out.
public struct PendingLogout: Codable, Equatable, Sendable {
    public let origin: String
    public let token: String
    public init(origin: String, token: String) { self.origin = origin; self.token = token }

    /// Whether a logout attempt that failed with `error` is finished (the session is gone or will
    /// never be accepted) or must be retried later.
    public static func isFinished(after error: Error) -> Bool {
        switch error as? RoomsError {
        case .expired?, .denied?, .invalidEndpoint?: true
        default: false
        }
    }
}

/// The ordered queue of sessions still to end on the server. Capped so a broken server cannot grow it.
public struct PendingLogoutQueue: Codable, Equatable, Sendable {
    public static let limit = 5
    public private(set) var items: [PendingLogout] = []
    public init(items: [PendingLogout] = []) { self.items = Array(items.suffix(Self.limit)) }
    public var isEmpty: Bool { items.isEmpty }
    public mutating func add(_ item: PendingLogout) {
        guard !item.token.isEmpty else { return }
        items.removeAll { $0 == item }; items.append(item)
        if items.count > Self.limit { items.removeFirst(items.count - Self.limit) }
    }
    public mutating func remove(_ item: PendingLogout) { items.removeAll { $0 == item } }
}

extension APIClient {
    /// Ends this session on the server and throws when that could not be confirmed (unlike `logout()`).
    /// The push subscription is dropped first on a best-effort basis; ending the session removes it as well.
    public func endSession() async throws {
        _ = try? await request(path: "/api/push/unsubscribe", method: "POST")
        _ = try await request(path: "/api/auth/session/logout", method: "POST")
    }
}
