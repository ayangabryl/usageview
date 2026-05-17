import Foundation
import os

private let logger = Logger(subsystem: "com.ayangabryl.usage", category: "CursorUsage")

struct CursorUsageData: Sendable {
    var isActive: Bool
    var planName: String?
    /// Total / included plan usage (0–100)
    var planPercentUsed: Double = 0
    /// Auto + Composer lane (0–100)
    var autoPercentUsed: Double?
    /// Named-model API lane (0–100)
    var apiPercentUsed: Double?
    var planUsedUSD: Double = 0
    var planLimitUSD: Double = 0
    var onDemandUsedUSD: Double = 0
    var onDemandLimitUSD: Double?
    var billingCycleEnd: Date?
    var requestsUsed: Int?
    var requestsLimit: Int?
    var requestPercentUsed: Double?
    var accountEmail: String?
    var accountName: String?

    var hasPlanLane: Bool { planPercentUsed > 0 || planLimitUSD > 0 }
    var hasRequestLane: Bool { (requestsLimit ?? 0) > 0 }
}

@MainActor
final class CursorUsageService: Sendable {
    private let authService: CursorAuthService
    private let probe = CursorStatusProbe()
    private let baseURL = URL(string: "https://cursor.com")!
    private let timeout: TimeInterval = 15

    init(authService: CursorAuthService) {
        self.authService = authService
    }

    func fetchUsage(for accountId: UUID) async -> CursorUsageData? {
        guard CursorSettings.isEnabled else { return nil }

        if CursorSettings.cookieSource == .manual,
           let manual = CursorSettings.manualCookieHeader
        {
            return await fetchFullUsage(cookieHeader: manual, accountId: accountId, persistSession: false)
        }

        if let token = authService.getToken(for: accountId),
           let usage = await fetchFullUsage(cookieHeader: token, accountId: accountId, persistSession: false)
        {
            return usage
        }

        if let cached = CookieHeaderCache.load(accountId: accountId),
           let usage = await fetchFullUsage(
               cookieHeader: cached.cookieHeader,
               accountId: accountId,
               persistSession: false)
        {
            authService.updateSession(cookieHeader: cached.cookieHeader, for: accountId)
            return usage
        }

        return await reimportAndFetch(accountId: accountId)
    }

    private func reimportAndFetch(accountId: UUID) async -> CursorUsageData? {
        guard CursorSettings.cookieSource == .auto else { return nil }
        do {
            let session = try await probe.fetchValidatedSession(
                accountId: accountId,
                allowCachedSessions: true,
                allowKeychainPrompt: false)
            authService.updateSession(
                cookieHeader: session.cookieHeader,
                for: accountId,
                sourceLabel: session.sourceLabel,
                cookies: session.cookies)
            return await fetchFullUsage(
                cookieHeader: session.cookieHeader,
                accountId: accountId,
                persistSession: false)
        } catch {
            logger.info("Cursor browser re-import failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func fetchFullUsage(
        cookieHeader: String,
        accountId: UUID,
        persistSession: Bool
    ) async -> CursorUsageData? {
        let normalized = CookieHeaderNormalizer.normalize(cookieHeader) ?? cookieHeader

        do {
            let result = try await fetchWithCookieHeader(normalized, accountId: accountId)
            if persistSession {
                authService.updateSession(cookieHeader: normalized, for: accountId)
            }
            return result
        } catch CursorProbeError.notLoggedIn {
            CookieHeaderCache.clear(accountId: accountId)
            return await reimportAndFetch(accountId: accountId)
        } catch {
            logger.error("Cursor usage fetch error: \(error.localizedDescription)")
            return nil
        }
    }

    private enum FetchPart: Sendable {
        case usageSummary(CursorUsageSummary)
        case userInfo(CursorUserInfo?)
        case requestUsage(CursorUsageResponse?)
    }

    private func fetchWithCookieHeader(_ cookieHeader: String, accountId: UUID) async throws -> CursorUsageData {
        var summary: CursorUsageSummary?
        var userInfo: CursorUserInfo?

        try await withThrowingTaskGroup(of: FetchPart.self) { group in
            group.addTask { try await .usageSummary(self.fetchUsageSummary(cookieHeader: cookieHeader)) }
            group.addTask {
                do {
                    return .userInfo(try await self.fetchUserInfo(cookieHeader: cookieHeader))
                } catch {
                    return .userInfo(nil)
                }
            }

            while let part = try await group.next() {
                switch part {
                case let .usageSummary(value):
                    summary = value
                case let .userInfo(value):
                    userInfo = value
                case .requestUsage:
                    break
                }
            }
        }

        guard let summary else {
            throw CursorProbeError.networkError("Usage summary did not complete")
        }

        var requestUsage: CursorUsageResponse?
        if let userId = userInfo?.sub {
            requestUsage = try? await fetchRequestUsage(userId: userId, cookieHeader: cookieHeader)
        }

        return CursorUsageParser.parse(summary: summary, userInfo: userInfo, requestUsage: requestUsage)
    }

    private func fetchUsageSummary(cookieHeader: String) async throws -> CursorUsageSummary {
        let bases = [baseURL, URL(string: "https://www.cursor.com")!]
        var lastError: Error?

        for base in bases {
            let url = base.appendingPathComponent("/api/usage-summary")
            var request = URLRequest(url: url)
            request.timeoutInterval = timeout
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else { continue }
                if http.statusCode == 401 || http.statusCode == 403 {
                    throw CursorProbeError.notLoggedIn
                }
                guard http.statusCode == 200 else { continue }
                return try JSONDecoder().decode(CursorUsageSummary.self, from: data)
            } catch let error as CursorProbeError {
                throw error
            } catch {
                lastError = error
            }
        }

        if let lastError { throw lastError }
        throw CursorProbeError.networkError("Could not load usage summary")
    }

    private func fetchUserInfo(cookieHeader: String) async throws -> CursorUserInfo {
        let url = baseURL.appendingPathComponent("/api/auth/me")
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CursorProbeError.networkError("Invalid auth response")
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw CursorProbeError.notLoggedIn
        }
        guard http.statusCode == 200 else {
            throw CursorProbeError.networkError("HTTP \(http.statusCode) on auth/me")
        }
        return try JSONDecoder().decode(CursorUserInfo.self, from: data)
    }

    private func fetchRequestUsage(userId: String, cookieHeader: String) async throws -> CursorUsageResponse {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("/api/usage"),
            resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "user", value: userId)]
        guard let url = components.url else {
            throw CursorProbeError.networkError("Invalid usage URL")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw CursorProbeError.networkError("Request usage unavailable")
        }
        return try JSONDecoder().decode(CursorUsageResponse.self, from: data)
    }
}
