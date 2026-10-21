import Foundation
import Security
import RoomsCore

enum SessionVault {
    struct SavedSession: Codable { let origin: String; let token: String }
    private static let service = "com.egemenmermer.rooms.mobile.session"
    private static var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "stoat"] }
    static func read(origin: URL) throws -> String? {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let result = SecItemCopyMatching(q as CFDictionary, &item)
        if result == errSecItemNotFound { return nil }
        guard result == errSecSuccess, let data = item as? Data else { throw RoomsError.unavailable }
        let saved = try JSONDecoder().decode(SavedSession.self, from: data)
        guard saved.origin == origin.absoluteString else { return nil }
        return saved.token
    }
    static func save(_ token: String, origin: URL) throws {
        let data = try JSONEncoder().encode(SavedSession(origin: origin.absoluteString, token: token))
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query; q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { throw RoomsError.unavailable }
        } else if status != errSecSuccess { throw RoomsError.unavailable }
    }
    static func clear() { SecItemDelete(query as CFDictionary) }
}
