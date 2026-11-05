import Foundation
import Security

/// Thin wrapper over the macOS Keychain. All secrets (API keys, OAuth tokens) live here and nowhere else.
public enum Keychain {
    /// Self-checks switch this so they never touch the app's real keys.
    nonisolated(unsafe) public static var service = ProcessInfo.processInfo.environment["EVERYDAY_DEV"] == "1" ? "everyday.dev" : "everyday."

    public enum KeychainError: Error, LocalizedError {
        case status(OSStatus)
        public var errorDescription: String? {
            if case .status(let s) = self { return (SecCopyErrorMessageString(s, nil) as String?) ?? "Keychain error \(s)" }
            return nil
        }
    }

    public static func set(_ value: String, for account: String) throws {
        let data = Data(value.utf8)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemCopyMatching(base as CFDictionary, nil)
        if status == errSecSuccess {
            let upd = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if upd != errSecSuccess { throw KeychainError.status(upd) }
        } else {
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let s = SecItemAdd(add as CFDictionary, nil)
            if s != errSecSuccess { throw KeychainError.status(s) }
        }
    }

    public static func get(_ account: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    public static func delete(_ account: String) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(q as CFDictionary)
    }
}

public enum KeychainAccount {
    public static func aiKey(_ provider: String) -> String { "ai.\(provider).apiKey" }
    public static let googleClientSecret = "google.oauth.clientSecret"
    public static func googleRefreshToken(_ email: String) -> String { "google.refresh.\(email)" }
}
