import Foundation

// MARK: - Usage summary (cursor.com/api/usage-summary)

struct CursorUsageSummary: Codable, Sendable {
    let billingCycleStart: String?
    let billingCycleEnd: String?
    let membershipType: String?
    let limitType: String?
    let isUnlimited: Bool?
    let individualUsage: CursorIndividualUsage?
    let teamUsage: CursorTeamUsage?
}

struct CursorIndividualUsage: Codable, Sendable {
    let plan: CursorPlanUsage?
    let onDemand: CursorOnDemandUsage?
    let overall: CursorOverallUsage?
}

struct CursorOverallUsage: Codable, Sendable {
    let enabled: Bool?
    let used: Int?
    let limit: Int?
    let remaining: Int?
}

struct CursorPlanUsage: Codable, Sendable {
    let enabled: Bool?
    let used: Int?
    let limit: Int?
    let remaining: Int?
    let autoPercentUsed: Double?
    let apiPercentUsed: Double?
    let totalPercentUsed: Double?
}

struct CursorOnDemandUsage: Codable, Sendable {
    let enabled: Bool?
    let used: Int?
    let limit: Int?
    let remaining: Int?
}

struct CursorTeamUsage: Codable, Sendable {
    let onDemand: CursorOnDemandUsage?
    let pooled: CursorPooledUsage?
    let plan: CursorPlanUsage?
}

struct CursorPooledUsage: Codable, Sendable {
    let enabled: Bool?
    let used: Int?
    let limit: Int?
    let remaining: Int?
}

// MARK: - Legacy request usage (cursor.com/api/usage?user=)

struct CursorUsageResponse: Codable, Sendable {
    let gpt4: CursorModelUsage?
    let startOfMonth: String?

    enum CodingKeys: String, CodingKey {
        case gpt4 = "gpt-4"
        case startOfMonth
    }
}

struct CursorModelUsage: Codable, Sendable {
    let numRequests: Int?
    let numRequestsTotal: Int?
    let maxRequestUsage: Int?
}

struct CursorUserInfo: Codable, Sendable {
    let email: String?
    let name: String?
    let sub: String?
}
