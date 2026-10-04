import Foundation
import Security

enum Keychain {
    private static func base(_ k: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: k]
    }
    static func set(_ v: String, _ k: String) {
        SecItemDelete(base(k) as CFDictionary)
        var q = base(k)
        q[kSecValueData as String] = Data(v.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(q as CFDictionary, nil)
    }
    static func get(_ k: String) -> String? {
        var q = base(k)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    static func remove(_ k: String) { SecItemDelete(base(k) as CFDictionary) }
}
