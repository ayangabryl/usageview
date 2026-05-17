import Foundation

// MARK: - Auth Method

enum AuthMethod: String, Codable, Sendable {
    case oauth
    case apiKey
    /// Codex CLI session (`codex login` → `~/.codex/auth.json`), tracked under OpenAI.
    case codexCLI
}
