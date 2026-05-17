import Foundation

enum ClaudeKeychainReadStrategy: String, CaseIterable, Sendable {
    case securityFramework
    case securityCLIExperimental

    var displayName: String {
        switch self {
        case .securityFramework: "Security.framework"
        case .securityCLIExperimental: "security CLI (recommended)"
        }
    }
}

enum ClaudeKeychainReadStrategyPreference {
    private static let userDefaultsKey = "claudeOAuthKeychainReadStrategy"

    /// CodexBar defaults to experimental CLI reader on current builds.
    static func current() -> ClaudeKeychainReadStrategy {
        if let raw = UserDefaults.standard.string(forKey: userDefaultsKey),
           let strategy = ClaudeKeychainReadStrategy(rawValue: raw)
        {
            return strategy
        }
        return .securityCLIExperimental
    }

    static func set(_ strategy: ClaudeKeychainReadStrategy) {
        UserDefaults.standard.set(strategy.rawValue, forKey: userDefaultsKey)
    }

    static func shouldPreferSecurityCLI() -> Bool {
        current() == .securityCLIExperimental
    }

    /// Prompt policy only applies to Security.framework fallback when using CLI strategy.
    static func isPromptPolicyApplicable() -> Bool {
        current() == .securityFramework
    }
}
