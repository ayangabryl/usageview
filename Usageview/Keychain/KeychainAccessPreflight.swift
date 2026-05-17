import Foundation
import Security

/// Non-interactive Keychain probe before attempting credential reads (CodexBar `KeychainAccessPreflight`).
enum KeychainAccessPreflight {
    enum Outcome: Sendable, Equatable {
        case allowed
        case interactionRequired
        case notFound
        case failure(Int)
    }

    static func checkGenericPassword(service: String, account: String? = nil) -> Outcome {
        guard !KeychainAccessGate.isDisabled else { return .notFound }

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true,
        ]
        if let account {
            query[kSecAttrAccount as String] = account
        }
        KeychainNoUIQuery.apply(to: &query)

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return .allowed
        case errSecItemNotFound:
            return .notFound
        case errSecInteractionNotAllowed:
            return .interactionRequired
        default:
            return .failure(Int(status))
        }
    }
}
