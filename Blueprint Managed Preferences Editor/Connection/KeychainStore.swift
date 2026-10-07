import Foundation
import Security

/// Stores client secrets as generic passwords in the login Keychain.
nonisolated enum KeychainStore {
    private static let service = "Blueprint Managed Preferences Editor.client-secret"

    struct KeychainError: Error, LocalizedError {
        let status: OSStatus
        var errorDescription: String? {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown error"
            return "Keychain error \(status): \(message)"
        }
    }

    private static func baseQuery(for profileID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profileID.uuidString,
        ]
    }

    static func secret(for profileID: UUID) -> String? {
        var query = baseQuery(for: profileID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func setSecret(_ secret: String, for profileID: UUID) throws {
        let data = Data(secret.utf8)
        let query = baseQuery(for: profileID)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrLabel as String] = "Blueprint Managed Preferences Editor client secret"
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }

    static func deleteSecret(for profileID: UUID) {
        SecItemDelete(baseQuery(for: profileID) as CFDictionary)
    }
}
