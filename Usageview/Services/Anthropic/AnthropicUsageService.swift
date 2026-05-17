import Foundation
import os

private let logger = Logger(subsystem: "com.ayangabryl.usage", category: "AnthropicUsage")

struct ClaudeUsageData: Sendable {
    var fiveHourUtilization: Double
    var fiveHourResetsAt: Date?
    var sevenDayUtilization: Double
    var sevenDayResetsAt: Date?
    var organizationID: String?
    // Extra metadata from usage response
    var planTier: String?
    var organizationName: String?
    var monthlySpendUSD: Double?
    var monthlySpendLimitUSD: Double?
}

struct ClaudeLocalUsageSummary: Sendable {
    var todayCostUSD: Double
    var last30DayCostUSD: Double
    var todayTokens: Int64
    var last30DayTokens: Int64
    var dailyCumulativeSpendByDay: [String: Double]
}

@MainActor
final class AnthropicUsageService: Sendable {
    private let authService: AnthropicAuthService

    init(authService: AnthropicAuthService) {
        self.authService = authService
    }

    func fetchUsage(for accountId: UUID) async -> ClaudeUsageData? {
        // Prefer Claude Code CLI credentials for most accurate usage data
        guard let token = await authService.getValidTokenPreferCLI(for: accountId) else {
            logger.error("No valid token for account \(accountId.uuidString)")
            return nil
        }

        let url = URL(string: "https://api.anthropic.com/api/oauth/usage")!

        // Detect Claude Code version for User-Agent (matches what Claude Code CLI sends)
        let claudeVersion = Self.detectClaudeCodeVersion() ?? "2.1.0"

        // Retry up to 5 times on 429 (rate limit on the usage endpoint itself)
        for attempt in 0..<5 {
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            // The usage API requires a claude-code User-Agent to return proper data
            request.setValue("claude-code/\(claudeVersion)", forHTTPHeaderField: "User-Agent")
            request.setValue("no-cache, no-store", forHTTPHeaderField: "Cache-Control")
            request.setValue("no-cache", forHTTPHeaderField: "Pragma")

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else { continue }

                if http.statusCode == 200 {
                    let bodyStr = String(data: data, encoding: .utf8) ?? ""
                    logger.info("Usage response: \(bodyStr.prefix(500))")
                    var usage = parseUsageResponse(data: data)
                    if var usage, usage.monthlySpendUSD == nil {
                        var orgID = usage.organizationID
                        if orgID == nil {
                            orgID = await fetchOrganizationID(token: token)
                        }
                        if let orgID,
                           let (used, limit) = await fetchOverageSpendLimit(token: token, organizationID: orgID)
                        {
                            usage.monthlySpendUSD = used
                            if usage.monthlySpendLimitUSD == nil {
                                usage.monthlySpendLimitUSD = limit
                            }
                            logger.info("Filled Claude spend via overage endpoint")
                        }
                    }
                    return usage
                } else if http.statusCode == 429 {
                    // Rate limited on the usage endpoint — wait and retry
                    let retryAfter = http.value(forHTTPHeaderField: "retry-after")
                        .flatMap { Double($0) } ?? 3.0
                    let delay = max(retryAfter, 3.0) // at least 3s
                    logger.info("Usage endpoint 429, retry-after=\(retryAfter), attempt \(attempt + 1)/5")
                    try? await Task.sleep(for: .seconds(delay))
                    continue
                } else {
                    let bodyStr = String(data: data, encoding: .utf8) ?? ""
                    logger.error("Usage endpoint status \(http.statusCode): \(bodyStr.prefix(300))")
                    return nil
                }
            } catch {
                logger.error("Usage fetch error: \(error.localizedDescription)")
                return nil
            }
        }

        logger.error("Usage fetch exhausted retries for \(accountId.uuidString)")
        return nil
    }

    func fetchLocalUsageSummary(lastDays: Int = 30) -> ClaudeLocalUsageSummary? {
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: Date())
        let firstDay = calendar.date(byAdding: .day, value: -(max(lastDays, 1) - 1), to: todayStart) ?? todayStart
        let todayKey = Self.dayKey(for: todayStart)

        guard let projectsDir = Self.claudeProjectsDirectory(),
              let enumerator = FileManager.default.enumerator(
                at: projectsDir,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
              )
        else {
            return nil
        }

        var dailyCost: [String: Double] = [:]
        var dailyTokens: [String: Int64] = [:]

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension.lowercased() == "jsonl" else { continue }
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]), values.isRegularFile == true else { continue }
            guard let data = try? Data(contentsOf: fileURL),
                  let text = String(data: data, encoding: .utf8)
            else {
                continue
            }

            for rawLine in text.split(whereSeparator: \.isNewline) {
                let lineData = Data(rawLine.utf8)
                guard let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }
                guard let eventDate = Self.parseEventDate(from: json) else { continue }

                let dayStart = calendar.startOfDay(for: eventDate)
                if dayStart < firstDay || dayStart > todayStart { continue }

                guard let usage = Self.extractUsage(from: json) else { continue }
                let totalTokens = usage.inputTokens + usage.outputTokens + usage.cacheReadTokens + usage.cacheWriteTokens
                guard totalTokens > 0 else { continue }

                let key = Self.dayKey(for: dayStart)
                let cost = Self.estimateCostUSD(
                    model: usage.model,
                    inputTokens: usage.inputTokens,
                    outputTokens: usage.outputTokens,
                    cacheReadTokens: usage.cacheReadTokens,
                    cacheWriteTokens: usage.cacheWriteTokens
                )

                dailyCost[key, default: 0] += cost
                dailyTokens[key, default: 0] += totalTokens
            }
        }

        let last30Cost = dailyCost.values.reduce(0, +)
        let last30Tokens = dailyTokens.values.reduce(0, +)

        if last30Cost <= 0 && last30Tokens <= 0 {
            return nil
        }

        var cumulativeByDay: [String: Double] = [:]
        var running: Double = 0
        for i in 0..<max(lastDays, 1) {
            guard let day = calendar.date(byAdding: .day, value: i, to: firstDay) else { continue }
            let key = Self.dayKey(for: day)
            running += dailyCost[key] ?? 0
            cumulativeByDay[key] = running
        }

        return ClaudeLocalUsageSummary(
            todayCostUSD: dailyCost[todayKey] ?? 0,
            last30DayCostUSD: last30Cost,
            todayTokens: dailyTokens[todayKey] ?? 0,
            last30DayTokens: last30Tokens,
            dailyCumulativeSpendByDay: cumulativeByDay
        )
    }

    private func parseUsageResponse(data: Data) -> ClaudeUsageData? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let formatterNoFrac = ISO8601DateFormatter()
        formatterNoFrac.formatOptions = [.withInternetDateTime]

        func parseDate(_ str: String?) -> Date? {
            guard let str else { return nil }
            return formatter.date(from: str) ?? formatterNoFrac.date(from: str)
        }

        func parseAmountUSD(_ raw: Any?) -> Double? {
            if let d = raw as? Double { return d }
            if let i = raw as? Int { return Double(i) }
            if let s = raw as? String, let d = Double(s) { return d }
            return nil
        }

        func parseAmountCentsToUSD(_ raw: Any?) -> Double? {
            guard let value = parseAmountUSD(raw) else { return nil }
            return value / 100.0
        }

        // Log all top-level keys for debugging
        logger.info("Usage response keys: \(json.keys.sorted(), privacy: .public)")

        // API response: { "five_hour": { "utilization": 31.0, "resets_at": "..." }, "seven_day": { ... } }
        let fiveHour = json["five_hour"] as? [String: Any]
        let sevenDay = json["seven_day"] as? [String: Any]

        // Also try alternative key names
        let fiveHourData = fiveHour
            ?? json["5_hour"] as? [String: Any]
            ?? json["hourly"] as? [String: Any]
            ?? json["short_term"] as? [String: Any]
        let sevenDayData = sevenDay
            ?? json["7_day"] as? [String: Any]
            ?? json["daily"] as? [String: Any]
            ?? json["weekly"] as? [String: Any]
            ?? json["long_term"] as? [String: Any]

        if fiveHourData != nil {
            logger.info("5-hour data keys: \(fiveHourData!.keys.sorted(), privacy: .public)")
        }
        if sevenDayData != nil {
            logger.info("7-day data keys: \(sevenDayData!.keys.sorted(), privacy: .public)")
        }

        guard fiveHourData != nil || sevenDayData != nil else {
            logger.warning("Unknown usage response keys: \(json.keys.sorted(), privacy: .public)")
            return nil
        }

        // Extract plan/org metadata from top-level fields if present
        let planTier = json["plan"] as? String
            ?? json["tier"] as? String
            ?? json["plan_tier"] as? String
            ?? json["plan_type"] as? String
            ?? (json["plan"] as? [String: Any])?["name"] as? String
            ?? (json["plan"] as? [String: Any])?["tier"] as? String
        let orgName = json["organization"] as? String
            ?? json["organization_name"] as? String
            ?? json["org_name"] as? String
            ?? (json["organization"] as? [String: Any])?["name"] as? String
        let orgID = json["organization_id"] as? String
            ?? json["org_id"] as? String
            ?? (json["organization"] as? [String: Any])?["id"] as? String

        // Spend metadata (best-effort: API keys may vary across accounts/plans)
        let overage = json["overage_spend"] as? [String: Any]
        let extraUsage = json["extra_usage"] as? [String: Any]
        let monthlySpendUSD = parseAmountUSD(json["monthly_spend_usd"])
            ?? parseAmountUSD(json["spend_this_month_usd"])
            ?? parseAmountUSD(json["overage_spend_usd"])
            ?? parseAmountUSD(overage?["current_usd"])
            ?? parseAmountUSD(overage?["used_usd"])
            ?? ((extraUsage?["is_enabled"] as? Bool) == false ? nil : parseAmountCentsToUSD(extraUsage?["used_credits"]))
        let monthlySpendLimitUSD = parseAmountUSD(json["monthly_spend_limit_usd"])
            ?? parseAmountUSD(json["overage_spend_limit_usd"])
            ?? parseAmountUSD(overage?["limit_usd"])
            ?? ((extraUsage?["is_enabled"] as? Bool) == false ? nil : parseAmountCentsToUSD(extraUsage?["monthly_limit"]))

        let spendCents = parseAmountUSD(json["monthly_spend_cents"])
            ?? parseAmountUSD(json["overage_spend_cents"])
            ?? parseAmountUSD(overage?["current_cents"])
            ?? parseAmountUSD(overage?["used_cents"])
        let limitCents = parseAmountUSD(json["monthly_spend_limit_cents"])
            ?? parseAmountUSD(json["overage_spend_limit_cents"])
            ?? parseAmountUSD(overage?["limit_cents"])

        return ClaudeUsageData(
            fiveHourUtilization: fiveHourData?["utilization"] as? Double ?? 0,
            fiveHourResetsAt: parseDate(fiveHourData?["resets_at"] as? String
                ?? fiveHourData?["reset_at"] as? String),
            sevenDayUtilization: sevenDayData?["utilization"] as? Double ?? 0,
            sevenDayResetsAt: parseDate(sevenDayData?["resets_at"] as? String
                ?? sevenDayData?["reset_at"] as? String),
            organizationID: orgID,
            planTier: planTier,
            organizationName: orgName,
            monthlySpendUSD: monthlySpendUSD ?? spendCents.map { $0 / 100.0 },
            monthlySpendLimitUSD: monthlySpendLimitUSD ?? limitCents.map { $0 / 100.0 }
        )
    }

    private func fetchOverageSpendLimit(token: String, organizationID: String) async -> (used: Double, limit: Double?)? {
        guard let url = URL(string: "https://api.anthropic.com/api/organizations/\(organizationID)/overage_spend_limit") else {
            return nil
        }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("claude-code/2.1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("no-cache, no-store", forHTTPHeaderField: "Cache-Control")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }

            func parseAmountUSD(_ raw: Any?) -> Double? {
                if let d = raw as? Double { return d }
                if let i = raw as? Int { return Double(i) }
                if let s = raw as? String, let d = Double(s) { return d }
                return nil
            }

            let used = parseAmountUSD(json["used_credits"]).map { $0 / 100.0 }
                ?? parseAmountUSD(json["used_usd"])
                ?? parseAmountUSD(json["current_usd"])
                ?? parseAmountUSD(json["monthly_spend_usd"])
            let limit = parseAmountUSD(json["monthly_credit_limit"]).map { $0 / 100.0 }
                ?? parseAmountUSD(json["limit_usd"])
                ?? parseAmountUSD(json["monthly_spend_limit_usd"])

            guard let used else { return nil }
            return (used, limit)
        } catch {
            return nil
        }
    }

    private func fetchOrganizationID(token: String) async -> String? {
        guard let url = URL(string: "https://api.anthropic.com/api/organizations") else {
            return nil
        }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("claude-code/2.1.0", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }

            guard let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                return nil
            }

            if let preferred = list.first(where: {
                guard let caps = $0["capabilities"] as? [String] else { return false }
                return caps.contains("chat")
            }) {
                return (preferred["uuid"] as? String) ?? (preferred["id"] as? String)
            }

            return (list.first?["uuid"] as? String) ?? (list.first?["id"] as? String)
        } catch {
            return nil
        }
    }

    // MARK: - Claude Code Version Detection

    /// Detect installed Claude Code CLI version for User-Agent header.
    /// Returns nil if not installed or detection fails.
    private static func detectClaudeCodeVersion() -> String? {
        // Try to find the claude binary
        let possiblePaths = [
            "/usr/local/bin/claude",
            "\(NSHomeDirectory())/.claude/local/claude",
            "/opt/homebrew/bin/claude"
        ]
        
        // Also check PATH via /usr/bin/which
        let whichProc = Process()
        whichProc.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        whichProc.arguments = ["claude"]
        let whichPipe = Pipe()
        whichProc.standardOutput = whichPipe
        whichProc.standardError = Pipe()
        
        var claudePath: String?
        if let _ = try? whichProc.run() {
            whichProc.waitUntilExit()
            if whichProc.terminationStatus == 0 {
                let data = whichPipe.fileHandleForReading.readDataToEndOfFile()
                claudePath = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        
        if claudePath == nil || claudePath!.isEmpty {
            claudePath = possiblePaths.first { FileManager.default.isExecutableFile(atPath: $0) }
        }
        
        guard let path = claudePath, !path.isEmpty else { return nil }
        
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = ["--version"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        
        do {
            try proc.run()
            // Timeout after 3 seconds
            let deadline = Date().addingTimeInterval(3.0)
            while proc.isRunning, Date() < deadline {
                usleep(50000)
            }
            if proc.isRunning {
                proc.terminate()
                usleep(200000)
                if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
            }
            
            guard proc.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return nil }
            let version = output
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(whereSeparator: \.isWhitespace).first
                .map(String.init)
            return version?.isEmpty == true ? nil : version
        } catch {
            return nil
        }
    }

    private static func claudeProjectsDirectory() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let url = home.appendingPathComponent(".claude/projects", isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        return url
    }

    private static func dayKey(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func parseEventDate(from json: [String: Any]) -> Date? {
        if let timestamp = json["timestamp"] as? TimeInterval {
            return Date(timeIntervalSince1970: timestamp)
        }
        if let timestamp = json["timestamp"] as? String {
            if let numeric = TimeInterval(timestamp) {
                return Date(timeIntervalSince1970: numeric)
            }
            let withFrac = ISO8601DateFormatter()
            withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = withFrac.date(from: timestamp) {
                return date
            }
            let noFrac = ISO8601DateFormatter()
            noFrac.formatOptions = [.withInternetDateTime]
            if let date = noFrac.date(from: timestamp) {
                return date
            }
        }
        return nil
    }

    private static func extractUsage(from json: [String: Any]) -> (
        model: String,
        inputTokens: Int64,
        outputTokens: Int64,
        cacheReadTokens: Int64,
        cacheWriteTokens: Int64
    )? {
        let message = json["message"] as? [String: Any]
        let usage = (message?["usage"] as? [String: Any]) ?? (json["usage"] as? [String: Any])
        guard let usage else { return nil }

        func int64Value(_ raw: Any?) -> Int64 {
            if let value = raw as? Int64 { return value }
            if let value = raw as? Int { return Int64(value) }
            if let value = raw as? Double { return Int64(value) }
            if let value = raw as? String, let parsed = Int64(value) { return parsed }
            return 0
        }

        let inputTokens = int64Value(usage["input_tokens"])
        let outputTokens = int64Value(usage["output_tokens"])
        let cacheReadTokens = int64Value(usage["cache_read_input_tokens"])
        let cacheWriteTokens = int64Value(usage["cache_creation_input_tokens"])
        let model = (message?["model"] as? String) ?? (json["model"] as? String) ?? "claude-sonnet"

        return (model, inputTokens, outputTokens, cacheReadTokens, cacheWriteTokens)
    }

    private static func estimateCostUSD(
        model: String,
        inputTokens: Int64,
        outputTokens: Int64,
        cacheReadTokens: Int64,
        cacheWriteTokens: Int64
    ) -> Double {
        let lower = model.lowercased()

        // Anthropic pricing table (USD per 1M tokens), used as best-effort estimation.
        let rates: (input: Double, output: Double, cacheRead: Double, cacheWrite: Double)
        if lower.contains("opus") {
            rates = (input: 15.0, output: 75.0, cacheRead: 1.5, cacheWrite: 18.75)
        } else if lower.contains("haiku") {
            rates = (input: 0.8, output: 4.0, cacheRead: 0.08, cacheWrite: 1.0)
        } else {
            // Sonnet family default
            rates = (input: 3.0, output: 15.0, cacheRead: 0.3, cacheWrite: 3.75)
        }

        let million = 1_000_000.0
        return (Double(inputTokens) / million) * rates.input
            + (Double(outputTokens) / million) * rates.output
            + (Double(cacheReadTokens) / million) * rates.cacheRead
            + (Double(cacheWriteTokens) / million) * rates.cacheWrite
    }

}
