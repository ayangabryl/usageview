import Foundation
import os

private let logger = Logger(subsystem: "com.ayangabryl.usage", category: "CursorUsage")

struct CursorUsageData: Sendable {
    var isActive: Bool
    var planName: String?
    var usedCents: Double = 0
    var limitCents: Double = 0
    var onDemandUsedCents: Double = 0
    var billingCycleEnd: Date?

    var usagePercent: Double {
        guard limitCents > 0 else { return 0 }
        return (usedCents / limitCents) * 100
    }
}

@MainActor
final class CursorUsageService: Sendable {
    private let authService: CursorAuthService

    init(authService: CursorAuthService) {
        self.authService = authService
    }

    /// Fetch Cursor usage summary using stored session token
    func fetchUsage(for accountId: UUID) async -> CursorUsageData? {
        guard let token = authService.getToken(for: accountId) else { return nil }

        // Try /api/usage-summary first
        if let usage = await fetchUsageSummary(token: token, accountId: accountId) {
            return usage
        }

        // Fallback: just verify token is valid via /api/auth/me
        return await verifySession(token: token)
    }

    private func fetchUsageSummary(token: String, accountId: UUID) async -> CursorUsageData? {
        let baseURLs = ["https://cursor.com", "https://www.cursor.com"]
        for base in baseURLs {
            if let usage = await fetchUsageSummary(token: token, baseURL: base, accountId: accountId) {
                return usage
            }
        }
        return nil
    }

    private func fetchUsageSummary(token: String, baseURL: String, accountId: UUID) async -> CursorUsageData? {
        guard let url = URL(string: "\(baseURL)/api/usage-summary") else { return nil }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        applySessionCookie(token, to: &request)
        request.setValue(baseURL, forHTTPHeaderField: "Origin")
        request.setValue("\(baseURL)/settings", forHTTPHeaderField: "Referer")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }
            if http.statusCode == 401 || http.statusCode == 403 {
                CookieHeaderCache.clear(accountId: accountId)
                logger.info("Cursor usage-summary (\(baseURL)): session expired (HTTP \(http.statusCode))")
                return nil
            }
            guard http.statusCode == 200 else {
                logger.info("Cursor usage-summary (\(baseURL)): HTTP \(http.statusCode)")
                return nil
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }

            var result = CursorUsageData(isActive: true)

            if let membership = json["membershipType"] as? String {
                result.planName = membership.capitalized
            }

            if let cycleEnd = json["billingCycleEnd"] as? String {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                result.billingCycleEnd = formatter.date(from: cycleEnd)
                    ?? ISO8601DateFormatter().date(from: cycleEnd)
            }

            if let individualUsage = json["individualUsage"] as? [String: Any],
               let plan = individualUsage["plan"] as? [String: Any]
            {
                result.usedCents = (plan["used"] as? Double) ?? 0
                result.limitCents = (plan["limit"] as? Double) ?? 0

                if let onDemand = individualUsage["onDemand"] as? [String: Any] {
                    result.onDemandUsedCents = (onDemand["used"] as? Double) ?? 0
                }
            }

            if let teamUsage = json["teamUsage"] as? [String: Any],
               let plan = teamUsage["plan"] as? [String: Any],
               result.limitCents == 0
            {
                result.usedCents = (plan["used"] as? Double) ?? result.usedCents
                result.limitCents = (plan["limit"] as? Double) ?? 0
            }

            return result
        } catch {
            logger.error("Cursor usage fetch error: \(error.localizedDescription)")
            return nil
        }
    }

    private func verifySession(token: String) async -> CursorUsageData? {
        for base in ["https://cursor.com", "https://www.cursor.com"] {
            if let session = await verifySession(token: token, baseURL: base) {
                return session
            }
        }
        return nil
    }

    private func verifySession(token: String, baseURL: String) async -> CursorUsageData? {
        guard let url = URL(string: "\(baseURL)/api/auth/me") else { return nil }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        applySessionCookie(token, to: &request)

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }
            return CursorUsageData(isActive: true)
        } catch {
            return nil
        }
    }

    private func applySessionCookie(_ token: String, to request: inout URLRequest) {
        if token.contains("=") {
            request.setValue(token, forHTTPHeaderField: "Cookie")
        } else {
            request.setValue("WorkosCursorSessionToken=\(token)", forHTTPHeaderField: "Cookie")
        }
    }
}
