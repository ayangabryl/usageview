import Foundation
import os

private let logger = Logger(subsystem: "com.ayangabryl.usage", category: "CopilotUsage")

// MARK: - Quota Snapshot (matches GitHub Copilot internal API)

struct CopilotQuotaSnapshot: Sendable {
    var entitlement: Double
    var remaining: Double
    var percentRemaining: Double
    var quotaId: String
    var hasPercentRemaining: Bool

    var isPlaceholder: Bool {
        entitlement == 0 && remaining == 0 && percentRemaining == 0 && quotaId.isEmpty
    }

    var usedPercent: Double {
        guard hasPercentRemaining else { return 0 }
        return max(0, 100 - percentRemaining)
    }
}

struct CopilotUsageData: Sendable {
    var entitlement: Double
    var remaining: Double
    var used: Double
    var percentRemaining: Double
    var resetDate: Date?
    var plan: String?
    // Chat quota (secondary)
    var chatEntitlement: Double?
    var chatRemaining: Double?
    var chatPercentRemaining: Double?
}

@MainActor
final class GitHubUsageService: Sendable {
    private let authService: GitHubAuthService

    init(authService: GitHubAuthService) {
        self.authService = authService
    }

    func fetchCopilotUsage(for accountId: UUID) async -> CopilotUsageData? {
        guard let token = authService.token(for: accountId) else { return nil }

        let url = URL(string: "https://api.github.com/copilot_internal/user")!
        var request = URLRequest(url: url)
        // Use "token" prefix (not Bearer) — matches GitHub Copilot internal API expectations
        request.setValue("token \(token)", forHTTPHeaderField: "Authorization")
        // Editor spoofing headers — required by the Copilot internal API
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("vscode/1.99.3", forHTTPHeaderField: "Editor-Version")
        request.setValue("copilot-chat/0.27.2", forHTTPHeaderField: "Editor-Plugin-Version")
        request.setValue("GitHubCopilotChat/0.27.2", forHTTPHeaderField: "User-Agent")
        request.setValue("2025-04-01", forHTTPHeaderField: "X-Github-Api-Version")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }

            if http.statusCode == 401 || http.statusCode == 403 {
                logger.error("Copilot API auth failed: \(http.statusCode)")
                return nil
            }

            guard http.statusCode == 200 else {
                logger.error("Copilot API error: \(http.statusCode)")
                return nil
            }

            return parseResponse(data: data)
        } catch {
            logger.error("Copilot fetch error: \(error.localizedDescription)")
            return nil
        }
    }

    private func parseResponse(data: Data) -> CopilotUsageData? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        // Parse quota snapshots — supports both direct and monthly_quotas/limited_user_quotas formats
        let quotaSnapshots = json["quota_snapshots"] as? [String: Any]
        let premium = parseQuotaSnapshot(quotaSnapshots?["premium_interactions"] as? [String: Any])
        let chat = parseQuotaSnapshot(quotaSnapshots?["chat"] as? [String: Any])

        // If no direct snapshots, try monthly_quotas + limited_user_quotas (fallback format)
        let finalPremium: CopilotQuotaSnapshot?
        let finalChat: CopilotQuotaSnapshot?

        if let premium, !premium.isPlaceholder {
            finalPremium = premium
        } else {
            finalPremium = makeQuotaFromMonthly(json: json, key: "completions")
        }

        if let chat, !chat.isPlaceholder {
            finalChat = chat
        } else {
            finalChat = makeQuotaFromMonthly(json: json, key: "chat")
        }

        // Also scan for any unknown quota keys if we found nothing
        var usablePremium = finalPremium
        var usableChat = finalChat
        if usablePremium == nil, usableChat == nil, let quotaSnapshots {
            for (key, value) in quotaSnapshots {
                guard let dict = value as? [String: Any],
                      let snapshot = parseQuotaSnapshot(dict),
                      !snapshot.isPlaceholder, snapshot.hasPercentRemaining else { continue }

                let lowerKey = key.lowercased()
                if usableChat == nil, lowerKey.contains("chat") {
                    usableChat = snapshot
                } else if usablePremium == nil,
                          lowerKey.contains("premium") || lowerKey.contains("completion") || lowerKey.contains("code") {
                    usablePremium = snapshot
                }
            }
            // If only one unknown quota found, expose it
            if usablePremium == nil, usableChat == nil {
                for (_, value) in quotaSnapshots {
                    guard let dict = value as? [String: Any],
                          let snapshot = parseQuotaSnapshot(dict),
                          !snapshot.isPlaceholder, snapshot.hasPercentRemaining else { continue }
                    usableChat = snapshot
                    break
                }
            }
        }

        // Need at least one valid quota
        guard usablePremium != nil || usableChat != nil else {
            logger.warning("No valid Copilot quota snapshots found")
            return nil
        }

        // Parse reset date
        let resetDateStr = json["quota_reset_date_utc"] as? String ?? json["quota_reset_date"] as? String
        var resetDate: Date?
        if let resetDateStr {
            let isoFormatter = ISO8601DateFormatter()
            isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            resetDate = isoFormatter.date(from: resetDateStr)
            if resetDate == nil {
                let dateFormatter = DateFormatter()
                dateFormatter.dateFormat = "yyyy-MM-dd"
                dateFormatter.timeZone = TimeZone(identifier: "UTC")
                resetDate = dateFormatter.date(from: resetDateStr)
            }
        }

        let plan = json["copilot_plan"] as? String

        // Build primary (premium) quota data
        let primaryEntitlement = usablePremium?.entitlement ?? 0
        let primaryRemaining = usablePremium?.remaining ?? 0
        let primaryPercentRemaining = usablePremium?.percentRemaining ?? 0

        return CopilotUsageData(
            entitlement: primaryEntitlement,
            remaining: primaryRemaining,
            used: max(0, primaryEntitlement - primaryRemaining),
            percentRemaining: primaryPercentRemaining,
            resetDate: resetDate,
            plan: plan,
            chatEntitlement: usableChat?.entitlement,
            chatRemaining: usableChat?.remaining,
            chatPercentRemaining: usableChat?.percentRemaining
        )
    }

    // MARK: - Parsing Helpers

    private func parseQuotaSnapshot(_ dict: [String: Any]?) -> CopilotQuotaSnapshot? {
        guard let dict else { return nil }

        let entitlement = parseNumber(dict["entitlement"]) ?? 0
        let remaining = parseNumber(dict["remaining"]) ?? 0
        let quotaId = dict["quota_id"] as? String ?? ""

        let percentRemaining: Double
        let hasPercentRemaining: Bool

        if let pct = parseNumber(dict["percent_remaining"]) {
            percentRemaining = max(0, min(100, pct))
            hasPercentRemaining = true
        } else if entitlement > 0 {
            let derived = (remaining / entitlement) * 100
            percentRemaining = max(0, min(100, derived))
            hasPercentRemaining = true
        } else {
            percentRemaining = 0
            hasPercentRemaining = false
        }

        return CopilotQuotaSnapshot(
            entitlement: entitlement,
            remaining: remaining,
            percentRemaining: percentRemaining,
            quotaId: quotaId,
            hasPercentRemaining: hasPercentRemaining
        )
    }

    /// Parse monthly_quotas + limited_user_quotas into a snapshot (fallback format)
    private func makeQuotaFromMonthly(json: [String: Any], key: String) -> CopilotQuotaSnapshot? {
        let monthly = json["monthly_quotas"] as? [String: Any]
        let limited = json["limited_user_quotas"] as? [String: Any]

        guard let monthlyVal = parseNumber(monthly?[key]),
              let limitedVal = parseNumber(limited?[key]),
              monthlyVal > 0 else { return nil }

        let entitlement = max(0, monthlyVal)
        let remaining = max(0, limitedVal)
        let percentRemaining = max(0, min(100, (remaining / entitlement) * 100))

        return CopilotQuotaSnapshot(
            entitlement: entitlement,
            remaining: remaining,
            percentRemaining: percentRemaining,
            quotaId: key,
            hasPercentRemaining: true
        )
    }

    /// Flexibly parse a number from Double, Int, or String
    private func parseNumber(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let s = value as? String { return Double(s) }
        return nil
    }
}
