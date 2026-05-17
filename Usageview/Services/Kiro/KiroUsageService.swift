import Foundation
import os

private let logger = Logger(subsystem: "com.ayangabryl.usage", category: "KiroUsage")

struct KiroUsageData: Sendable {
    var isActive: Bool
    var planName: String?
    var creditsUsed: Double = 0
    var creditsTotal: Double = 0
    var creditsPercent: Double = 0
    var resetsAt: Date?

    var hasQuotaData: Bool {
        creditsTotal > 0 || creditsPercent > 0
    }
}

@MainActor
final class KiroUsageService: Sendable {
    private let authService: KiroAuthService

    init(authService: KiroAuthService) {
        self.authService = authService
    }

    func fetchStatus(for accountId: UUID) async -> KiroUsageData? {
        if let snapshot = await KiroCLIUsageProbe.fetchUsage() {
            logger.info("Kiro CLI: \(snapshot.creditsPercent, privacy: .public)% credits")
            return KiroUsageData(
                isActive: true,
                planName: snapshot.planName,
                creditsUsed: snapshot.creditsUsed,
                creditsTotal: snapshot.creditsTotal,
                creditsPercent: snapshot.creditsPercent,
                resetsAt: snapshot.resetsAt
            )
        }

        if authService.getAPIKey(for: accountId) != nil || KiroCLIUsageProbe.isCLIAvailable() {
            return KiroUsageData(isActive: KiroCLIUsageProbe.isCLIAvailable())
        }

        return nil
    }
}
