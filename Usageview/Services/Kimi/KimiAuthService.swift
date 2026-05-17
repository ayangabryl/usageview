import Foundation
import Security

struct KimiAccountInfo: Sendable {
    var name: String?
}

@Observable
@MainActor
final class KimiAuthService: Sendable {

    // MARK: - Multi-Account Auth

    func isAuthenticated(for accountId: UUID) -> Bool {
        loadToken(key: apiKey(for: accountId)) != nil
    }

    /// Import kimi-auth from a browser where you are signed in at kimi.com.
    func saveFromBrowser(for accountId: UUID) throws -> KimiAccountInfo {
        let session = try KimiCookieImporter.importSession()
        guard let token = session.authToken else {
            throw KimiCookieImportError.noCookies
        }
        return saveAPIKey(token, for: accountId, sourceLabel: session.sourceLabel)
    }

    /// Store the user-provided API key
    func saveAPIKey(_ key: String, for accountId: UUID) -> KimiAccountInfo {
        saveAPIKey(key, for: accountId, sourceLabel: nil)
    }

    private func saveAPIKey(_ key: String, for accountId: UUID, sourceLabel: String?) -> KimiAccountInfo {
        saveToken(key: apiKey(for: accountId), value: key)
        // Mask the key for display: show first 8 chars + "..."
        let masked: String
        if let sourceLabel {
            masked = sourceLabel
        } else {
            masked = key.count > 8 ? String(key.prefix(8)) + "..." : key
        }
        return KimiAccountInfo(name: masked)
    }

    /// Retrieve the stored API key
    func getAPIKey(for accountId: UUID) -> String? {
        loadToken(key: apiKey(for: accountId))
    }

    func disconnect(accountId: UUID) {
        removeToken(key: apiKey(for: accountId))
    }

    // MARK: - Key Helpers

    private func apiKey(for id: UUID) -> String {
        "com.ayangabryl.usage.kimi-apikey-\(id.uuidString)"
    }

    // MARK: - Keychain Storage

    private func saveToken(key: String, value: String) { KeychainHelper.save(value, forKey: key) }
    private func loadToken(key: String) -> String? { KeychainHelper.load(forKey: key) }
    private func removeToken(key: String) { KeychainHelper.remove(forKey: key) }
}
