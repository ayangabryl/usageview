import Foundation

struct CodexAccountInfo: Sendable {
    var name: String?
}

@Observable
@MainActor
final class CodexAuthService: Sendable {

    func isAuthenticated(for accountId: UUID) -> Bool {
        loadToken(key: tokenKey(for: accountId)) != nil || (try? loadCLIAuth()) != nil
    }

    /// Import OAuth token from `~/.codex/auth.json` (Codex CLI login).
    func connectFromCLI(for accountId: UUID) throws -> CodexAccountInfo {
        let creds = try loadCLIAuth()
        saveToken(key: tokenKey(for: accountId), value: creds.accessToken)
        let label = creds.accountId.map { "Codex · \($0.prefix(8))…" } ?? "Codex CLI"
        return CodexAccountInfo(name: label)
    }

    func getValidToken(for accountId: UUID) async -> String? {
        if let stored = loadToken(key: tokenKey(for: accountId)) {
            return stored
        }
        if let creds = try? loadCLIAuth() {
            saveToken(key: tokenKey(for: accountId), value: creds.accessToken)
            return creds.accessToken
        }
        return nil
    }

    func chatgptAccountId(for accountId: UUID) -> String? {
        if let stored = loadAccountId(key: accountIdKey(for: accountId)) {
            return stored
        }
        return try? loadCLIAuth().accountId
    }

    func disconnect(accountId: UUID) {
        removeToken(key: tokenKey(for: accountId))
        removeToken(key: accountIdKey(for: accountId))
    }

    // MARK: - CLI auth.json

    struct CLICredentials: Sendable {
        let accessToken: String
        let accountId: String?
    }

    func loadCLIAuth() throws -> CLICredentials {
        let url = Self.authFileURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CodexAuthError.notFound
        }
        let data = try Data(contentsOf: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexAuthError.invalidFile
        }

        if let apiKey = json["OPENAI_API_KEY"] as? String,
           !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return CLICredentials(accessToken: apiKey, accountId: nil)
        }

        guard let tokens = json["tokens"] as? [String: Any],
              let access = tokens["access_token"] as? String ?? tokens["accessToken"] as? String,
              !access.isEmpty
        else {
            throw CodexAuthError.missingTokens
        }
        let accountId = tokens["account_id"] as? String ?? tokens["accountId"] as? String
        return CLICredentials(accessToken: access, accountId: accountId)
    }

    private static func authFileURL() -> URL {
        let env = ProcessInfo.processInfo.environment
        if let codexHome = env["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !codexHome.isEmpty
        {
            return URL(fileURLWithPath: codexHome).appendingPathComponent("auth.json")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json")
    }

    // MARK: - Keychain

    private func tokenKey(for id: UUID) -> String {
        "com.ayangabryl.usage.codex-token-\(id.uuidString)"
    }

    private func accountIdKey(for id: UUID) -> String {
        "com.ayangabryl.usage.codex-account-id-\(id.uuidString)"
    }

    private func saveToken(key: String, value: String) { KeychainHelper.save(value, forKey: key) }
    private func loadToken(key: String) -> String? { KeychainHelper.load(forKey: key) }
    private func removeToken(key: String) { KeychainHelper.remove(forKey: key) }

    private func loadAccountId(key: String) -> String? { KeychainHelper.load(forKey: key) }
}

enum CodexAuthError: LocalizedError {
    case notFound
    case invalidFile
    case missingTokens

    var errorDescription: String? {
        switch self {
        case .notFound:
            "Codex auth.json not found. Run `codex` in Terminal to sign in first."
        case .invalidFile:
            "Could not read Codex auth.json."
        case .missingTokens:
            "Codex auth.json has no tokens. Run `codex` to sign in."
        }
    }
}
