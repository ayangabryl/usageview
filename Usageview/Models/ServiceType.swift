import Foundation
import SwiftUI

// MARK: - Service Type

enum ServiceType: String, Codable, CaseIterable, Sendable {
    case claude
    case copilot
    case chatgpt
    case gemini
    case kimi
    case cursor
    case openrouter
    case kiro
    case augment
    case jetbrainsAI

    var displayName: String {
        switch self {
        case .claude: "Claude"
        case .copilot: "GitHub Copilot"
        case .chatgpt: "OpenAI"
        case .gemini: "Gemini"
        case .kimi: "Kimi AI"
        case .cursor: "Cursor"
        case .openrouter: "OpenRouter"
        case .kiro: "Kiro"
        case .augment: "Augment"
        case .jetbrainsAI: "JetBrains AI"
        }
    }

    /// Asset catalog image name for the bundled brand logo
    var assetName: String {
        switch self {
        case .claude: "AnthropicLogo"
        case .copilot: "GitHubLogo"
        case .chatgpt: "OpenAILogo"
        case .gemini: "GeminiLogo"
        case .kimi: "KimiLogo"
        case .cursor: "CursorLogo"
        case .openrouter: "OpenRouterLogo"
        case .kiro: "KiroLogo"
        case .augment: "AugmentLogo"
        case .jetbrainsAI: "JetBrainsLogo"
        }
    }

    var accentColor: Color {
        switch self {
        case .claude: Color(hex: "#D97706")
        case .copilot: Color(hex: "#6366F1")
        case .chatgpt: Color(hex: "#10A37F")
        case .gemini: Color(hex: "#4285F4")
        case .kimi: Color(hex: "#000000")
        case .cursor: Color(hex: "#00D4AA")
        case .openrouter: Color(hex: "#6467F2")
        case .kiro: Color(hex: "#FF9900")
        case .augment: Color(hex: "#7C3AED")
        case .jetbrainsAI: Color(hex: "#FE315D")
        }
    }

    var authDescription: String {
        switch self {
        case .claude: "OAuth, API key, or Claude Code CLI"
        case .copilot: "GitHub device sign-in"
        case .chatgpt: "OpenAI device sign-in or API key"
        case .gemini: "Google OAuth, API key, or Gemini CLI"
        case .kimi: "Kimi Code token (kimi-auth) or Moonshot API key"
        case .cursor: "Browser session cookie"
        case .openrouter: "API key"
        case .kiro: "kiro-cli login (recommended)"
        case .augment: "API key (usage coming soon)"
        case .jetbrainsAI: "Auto-detect from IDE"
        }
    }

    /// Whether this service supports multiple auth methods
    var supportsMultipleAuthMethods: Bool {
        switch self {
        case .claude, .chatgpt, .gemini: true
        case .copilot, .kimi, .cursor, .openrouter, .kiro, .augment, .jetbrainsAI: false
        }
    }

    var defaultUsageUnit: String {
        switch self {
        case .claude: "% used"
        case .copilot: "premium requests"
        case .chatgpt: "premium requests"
        case .gemini: "requests"
        case .kimi: "tokens"
        case .cursor: "requests"
        case .openrouter: "credits"
        case .kiro: "credits"
        case .augment: "credits"
        case .jetbrainsAI: "credits"
        }
    }

    var defaultLimit: Double {
        switch self {
        case .claude: 100
        case .copilot: 300
        case .chatgpt: 0
        case .gemini: 0
        case .kimi: 0
        case .cursor: 0
        case .openrouter: 0
        case .kiro: 0
        case .augment: 0
        case .jetbrainsAI: 0
        }
    }

    var dashboardURL: URL? {
        let urlString: String = switch self {
        case .claude: "https://claude.ai/settings/billing"
        case .copilot: "https://github.com/settings/copilot"
        case .chatgpt: "https://platform.openai.com/settings/organization/usage"
        case .gemini: "https://aistudio.google.com/"
        case .kimi: "https://platform.moonshot.ai/console/billing"
        case .cursor: "https://www.cursor.com/settings"
        case .openrouter: "https://openrouter.ai/settings/credits"
        case .kiro: "https://kiro.dev/"
        case .augment: "https://app.augmentcode.com/"
        case .jetbrainsAI: "https://account.jetbrains.com/"
        }
        return URL(string: urlString)
    }

    var statusPageURL: URL? {
        let urlString: String? = switch self {
        case .claude: "https://status.anthropic.com/"
        case .copilot: "https://www.githubstatus.com/"
        case .chatgpt: "https://status.openai.com/"
        case .gemini: "https://status.cloud.google.com/"
        case .openrouter: "https://status.openrouter.ai/"
        case .cursor: "https://status.cursor.com/"
        case .kiro, .augment, .jetbrainsAI, .kimi: nil
        }
        guard let urlString else { return nil }
        return URL(string: urlString)
    }
}
