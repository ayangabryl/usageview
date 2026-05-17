import Foundation
import Darwin

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
        let snapshot = try loadCLIAuthSnapshot()
        return try saveSnapshot(snapshot, for: accountId)
    }

    /// Import from an explicit `auth.json` URL (obtained via NSOpenPanel security-scoped access).
    func connectFromCLI(for accountId: UUID, authFileURL: URL) throws -> CodexAccountInfo {
        let accessing = authFileURL.startAccessingSecurityScopedResource()
        defer { if accessing { authFileURL.stopAccessingSecurityScopedResource() } }

        let data = try Data(contentsOf: authFileURL)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexAuthError.invalidFormat
        }
        let rawString = String(data: data, encoding: .utf8) ?? "{}"
        let creds = try parseCredentials(from: json)
        let snapshot = CLIAuthSnapshot(credentials: creds, rawJSONString: rawString)
        return try saveSnapshot(snapshot, for: accountId)
    }

    /// Restore a saved session by writing auth.json to a security-scoped URL.
    /// Used when the sandbox cannot write to the real path directly.
    func activateSession(for accountId: UUID, writingTo authFileURL: URL) throws -> CodexAccountInfo {
        guard let snapshotRaw = loadToken(key: authSnapshotKey(for: accountId)) else {
            throw CodexAuthError.noSavedSession
        }
        guard let data = snapshotRaw.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw CodexAuthError.invalidSavedSession
        }

        let accessing = authFileURL.startAccessingSecurityScopedResource()
        defer { if accessing { authFileURL.stopAccessingSecurityScopedResource() } }

        let writeData = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        let directory = authFileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try writeData.write(to: authFileURL, options: .atomic)

        let creds = try parseCredentials(from: json)
        saveToken(key: tokenKey(for: accountId), value: creds.accessToken)
        if let accountIdString = creds.accountId {
            saveToken(key: accountIdKey(for: accountId), value: accountIdString)
        } else {
            removeToken(key: accountIdKey(for: accountId))
        }
        let label = creds.accountId.map { "Codex · \($0.prefix(8))…" } ?? "Codex CLI"
        return CodexAccountInfo(name: label)
    }

    private func saveSnapshot(_ snapshot: CLIAuthSnapshot, for accountId: UUID) throws -> CodexAccountInfo {
        let creds = snapshot.credentials
        saveToken(key: tokenKey(for: accountId), value: creds.accessToken)
        if let accountIdString = creds.accountId {
            saveToken(key: accountIdKey(for: accountId), value: accountIdString)
        } else {
            removeToken(key: accountIdKey(for: accountId))
        }
        saveToken(key: authSnapshotKey(for: accountId), value: snapshot.rawJSONString)
        let label = creds.accountId.map { "Codex · \($0.prefix(8))…" } ?? "Codex CLI"
        return CodexAccountInfo(name: label)
    }

    func getValidToken(for accountId: UUID) async -> String? {
        if let stored = loadToken(key: tokenKey(for: accountId)) {
            return stored
        }
        if let snapshot = try? loadCLIAuthSnapshot() {
            let creds = snapshot.credentials
            saveToken(key: tokenKey(for: accountId), value: creds.accessToken)
            if let accountIdString = creds.accountId {
                saveToken(key: accountIdKey(for: accountId), value: accountIdString)
            } else {
                removeToken(key: accountIdKey(for: accountId))
            }
            saveToken(key: authSnapshotKey(for: accountId), value: snapshot.rawJSONString)
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
        removeToken(key: authSnapshotKey(for: accountId))
    }

    func hasSavedSession(for accountId: UUID) -> Bool {
        loadToken(key: authSnapshotKey(for: accountId)) != nil
    }

    func isActiveSession(for accountId: UUID) -> Bool {
        guard let currentCreds = try? loadCLIAuth() else { return false }

        // Prefer stable account_id comparison (survives token refresh).
        if let savedAccountId = loadToken(key: accountIdKey(for: accountId)),
           !savedAccountId.isEmpty,
           let currentAccountId = currentCreds.accountId {
            return savedAccountId == currentAccountId
        }

        // Fallback: compare raw access tokens (works for API-key accounts with no account_id).
        guard let savedToken = loadToken(key: tokenKey(for: accountId)) else { return false }
        return savedToken == currentCreds.accessToken
    }

    /// Make this account the active Codex session by restoring its saved auth.json snapshot.
    func activateSession(for accountId: UUID) throws -> CodexAccountInfo {
        guard let snapshotRaw = loadToken(key: authSnapshotKey(for: accountId)) else {
            throw CodexAuthError.noSavedSession
        }
        guard let data = snapshotRaw.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw CodexAuthError.invalidSavedSession
        }
        try writeCLIAuth(json: json)
        let creds = try loadCLIAuth()
        saveToken(key: tokenKey(for: accountId), value: creds.accessToken)
        if let accountIdString = creds.accountId {
            saveToken(key: accountIdKey(for: accountId), value: accountIdString)
        } else {
            removeToken(key: accountIdKey(for: accountId))
        }
        let label = creds.accountId.map { "Codex · \($0.prefix(8))…" } ?? "Codex CLI"
        return CodexAccountInfo(name: label)
    }

    // MARK: - CLI auth.json

    struct CLICredentials: Sendable {
        let accessToken: String
        let accountId: String?
    }

    func loadCLIAuth() throws -> CLICredentials {
        try loadCLIAuthSnapshot().credentials
    }

    private struct CLIAuthSnapshot {
        let credentials: CLICredentials
        let rawJSONString: String
    }

    private func loadCLIAuthSnapshot() throws -> CLIAuthSnapshot {
        guard let url = Self.firstExistingAuthFileURL() else {
            throw CodexAuthError.notFound(checkedPaths: Self.authFileCandidates().map(\.path))
        }
        let data = try Data(contentsOf: url)
        guard let rawJSONString = String(data: data, encoding: .utf8) else {
            throw CodexAuthError.invalidFile
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexAuthError.invalidFile
        }
        return CLIAuthSnapshot(credentials: try parseCredentials(from: json), rawJSONString: rawJSONString)
    }

    private func parseCredentials(from json: [String: Any]) throws -> CLICredentials {
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

    private func writeCLIAuth(json: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        for url in Self.authFileWriteTargets() {
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }
    }

    /// Real user home directory — bypasses macOS sandbox path redirection.
    /// `FileManager.homeDirectoryForCurrentUser` returns the container path in sandboxed apps;
    /// `getpwuid` queries Directory Services and always returns the actual `/Users/name` path.
    static func realHomeDirectory() -> URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    private static func authFileCandidates() -> [URL] {
        var candidates: [URL] = []
        let env = ProcessInfo.processInfo.environment
        if let codexHome = env["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !codexHome.isEmpty
        {
            candidates.append(URL(fileURLWithPath: codexHome).appendingPathComponent("auth.json"))
        }
        let home = realHomeDirectory()
        candidates.append(home.appendingPathComponent(".codex/auth.json"))
        candidates.append(home.appendingPathComponent("Library/Application Support/Codex/auth.json"))

        var unique: [URL] = []
        for candidate in candidates {
            if !unique.contains(where: { $0.path == candidate.path }) {
                unique.append(candidate)
            }
        }
        return unique
    }

    private static func firstExistingAuthFileURL() -> URL? {
        authFileCandidates().first(where: { FileManager.default.fileExists(atPath: $0.path) })
    }

    private static func authFileWriteTargets() -> [URL] {
        var targets: [URL] = []
        if let existing = firstExistingAuthFileURL() {
            targets.append(existing)
        }
        // Always keep canonical CLI path in sync.
        let canonical = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json")
        if !targets.contains(where: { $0.path == canonical.path }) {
            targets.append(canonical)
        }
        return targets
    }

    // MARK: - Keychain

    private func tokenKey(for id: UUID) -> String {
        "com.ayangabryl.usage.codex-token-\(id.uuidString)"
    }

    private func accountIdKey(for id: UUID) -> String {
        "com.ayangabryl.usage.codex-account-id-\(id.uuidString)"
    }

    private func authSnapshotKey(for id: UUID) -> String {
        "com.ayangabryl.usage.codex-auth-json-\(id.uuidString)"
    }

    private func saveToken(key: String, value: String) { KeychainHelper.save(value, forKey: key) }
    private func loadToken(key: String) -> String? { KeychainHelper.load(forKey: key) }
    private func removeToken(key: String) { KeychainHelper.remove(forKey: key) }

    private func loadAccountId(key: String) -> String? { KeychainHelper.load(forKey: key) }
}

enum CodexAuthError: LocalizedError {
    case notFound(checkedPaths: [String])
    case invalidFile
    case invalidFormat
    case missingTokens
    case noSavedSession
    case invalidSavedSession

    var errorDescription: String? {
        switch self {
        case .notFound(let checkedPaths):
            let paths = checkedPaths.joined(separator: ", ")
            return "Codex auth.json not found. Checked: \(paths). Run `codex login` in Terminal, then try import again."
        case .invalidFile:
            return "Could not read Codex auth.json."
        case .invalidFormat:
            return "The selected file is not a valid Codex auth.json."
        case .missingTokens:
            return "Codex auth.json has no tokens. Run `codex` to sign in."
        case .noSavedSession:
            return "No saved Codex session for this account. Import from Codex CLI first."
        case .invalidSavedSession:
            return "Saved Codex session is invalid. Re-import from Codex CLI."
        }
    }
}
