import Foundation
import SwiftUI

// MARK: - Account

struct Account: Codable, Identifiable, Sendable {
    var id: UUID
    var serviceType: ServiceType
    var authMethod: AuthMethod
    var label: String
    var currentUsage: Double
    var usageLimit: Double
    var usageUnit: String
    var resetDate: Date
    var username: String?
    var avatarURL: String?

    // Claude dual rate windows
    var fiveHourUsage: Double?
    var fiveHourResetDate: Date?
    var sevenDayUsage: Double?
    var sevenDayResetDate: Date?
    var tertiaryUsage: Double?
    var tertiaryResetDate: Date?

    // Copilot chat quota (secondary)
    var chatUsage: Double?
    var chatLimit: Double?
    var chatPercentRemaining: Double?

    // Plan / tier label (Copilot, ChatGPT, Gemini, Kimi)
    var planName: String?

    // Organization / workspace info (Claude, etc.)
    var organizationName: String?
    var memberRole: String?

    // Kimi billing data
    var kimiWeeklyUsed: Double?
    var kimiWeeklyLimit: Double?
    var kimiWeeklyResetDate: Date?
    var kimiRateLimitUsed: Double?
    var kimiRateLimitMax: Double?
    var kimiRateLimitResetDate: Date?

    // OpenRouter credits
    var openRouterTotalCredits: Double?
    var openRouterTotalUsage: Double?

    // Provider spend / billing metadata
    var monthlySpendUSD: Double?
    var monthlySpendLimitUSD: Double?
    var openAICreditsBalance: Double?
    var openAICreditsUnlimited: Bool?
    var spendHistoryByDay: [String: Double]?
    var todayTokenCount: Int64?
    var last30DayTokenCount: Int64?

    // App Review demo mode flag
    var isDemoAccount: Bool = false

    // JetBrains AI quota
    var jetbrainsQuotaCurrent: Double?
    var jetbrainsQuotaMaximum: Double?
    var jetbrainsQuotaResetDate: Date?

    init(id: UUID, serviceType: ServiceType, authMethod: AuthMethod = .oauth, label: String, currentUsage: Double, usageLimit: Double, usageUnit: String, resetDate: Date, username: String? = nil, avatarURL: String? = nil) {
        self.id = id
        self.serviceType = serviceType
        self.authMethod = authMethod
        self.label = label
        self.currentUsage = currentUsage
        self.usageLimit = usageLimit
        self.usageUnit = usageUnit
        self.resetDate = resetDate
        self.username = username
        self.avatarURL = avatarURL
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        serviceType = try container.decode(ServiceType.self, forKey: .serviceType)
        authMethod = try container.decodeIfPresent(AuthMethod.self, forKey: .authMethod) ?? .oauth
        label = try container.decode(String.self, forKey: .label)
        currentUsage = try container.decode(Double.self, forKey: .currentUsage)
        usageLimit = try container.decode(Double.self, forKey: .usageLimit)
        usageUnit = try container.decode(String.self, forKey: .usageUnit)
        resetDate = try container.decode(Date.self, forKey: .resetDate)
        username = try container.decodeIfPresent(String.self, forKey: .username)
        avatarURL = try container.decodeIfPresent(String.self, forKey: .avatarURL)
        fiveHourUsage = try container.decodeIfPresent(Double.self, forKey: .fiveHourUsage)
        fiveHourResetDate = try container.decodeIfPresent(Date.self, forKey: .fiveHourResetDate)
        sevenDayUsage = try container.decodeIfPresent(Double.self, forKey: .sevenDayUsage)
        sevenDayResetDate = try container.decodeIfPresent(Date.self, forKey: .sevenDayResetDate)
        tertiaryUsage = try container.decodeIfPresent(Double.self, forKey: .tertiaryUsage)
        tertiaryResetDate = try container.decodeIfPresent(Date.self, forKey: .tertiaryResetDate)
        chatUsage = try container.decodeIfPresent(Double.self, forKey: .chatUsage)
        chatLimit = try container.decodeIfPresent(Double.self, forKey: .chatLimit)
        chatPercentRemaining = try container.decodeIfPresent(Double.self, forKey: .chatPercentRemaining)
        planName = try container.decodeIfPresent(String.self, forKey: .planName)
        organizationName = try container.decodeIfPresent(String.self, forKey: .organizationName)
        memberRole = try container.decodeIfPresent(String.self, forKey: .memberRole)
        kimiWeeklyUsed = try container.decodeIfPresent(Double.self, forKey: .kimiWeeklyUsed)
        kimiWeeklyLimit = try container.decodeIfPresent(Double.self, forKey: .kimiWeeklyLimit)
        kimiWeeklyResetDate = try container.decodeIfPresent(Date.self, forKey: .kimiWeeklyResetDate)
        kimiRateLimitUsed = try container.decodeIfPresent(Double.self, forKey: .kimiRateLimitUsed)
        kimiRateLimitMax = try container.decodeIfPresent(Double.self, forKey: .kimiRateLimitMax)
        kimiRateLimitResetDate = try container.decodeIfPresent(Date.self, forKey: .kimiRateLimitResetDate)
        openRouterTotalCredits = try container.decodeIfPresent(Double.self, forKey: .openRouterTotalCredits)
        openRouterTotalUsage = try container.decodeIfPresent(Double.self, forKey: .openRouterTotalUsage)
        monthlySpendUSD = try container.decodeIfPresent(Double.self, forKey: .monthlySpendUSD)
        monthlySpendLimitUSD = try container.decodeIfPresent(Double.self, forKey: .monthlySpendLimitUSD)
        openAICreditsBalance = try container.decodeIfPresent(Double.self, forKey: .openAICreditsBalance)
        openAICreditsUnlimited = try container.decodeIfPresent(Bool.self, forKey: .openAICreditsUnlimited)
        spendHistoryByDay = try container.decodeIfPresent([String: Double].self, forKey: .spendHistoryByDay)
        todayTokenCount = try container.decodeIfPresent(Int64.self, forKey: .todayTokenCount)
        last30DayTokenCount = try container.decodeIfPresent(Int64.self, forKey: .last30DayTokenCount)
        isDemoAccount = try container.decodeIfPresent(Bool.self, forKey: .isDemoAccount) ?? false
        jetbrainsQuotaCurrent = try container.decodeIfPresent(Double.self, forKey: .jetbrainsQuotaCurrent)
        jetbrainsQuotaMaximum = try container.decodeIfPresent(Double.self, forKey: .jetbrainsQuotaMaximum)
        jetbrainsQuotaResetDate = try container.decodeIfPresent(Date.self, forKey: .jetbrainsQuotaResetDate)
    }

    /// Whether this Gemini OAuth account has quota data from the CLI
    var hasGeminiQuota: Bool {
        serviceType == .gemini && authMethod == .oauth && fiveHourUsage != nil
    }

    /// Whether this account only shows connection status (no real usage tracking)
    var isStatusOnly: Bool {
        // Demo accounts: show usage bar only if they have actual usage data; otherwise stay status-only
        if isDemoAccount && usageLimit > 0 { return false }
        if isDemoAccount { return true }
        switch (serviceType, authMethod) {
        case (.gemini, .oauth): return !hasGeminiQuota  // OAuth shows real quota when available
        case (.gemini, .apiKey): return true
        case (.claude, .apiKey), (.chatgpt, .apiKey): return true
        case (.chatgpt, .oauth): return !hasChatGPTUsage
        case (.chatgpt, .codexCLI): return !hasCodexCLIUsage
        case (.codex, _): return !hasCodexCLIUsage
        case (.zai, _): return !hasZaiQuota
        case (.kimi, _): return !hasKimiBilling
        case (.cursor, _): return !hasCursorUsage
        case (.openrouter, _): return !hasOpenRouterCredits
        case (.kiro, _): return !hasKiroQuota
        case (.augment, _): return true  // Status-only for now
        case (.jetbrainsAI, _): return !hasJetBrainsQuota
        default: return false
        }
    }

    var usagePercentage: Double {
        guard usageLimit > 0 else { return 0 }
        return min(currentUsage / usageLimit, 1.0)
    }

    var isAtLimit: Bool {
        guard usageLimit > 0 else { return false }
        return currentUsage >= usageLimit
    }

    /// Claude / ChatGPT / Gemini OAuth / Codex with session + weekly (or Pro + Flash) windows
    var hasDualWindows: Bool {
        switch serviceType {
        case .codex:
            return hasCodexCLIUsage && sevenDayUsage != nil
        case .chatgpt:
            if authMethod == .codexCLI {
                return hasCodexCLIUsage && sevenDayUsage != nil
            }
            return authMethod == .oauth && fiveHourUsage != nil && sevenDayUsage != nil
        case .claude, .gemini:
            return authMethod == .oauth && fiveHourUsage != nil && sevenDayUsage != nil
        default:
            return false
        }
    }

    /// Z.ai: token + MCP (+ optional short session) lanes
    var hasZaiTripleWindows: Bool {
        serviceType == .zai && fiveHourUsage != nil && (sevenDayUsage != nil || tertiaryUsage != nil)
    }

    /// Whether this Copilot account has both premium and chat quotas
    var hasCopilotDualQuotas: Bool {
        serviceType == .copilot && chatPercentRemaining != nil
    }

    /// Whether this Kimi account has billing data
    var hasKimiBilling: Bool {
        serviceType == .kimi && kimiWeeklyLimit != nil && kimiWeeklyLimit! > 0
    }

    /// Whether this ChatGPT account has real usage data from /wham/usage
    var hasChatGPTUsage: Bool {
        serviceType == .chatgpt && authMethod == .oauth && fiveHourUsage != nil
    }

    var hasCodexCLIUsage: Bool {
        (serviceType == .chatgpt && authMethod == .codexCLI) || serviceType == .codex
            ? fiveHourUsage != nil
            : false
    }

    var hasZaiQuota: Bool {
        serviceType == .zai && fiveHourUsage != nil
    }

    var hasKiroQuota: Bool {
        serviceType == .kiro && usageLimit > 0
    }

    /// Whether this Cursor account has usage data
    var hasCursorUsage: Bool {
        guard serviceType == .cursor else { return false }
        return usageLimit > 0
            || fiveHourUsage != nil
            || tertiaryUsage != nil
            || (monthlySpendLimitUSD ?? 0) > 0
    }

    /// Cursor: Total / Auto / API lanes (CodexBar-style)
    var hasCursorLanes: Bool {
        serviceType == .cursor && hasCursorUsage
    }

    /// Whether this OpenRouter account has credits data
    var hasOpenRouterCredits: Bool {
        serviceType == .openrouter && openRouterTotalCredits != nil && openRouterTotalCredits! > 0
    }

    /// Whether this JetBrains AI account has quota data
    var hasJetBrainsQuota: Bool {
        serviceType == .jetbrainsAI && jetbrainsQuotaMaximum != nil && jetbrainsQuotaMaximum! > 0
    }

    /// Whether a reset date is plausible for a given rate window.
    /// The 5-hour window shouldn't show resets > 6h away; the 7-day window shouldn't show > 8d.
    static func isResetReasonable(_ date: Date?, maxHours: Double) -> Bool {
        guard let date else { return false }
        let interval = date.timeIntervalSince(.now)
        return interval > 0 && interval < maxHours * 3600
    }

    /// Format a reset date as a short label
    static func resetLabel(for date: Date?) -> String {
        guard let date, date.timeIntervalSince(.now) > 0 else { return "now" }
        let totalMinutes = Int(date.timeIntervalSince(.now)) / 60
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours >= 24 {
            return "\(hours / 24)d"
        } else if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }

    /// Smart reset label: hours/minutes when < 24h, days otherwise
    var resetLabel: String {
        let interval = resetDate.timeIntervalSince(.now)
        guard interval > 0 else { return "now" }
        let totalMinutes = Int(interval) / 60
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours >= 24 {
            return "\(hours / 24)d"
        } else if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }

    var formattedUsage: String {
        if isStatusOnly {
            return usageUnit  // "Connected" / "Inactive" / etc.
        }
        if usageUnit == "% used" {
            return "\(Int(currentUsage))% used"
        }
        return "\(Int(currentUsage))/\(Int(usageLimit)) \(usageUnit)"
    }

    var accentColor: Color {
        serviceType.accentColor
    }
}
