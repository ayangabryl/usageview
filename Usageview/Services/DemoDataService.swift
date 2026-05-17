import Foundation

/// Provides mock usage data when the demo API key is entered.
///
/// Usage for App Review: enter "uv-rev-4f8a2d1e9c3b7f6a" as the API key for any
/// service that supports API key auth (Claude, OpenAI, Gemini, OpenRouter, Kimi, Kiro, Augment).
/// The app will display realistic mock usage data without making real API calls.
/// This key is not documented or exposed anywhere in the app UI.
enum DemoDataService {

    static let magicKey = "uv-rev-4f8a2d1e9c3b7f6a"

    struct DemoSnapshot {
        var username: String
        var planName: String?
        var organizationName: String?

        /// Primary usage percentage (0–100)
        var currentUsage: Double
        var usageLimit: Double
        var usageUnit: String
        var resetDate: Date

        // Dual-window fields (Claude / ChatGPT / Gemini)
        var fiveHourUsage: Double?
        var fiveHourResetDate: Date?
        var sevenDayUsage: Double?
        var sevenDayResetDate: Date?

        // OpenRouter credits
        var openRouterTotalCredits: Double?
        var openRouterTotalUsage: Double?
    }

    static func snapshot(for serviceType: ServiceType) -> DemoSnapshot {
        let now = Date()
        switch serviceType {

        case .claude:
            return DemoSnapshot(
                username: "demo@example.com",
                planName: "Pro",
                organizationName: "Demo Workspace",
                currentUsage: 67.0,
                usageLimit: 100,
                usageUnit: "% used",
                resetDate: now.addingTimeInterval(60 * 60 * 24 * 5), // 5 days
                fiveHourUsage: 45.0,
                fiveHourResetDate: now.addingTimeInterval(60 * 60 * 3),
                sevenDayUsage: 67.0,
                sevenDayResetDate: now.addingTimeInterval(60 * 60 * 24 * 5)
            )

        case .chatgpt:
            return DemoSnapshot(
                username: "demo@example.com",
                planName: "Plus",
                currentUsage: 58.0,
                usageLimit: 100,
                usageUnit: "% used",
                resetDate: now.addingTimeInterval(60 * 60 * 24 * 6),
                fiveHourUsage: 32.0,
                fiveHourResetDate: now.addingTimeInterval(60 * 60 * 4),
                sevenDayUsage: 58.0,
                sevenDayResetDate: now.addingTimeInterval(60 * 60 * 24 * 6)
            )

        case .codex:
            return DemoSnapshot(
                username: "demo@example.com",
                planName: "Pro",
                currentUsage: 41.0,
                usageLimit: 100,
                usageUnit: "% used",
                resetDate: now.addingTimeInterval(60 * 60 * 4),
                fiveHourUsage: 41.0,
                fiveHourResetDate: now.addingTimeInterval(60 * 60 * 4),
                sevenDayUsage: 62.0,
                sevenDayResetDate: now.addingTimeInterval(60 * 60 * 24 * 5)
            )

        case .zai:
            return DemoSnapshot(
                username: "demo@z.ai",
                planName: "GLM Coding Plan",
                currentUsage: 55.0,
                usageLimit: 100,
                usageUnit: "% used",
                resetDate: now.addingTimeInterval(60 * 60 * 24 * 2),
                fiveHourUsage: 48.0,
                fiveHourResetDate: now.addingTimeInterval(60 * 60 * 24 * 2),
                sevenDayUsage: 22.0,
                sevenDayResetDate: now.addingTimeInterval(60 * 60 * 24 * 28)
            )

        case .gemini:
            return DemoSnapshot(
                username: "demo@example.com",
                planName: "Pro",
                currentUsage: 41.0,
                usageLimit: 100,
                usageUnit: "% used",
                resetDate: now.addingTimeInterval(60 * 60 * 24 * 3),
                fiveHourUsage: 41.0,
                fiveHourResetDate: now.addingTimeInterval(60 * 60 * 5),
                sevenDayUsage: 28.0,
                sevenDayResetDate: now.addingTimeInterval(60 * 60 * 24 * 3)
            )

        case .openrouter:
            let totalCredits = 10.0
            let totalUsage = 3.47
            let pct = (totalUsage / totalCredits) * 100
            return DemoSnapshot(
                username: "demo@openrouter.ai",
                currentUsage: pct,
                usageLimit: 100,
                usageUnit: String(format: "$%.2f remaining", totalCredits - totalUsage),
                resetDate: now.addingTimeInterval(60 * 60 * 24 * 30),
                openRouterTotalCredits: totalCredits,
                openRouterTotalUsage: totalUsage
            )

        case .kimi:
            return DemoSnapshot(
                username: "demo@example.com",
                planName: "K1",
                currentUsage: 35.0,
                usageLimit: 100,
                usageUnit: "% used",
                resetDate: now.addingTimeInterval(60 * 60 * 24 * 4)
            )

        case .kiro:
            return DemoSnapshot(
                username: "demo@example.com",
                planName: "Pro",
                currentUsage: 0,
                usageLimit: 0,
                usageUnit: "Connected",
                resetDate: now.addingTimeInterval(60 * 60 * 24 * 30)
            )

        case .augment:
            return DemoSnapshot(
                username: "demo@example.com",
                planName: "Team",
                currentUsage: 0,
                usageLimit: 0,
                usageUnit: "Connected",
                resetDate: now.addingTimeInterval(60 * 60 * 24 * 30)
            )

        default:
            return DemoSnapshot(
                username: "demo@example.com",
                currentUsage: 50.0,
                usageLimit: 100,
                usageUnit: "% used",
                resetDate: now.addingTimeInterval(60 * 60 * 24 * 7)
            )
        }
    }
}
