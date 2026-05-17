import Foundation

/// Maps Cursor API payloads to display fields (CodexBar `parseUsageSummary` logic).
enum CursorUsageParser {
    static func parse(
        summary: CursorUsageSummary,
        userInfo: CursorUserInfo?,
        requestUsage: CursorUsageResponse?
    ) -> CursorUsageData {
        let billingCycleEnd = summary.billingCycleEnd.flatMap(parseISO8601)

        let planUsedRaw = Double(summary.individualUsage?.plan?.used ?? 0)
        let planLimitRaw = Double(summary.individualUsage?.plan?.limit ?? 0)
        let overallUsedRaw = summary.individualUsage?.overall?.used.map(Double.init)
        let overallLimitRaw = summary.individualUsage?.overall?.limit.map(Double.init)
        let pooledUsedRaw = summary.teamUsage?.pooled?.used.map(Double.init)
        let pooledLimitRaw = summary.teamUsage?.pooled?.limit.map(Double.init)

        let autoPercent = normPct(summary.individualUsage?.plan?.autoPercentUsed)
        let apiPercent = normPct(summary.individualUsage?.plan?.apiPercentUsed)

        let planPercentUsed: Double = if let total = summary.individualUsage?.plan?.totalPercentUsed {
            clampPercent(total)
        } else if let autoUsed = autoPercent, let apiUsed = apiPercent {
            clampPercent((autoUsed + apiUsed) / 2)
        } else if let apiUsed = apiPercent {
            clampPercent(apiUsed)
        } else if let autoUsed = autoPercent {
            clampPercent(autoUsed)
        } else if planLimitRaw > 0 {
            clampPercent((planUsedRaw / planLimitRaw) * 100)
        } else if let used = overallUsedRaw, let limit = overallLimitRaw, limit > 0 {
            clampPercent((used / limit) * 100)
        } else if let used = pooledUsedRaw, let limit = pooledLimitRaw, limit > 0 {
            clampPercent((used / limit) * 100)
        } else {
            0
        }

        let planUsedUSD: Double
        let planLimitUSD: Double
        if planLimitRaw > 0 || planUsedRaw > 0 {
            planUsedUSD = planUsedRaw / 100.0
            planLimitUSD = planLimitRaw / 100.0
        } else if let usedCents = overallUsedRaw, let limitCents = overallLimitRaw {
            planUsedUSD = usedCents / 100.0
            planLimitUSD = limitCents / 100.0
        } else if let usedCents = pooledUsedRaw, let limitCents = pooledLimitRaw {
            planUsedUSD = usedCents / 100.0
            planLimitUSD = limitCents / 100.0
        } else if let teamPlan = summary.teamUsage?.plan {
            planUsedUSD = Double(teamPlan.used ?? 0) / 100.0
            planLimitUSD = Double(teamPlan.limit ?? 0) / 100.0
        } else {
            planUsedUSD = 0
            planLimitUSD = 0
        }

        let onDemandUsedUSD = Double(summary.individualUsage?.onDemand?.used ?? 0) / 100.0
        let onDemandLimitUSD = summary.individualUsage?.onDemand?.limit.map { Double($0) / 100.0 }

        let requestsUsed = requestUsage?.gpt4?.numRequestsTotal ?? requestUsage?.gpt4?.numRequests
        let requestsLimit = requestUsage?.gpt4?.maxRequestUsage

        var requestPercent: Double?
        if let limit = requestsLimit, limit > 0, let used = requestsUsed {
            requestPercent = clampPercent((Double(used) / Double(limit)) * 100)
        }

        let membership = summary.membershipType?.capitalized

        return CursorUsageData(
            isActive: true,
            planName: membership,
            planPercentUsed: planPercentUsed,
            autoPercentUsed: autoPercent,
            apiPercentUsed: apiPercent,
            planUsedUSD: planUsedUSD,
            planLimitUSD: planLimitUSD,
            onDemandUsedUSD: onDemandUsedUSD,
            onDemandLimitUSD: onDemandLimitUSD,
            billingCycleEnd: billingCycleEnd,
            requestsUsed: requestsUsed,
            requestsLimit: requestsLimit,
            requestPercentUsed: requestPercent,
            accountEmail: userInfo?.email,
            accountName: userInfo?.name)
    }

    private static func normPct(_ value: Double?) -> Double? {
        guard let v = value else { return nil }
        if v < 0 { return 0 }
        if v > 100 { return 100 }
        return v
    }

    private static func clampPercent(_ value: Double) -> Double {
        max(0, min(100, value))
    }

    private static func parseISO8601(_ dateString: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: dateString) ?? ISO8601DateFormatter().date(from: dateString)
    }
}
