import Foundation
import Security
import RoomsCore

enum SessionVault {
    struct SavedSession: Codable { let origin: String; let token: String }
    private static let service = "com.egemenmermer.rooms.mobile.session"
    private static var query: [String: Any] { query(account: "stoat") }
    /// Sessions signed out while offline; a separate item so `clear()` and `read` never touch it.
    private static var pendingQuery: [String: Any] { query(account: "stoat-pending-logout") }
    private static func query(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    static func read(origin: URL) throws -> String? {
        guard let data = try readData(query) else { return nil }
        // An unreadable item can never restore; dropping it shows the login form instead of retrying forever.
        guard let saved = try? JSONDecoder().decode(SavedSession.self, from: data) else { clear(); return nil }
        guard saved.origin == origin.absoluteString else { return nil }
        return saved.token
    }
    static func save(_ token: String, origin: URL) throws {
        try write(JSONEncoder().encode(SavedSession(origin: origin.absoluteString, token: token)), to: query)
    }
    static func clear() { SecItemDelete(query as CFDictionary) }

    // MARK: Pending logout (B4)
    static func pendingLogouts() -> PendingLogoutQueue {
        guard let data = try? readData(pendingQuery), let queue = try? JSONDecoder().decode(PendingLogoutQueue.self, from: data) else { return PendingLogoutQueue() }
        return queue
    }
    /// Remembers a session to end on the server later. Throws if the Keychain refused it.
    static func addPendingLogout(token: String, origin: URL) throws {
        var queue = pendingLogouts(); queue.add(PendingLogout(origin: origin.absoluteString, token: token))
        try storePending(queue)
    }
    static func removePendingLogout(_ item: PendingLogout) {
        var queue = pendingLogouts(); queue.remove(item)
        try? storePending(queue)
    }
    private static func storePending(_ queue: PendingLogoutQueue) throws {
        if queue.isEmpty { SecItemDelete(pendingQuery as CFDictionary); return }
        try write(JSONEncoder().encode(queue), to: pendingQuery)
    }

    private static func readData(_ base: [String: Any]) throws -> Data? {
        var q = base; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let result = SecItemCopyMatching(q as CFDictionary, &item)
        if result == errSecItemNotFound { return nil }
        guard result == errSecSuccess, let data = item as? Data else { throw RoomsError.unavailable }
        return data
    }
    private static func write(_ data: Data, to base: [String: Any]) throws {
        let status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = base; q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { throw RoomsError.unavailable }
        } else if status != errSecSuccess { throw RoomsError.unavailable }
    }
}
