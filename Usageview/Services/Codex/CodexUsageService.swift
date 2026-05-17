import Foundation
import os

private let logger = Logger(subsystem: "com.ayangabryl.usage", category: "CodexUsage")

struct CodexUsageData: Sendable {
    var planName: String
    var fiveHourUsedPercent: Int?
    var fiveHourResetAt: Date?
    var weeklyUsedPercent: Int?
    var weeklyResetAt: Date?
    var creditsBalance: Double?
    var creditsUnlimited: Bool = false
}

@MainActor
final class CodexUsageService: Sendable {
    private let authService: CodexAuthService

    init(authService: CodexAuthService) {
        self.authService = authService
    }

    func fetchUsage(for accountId: UUID) async -> CodexUsageData? {
        guard let bearer = await authService.getValidToken(for: accountId) else {
            logger.error("Codex: no token")
            return nil
        }

        let urls = [
            "https://chatgpt.com/backend-api/wham/usage",
            "https://chatgpt.com/api/codex/usage",
        ]

        for urlStr in urls {
            guard let url = URL(string: urlStr) else { continue }
            var request = URLRequest(url: url)
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 15
            if let chatgptAccId = authService.chatgptAccountId(for: accountId) {
                request.setValue(chatgptAccId, forHTTPHeaderField: "ChatGPT-Account-Id")
            }

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }

                let planType = json["plan_type"] as? String ?? "Codex"
                var result = CodexUsageData(planName: planType)

                if let rateLimit = json["rate_limit"] as? [String: Any] {
                    if let primary = rateLimit["primary_window"] as? [String: Any] {
                        result.fiveHourUsedPercent = primary["used_percent"] as? Int
                        result.fiveHourResetAt = parseReset(primary["reset_at"])
                    }
                    if let secondary = rateLimit["secondary_window"] as? [String: Any] {
                        result.weeklyUsedPercent = secondary["used_percent"] as? Int
                        result.weeklyResetAt = parseReset(secondary["reset_at"])
                    }
                }

                if let credits = json["credits"] as? [String: Any] {
                    result.creditsUnlimited = credits["unlimited"] as? Bool ?? false
                    if let balance = credits["balance"] as? Double {
                        result.creditsBalance = balance
                    } else if let balanceStr = credits["balance"] as? String,
                              let balance = Double(balanceStr)
                    {
                        result.creditsBalance = balance
                    }
                }

                if result.fiveHourUsedPercent != nil || result.weeklyUsedPercent != nil {
                    logger.info("Codex usage: 5h=\(result.fiveHourUsedPercent ?? -1)% weekly=\(result.weeklyUsedPercent ?? -1)%")
                    return result
                }
                return result
            } catch {
                logger.error("Codex \(urlStr): \(error.localizedDescription, privacy: .public)")
            }
        }
        return nil
    }

    private func parseReset(_ raw: Any?) -> Date? {
        if let value = raw as? Int {
            return Date(timeIntervalSince1970: TimeInterval(value))
        }
        if let value = raw as? Double {
            return Date(timeIntervalSince1970: value)
        }
        return nil
    }
}
