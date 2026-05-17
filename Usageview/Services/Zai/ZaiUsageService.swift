import Foundation
import os

private let logger = Logger(subsystem: "com.ayangabryl.usage", category: "ZaiUsage")

struct ZaiUsageData: Sendable {
    var planName: String?
    /// Longest token window (primary)
    var tokenUsedPercent: Double?
    var tokenResetAt: Date?
    var tokenWindowLabel: String?
    /// MCP / TIME_LIMIT window (secondary)
    var mcpUsedPercent: Double?
    var mcpResetAt: Date?
    var mcpWindowLabel: String?
    /// Shorter TOKENS_LIMIT when API returns two (tertiary / 5h-style)
    var sessionUsedPercent: Double?
    var sessionResetAt: Date?
    var sessionWindowLabel: String?

    var primaryPercent: Double {
        [tokenUsedPercent, sessionUsedPercent, mcpUsedPercent].compactMap { $0 }.max() ?? 0
    }
}

@MainActor
final class ZaiUsageService: Sendable {
    private let authService: ZaiAuthService

    init(authService: ZaiAuthService) {
        self.authService = authService
    }

    func fetchUsage(for accountId: UUID) async -> ZaiUsageData? {
        guard let apiKey = authService.getAPIKey(for: accountId) else { return nil }
        let region = authService.region(for: accountId)
        var request = URLRequest(url: region.quotaURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.timeoutInterval = 20

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }
            guard http.statusCode == 200 else {
                logger.warning("Z.ai HTTP \(http.statusCode)")
                return nil
            }
            return parseQuotaResponse(data)
        } catch {
            logger.error("Z.ai fetch: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func parseQuotaResponse(_ data: Data) -> ZaiUsageData? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = json["code"] as? Int, code == 200,
              let payload = json["data"] as? [String: Any],
              let limits = payload["limits"] as? [[String: Any]]
        else { return nil }

        let planName = [payload["planName"], payload["plan"], payload["plan_type"], payload["packageName"]]
            .compactMap { $0 as? String }
            .first { !$0.isEmpty }

        var tokenLimits: [ZaiParsedLimit] = []
        var timeLimit: ZaiParsedLimit?

        for raw in limits {
            guard let parsed = ZaiParsedLimit(raw: raw) else { continue }
            switch parsed.type {
            case "TOKENS_LIMIT": tokenLimits.append(parsed)
            case "TIME_LIMIT": timeLimit = parsed
            default: break
            }
        }

        var result = ZaiUsageData(planName: planName)
        let sortedTokens = tokenLimits.sorted { ($0.windowMinutes ?? Int.max) < ($1.windowMinutes ?? Int.max) }

        if sortedTokens.count >= 2 {
            apply(limit: sortedTokens.first!, to: &result, slot: .session)
            apply(limit: sortedTokens.last!, to: &result, slot: .token)
        } else if let only = sortedTokens.first {
            apply(limit: only, to: &result, slot: .token)
        }

        if let timeLimit {
            apply(limit: timeLimit, to: &result, slot: .mcp)
        }

        guard result.tokenUsedPercent != nil || result.mcpUsedPercent != nil || result.sessionUsedPercent != nil else {
            return nil
        }
        return result
    }

    private enum LimitSlot { case token, mcp, session }

    private func apply(limit: ZaiParsedLimit, to data: inout ZaiUsageData, slot: LimitSlot) {
        let label = limit.windowLabel ?? (slot == .mcp ? "MCP" : "Tokens")
        switch slot {
        case .token:
            data.tokenUsedPercent = limit.usedPercent
            data.tokenResetAt = limit.resetAt
            data.tokenWindowLabel = label
        case .mcp:
            data.mcpUsedPercent = limit.usedPercent
            data.mcpResetAt = limit.resetAt
            data.mcpWindowLabel = label
        case .session:
            data.sessionUsedPercent = limit.usedPercent
            data.sessionResetAt = limit.resetAt
            data.sessionWindowLabel = label
        }
    }
}

private struct ZaiParsedLimit {
    let type: String
    let usedPercent: Double
    let resetAt: Date?
    let windowMinutes: Int?
    let windowLabel: String?

    init?(raw: [String: Any]) {
        guard let type = raw["type"] as? String else { return nil }
        self.type = type
        let pct = (raw["percentage"] as? Int).map(Double.init) ?? (raw["percentage"] as? Double) ?? 0
        var usedPercent = min(100, max(0, pct))

        if let ms = raw["nextResetTime"] as? Int {
            self.resetAt = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        } else if let ms = raw["nextResetTime"] as? Double {
            self.resetAt = Date(timeIntervalSince1970: ms / 1000)
        } else {
            self.resetAt = nil
        }

        let unit = raw["unit"] as? Int ?? 0
        let number = raw["number"] as? Int ?? 0
        if number > 0 {
            switch unit {
            case 5: self.windowMinutes = number
            case 3: self.windowMinutes = number * 60
            case 1: self.windowMinutes = number * 24 * 60
            case 6: self.windowMinutes = number * 7 * 24 * 60
            default: self.windowMinutes = nil
            }
            let unitName: String? = switch unit {
            case 5: "minute"
            case 3: "hour"
            case 1: "day"
            case 6: "week"
            default: nil
            }
            if let unitName {
                let plural = number == 1 ? unitName : "\(unitName)s"
                self.windowLabel = "\(number) \(plural)"
            } else {
                self.windowLabel = nil
            }
        } else {
            self.windowMinutes = nil
            self.windowLabel = type == "TIME_LIMIT" ? "MCP" : nil
        }

        if let usage = raw["usage"] as? Int, usage > 0,
           let remaining = raw["remaining"] as? Int,
           let current = raw["currentValue"] as? Int
        {
            let used = max(0, min(usage, max(usage - remaining, current)))
            usedPercent = min(100, (Double(used) / Double(usage)) * 100)
        }
        self.usedPercent = usedPercent
    }
}
