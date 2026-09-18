import Foundation
import Security

enum Prefs {
    static let devModeKey = "devMode"
    static var devMode: Bool { UserDefaults.standard.bool(forKey: devModeKey) }
}

/// TypeSafe API key in the login keychain (generic password, one item).
enum Keychain {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "dev.rongxin.smartswitch",
        kSecAttrAccount as String: "typesafe-api-key",
    ]

    static var apiKey: String? {
        get {
            var q = query
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var out: AnyObject?
            guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
                  let data = out as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }
        set {
            let value = newValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            SecItemDelete(query as CFDictionary)
            guard !value.isEmpty else { return }
            var q = query
            q[kSecValueData as String] = Data(value.utf8)
            SecItemAdd(q as CFDictionary, nil)
        }
    }
}
