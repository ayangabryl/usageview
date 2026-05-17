import Foundation
import SwiftUI
import AppKit
import os

private let storeLogger = Logger(subsystem: "com.ayangabryl.usage", category: "AccountStore")

enum ViewMode: String, CaseIterable {
    case expanded
    case compact
}

@Observable
@MainActor
final class AccountStore {
    var accounts: [Account] = []
    var refreshingIds: Set<UUID> = []
    var viewMode: ViewMode = .expanded
    var showWeeklyLimit: Bool = false
    /// Incremented after every save to force SwiftUI re-render in MenuBarExtra
    var dataVersion: Int = 0

    /// Brief green checkmark flash on the menu bar icon when an account is linked.
    var showMenuBarCheckmark: Bool = false
    private var checkmarkTask: Task<Void, Never>?

    /// Animated sweep override for the menu bar gauge. `nil` = use real value.
    var sweepOverridePercent: Double?
    private var sweepTask: Task<Void, Never>?



    /// The account pinned to the menu bar icon. When set, the gauge tracks this account only.
    var pinnedAccountId: UUID? {
        didSet {
            if let id = pinnedAccountId {
                UserDefaults.standard.set(id.uuidString, forKey: "pinnedAccountId")
            } else {
                UserDefaults.standard.removeObject(forKey: "pinnedAccountId")
            }
            dataVersion += 1
        }
    }

    /// The menu bar icon style.
    var menuBarIconStyle: MenuBarIconStyle = .dynamic {
        didSet {
            UserDefaults.standard.set(menuBarIconStyle.rawValue, forKey: "menuBarIconStyle")
            dataVersion += 1
        }
    }

    /// Custom display order of accounts (by UUID). Persisted to UserDefaults.
    var accountOrder: [UUID] = [] {
        didSet {
            let strings = accountOrder.map { $0.uuidString }
            UserDefaults.standard.set(strings, forKey: "accountOrder")
            dataVersion += 1
        }
    }

    /// Custom color for the "Colored" icon style. Stored as hex string.
    var menuBarIconColor: Color = Color(red: 0.38, green: 0.52, blue: 1.0) {
        didSet {
            if let hex = menuBarIconColor.toHex() {
                UserDefaults.standard.set(hex, forKey: "menuBarIconColor")
            }
            dataVersion += 1
        }
    }

    let githubAuth: GitHubAuthService
    let claudeAuth: AnthropicAuthService
    let openaiAuth: OpenAIAuthService
    let geminiAuth: GeminiAuthService
    let kimiAuth: KimiAuthService
    let cursorAuth: CursorAuthService
    let openrouterAuth: OpenRouterAuthService
    let kiroAuth: KiroAuthService
    let augmentAuth: AugmentAuthService
    let jetbrainsAuth: JetBrainsAuthService
    let codexAuth: CodexAuthService
    let zaiAuth: ZaiAuthService
    private let githubUsage: GitHubUsageService
    private let claudeUsage: AnthropicUsageService
    private let openaiUsage: OpenAIUsageService
    private let geminiUsage: GeminiUsageService
    private let kimiUsage: KimiUsageService
    private let cursorUsage: CursorUsageService
    private let openrouterUsage: OpenRouterUsageService
    private let kiroUsage: KiroUsageService
    private let augmentUsage: AugmentUsageService
    private let jetbrainsUsage: JetBrainsUsageService
    private let codexUsage: CodexUsageService
    private let zaiUsage: ZaiUsageService
    private let storageKey = "accounts_data_v3"

    init() {
        let gh = GitHubAuthService()
        let cl = AnthropicAuthService()
        let oa = OpenAIAuthService()
        let ge = GeminiAuthService()
        let ki = KimiAuthService()
        let cu = CursorAuthService()
        let or = OpenRouterAuthService()
        let kr = KiroAuthService()
        let au = AugmentAuthService()
        let jb = JetBrainsAuthService()
        let cx = CodexAuthService()
        let za = ZaiAuthService()
        self.githubAuth = gh
        self.claudeAuth = cl
        self.openaiAuth = oa
        self.geminiAuth = ge
        self.kimiAuth = ki
        self.cursorAuth = cu
        self.openrouterAuth = or
        self.kiroAuth = kr
        self.augmentAuth = au
        self.jetbrainsAuth = jb
        self.codexAuth = cx
        self.zaiAuth = za
        self.githubUsage = GitHubUsageService(authService: gh)
        self.claudeUsage = AnthropicUsageService(authService: cl)
        self.openaiUsage = OpenAIUsageService(authService: oa)
        self.geminiUsage = GeminiUsageService(authService: ge)
        self.kimiUsage = KimiUsageService(authService: ki)
        self.cursorUsage = CursorUsageService(authService: cu)
        self.openrouterUsage = OpenRouterUsageService(authService: or)
        self.kiroUsage = KiroUsageService(authService: kr)
        self.augmentUsage = AugmentUsageService(authService: au)
        self.jetbrainsUsage = JetBrainsUsageService(authService: jb)
        self.codexUsage = CodexUsageService(authService: cx)
        self.zaiUsage = ZaiUsageService(authService: za)
        if let mode = UserDefaults.standard.string(forKey: "viewMode"),
           let m = ViewMode(rawValue: mode) {
            viewMode = m
        }
        showWeeklyLimit = UserDefaults.standard.bool(forKey: "showWeeklyLimit")
        if let pinStr = UserDefaults.standard.string(forKey: "pinnedAccountId"),
           let pinId = UUID(uuidString: pinStr) {
            pinnedAccountId = pinId
        }
        if let styleStr = UserDefaults.standard.string(forKey: "menuBarIconStyle"),
           let style = MenuBarIconStyle(rawValue: styleStr) {
            menuBarIconStyle = style
        }
        if let hex = UserDefaults.standard.string(forKey: "menuBarIconColor") {
            menuBarIconColor = Color(hex: hex)
        }
        if let orderStrings = UserDefaults.standard.stringArray(forKey: "accountOrder") {
            accountOrder = orderStrings.compactMap { UUID(uuidString: $0) }
        }
        load()
        KeychainMigration.cleanupOrphanedTokens(keepingAccountIds: Set(accounts.map(\.id)))
    }

    // MARK: - Persistence

    func save() {
        if let data = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
        dataVersion += 1
    }

    func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([Account].self, from: data)
        else { return }
        accounts = decoded
        migrateLegacyCodexAccountsIfNeeded()
    }

    /// Codex is tracked under OpenAI (Codex CLI auth method).
    private func migrateLegacyCodexAccountsIfNeeded() {
        var migrated = false
        for index in accounts.indices where accounts[index].serviceType == .codex {
            accounts[index].serviceType = .chatgpt
            accounts[index].authMethod = .codexCLI
            migrated = true
        }
        if migrated { save() }
    }

    // MARK: - Account Management

    @discardableResult
    func addAccount(serviceType: ServiceType, authMethod: AuthMethod = .oauth) -> Account {
        let account = Account(
            id: UUID(),
            serviceType: serviceType,
            authMethod: authMethod,
            label: "",
            currentUsage: 0,
            usageLimit: serviceType.defaultLimit,
            usageUnit: serviceType.defaultUsageUnit,
            resetDate: .now
        )
        accounts.append(account)
        accountOrder.append(account.id)
        save()
        return account
    }

    func removeAccount(id: UUID) {
        guard let account = accounts.first(where: { $0.id == id }) else { return }
        switch account.serviceType {
        case .claude: claudeAuth.disconnect(accountId: id)
        case .copilot: githubAuth.disconnect(accountId: id)
        case .chatgpt: disconnectOpenAI(accountId: id, authMethod: account.authMethod)
        case .gemini: geminiAuth.disconnect(accountId: id)
        case .kimi: kimiAuth.disconnect(accountId: id)
        case .cursor: cursorAuth.disconnect(accountId: id)
        case .openrouter: openrouterAuth.disconnect(accountId: id)
        case .kiro: kiroAuth.disconnect(accountId: id)
        case .augment: augmentAuth.disconnect(accountId: id)
        case .jetbrainsAI: jetbrainsAuth.disconnect(accountId: id)
        case .codex: codexAuth.disconnect(accountId: id)
        case .zai: zaiAuth.disconnect(accountId: id)
        }
        accounts.removeAll { $0.id == id }
        accountOrder.removeAll { $0 == id }
        save()
    }

    /// Disconnect an account (remove tokens but keep the account entry)
    func disconnectAccount(id: UUID) {
        guard let account = accounts.first(where: { $0.id == id }) else { return }
        switch account.serviceType {
        case .claude: claudeAuth.disconnect(accountId: id)
        case .copilot: githubAuth.disconnect(accountId: id)
        case .chatgpt: disconnectOpenAI(accountId: id, authMethod: account.authMethod)
        case .gemini: geminiAuth.disconnect(accountId: id)
        case .kimi: kimiAuth.disconnect(accountId: id)
        case .cursor: cursorAuth.disconnect(accountId: id)
        case .openrouter: openrouterAuth.disconnect(accountId: id)
        case .kiro: kiroAuth.disconnect(accountId: id)
        case .augment: augmentAuth.disconnect(accountId: id)
        case .jetbrainsAI: jetbrainsAuth.disconnect(accountId: id)
        case .codex: codexAuth.disconnect(accountId: id)
        case .zai: zaiAuth.disconnect(accountId: id)
        }
        if let index = accounts.firstIndex(where: { $0.id == id }) {
            accounts[index].username = nil
            accounts[index].avatarURL = nil
            accounts[index].currentUsage = 0
            save()
        }
    }

    func updateAccountAfterConnect(id: UUID, username: String?, avatarURL: String?, authMethod: AuthMethod? = nil, isDemoKey: Bool = false) {
        if let index = accounts.firstIndex(where: { $0.id == id }) {
            accounts[index].username = username
            accounts[index].avatarURL = avatarURL
            if let authMethod {
                accounts[index].authMethod = authMethod
            }
            if let username, accounts[index].label.isEmpty {
                accounts[index].label = username
            }
            // Detect demo key by checking keychain right after it was saved
            if isDemoKey || hasStoredDemoKey(for: id) {
                accounts[index].isDemoAccount = true
            }
            save()
            flashMenuBarCheckmark()
        }
    }

    /// Check if any API-key-capable service has the magic demo key stored for this account.
    private func hasStoredDemoKey(for accountId: UUID) -> Bool {
        let key = DemoDataService.magicKey
        return claudeAuth.getAPIKey(for: accountId) == key
            || openaiAuth.getAPIKey(for: accountId) == key
            || geminiAuth.getAPIKey(for: accountId) == key
            || openrouterAuth.getAPIKey(for: accountId) == key
            || kimiAuth.getAPIKey(for: accountId) == key
            || kiroAuth.getAPIKey(for: accountId) == key
            || augmentAuth.getAPIKey(for: accountId) == key
            || zaiAuth.getAPIKey(for: accountId) == key
    }

    /// Briefly show a green checkmark, then sweep the gauge from 0 → actual%.
    private func flashMenuBarCheckmark() {
        checkmarkTask?.cancel()
        sweepTask?.cancel()
        showMenuBarCheckmark = true
        sweepOverridePercent = 0  // Lock gauge at 0% immediately to prevent flash
        dataVersion += 1

        checkmarkTask = Task {
            // Show checkmark for 1.5s
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            showMenuBarCheckmark = false
            dataVersion += 1

            // Now sweep from 0 → actual percent
            let targetPercent = menuBarPercent ?? 0
            await animateSweep(to: targetPercent)
        }
    }

    /// Animate the gauge fill from 0% to the target over ~0.8s with ease-out.
    private func animateSweep(to target: Double) async {
        sweepTask?.cancel()
        let duration: Double = 0.8  // seconds
        let fps: Double = 30
        let totalFrames = Int(duration * fps)

        sweepOverridePercent = 0
        dataVersion += 1

        sweepTask = Task {
            for frame in 1...totalFrames {
                guard !Task.isCancelled else { break }
                try? await Task.sleep(for: .milliseconds(Int(1000 / fps)))
                let progress = Double(frame) / Double(totalFrames)
                // Ease-out cubic: fast start, gentle stop
                let eased = 1 - pow(1 - progress, 3)
                sweepOverridePercent = target * eased
                dataVersion += 1
            }
            // Snap to real value and clear override
            sweepOverridePercent = nil
            dataVersion += 1
        }
    }

    func renameAccount(id: UUID, label: String) {
        if let index = accounts.firstIndex(where: { $0.id == id }) {
            accounts[index].label = label
            save()
        }
    }

    // MARK: - Refresh

    /// Returns true if this account was connected with the App Review demo key.
    /// Checks the persisted flag first; falls back to a live keychain read and
    /// marks the account if the key is found (handles old accounts or missed saves).
    private func isDemoKey(for account: Account) -> Bool {
        if account.isDemoAccount { return true }
        guard hasStoredDemoKey(for: account.id) else { return false }
        // Mark flag for future refreshes
        if let index = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[index].isDemoAccount = true
            save()
        }
        return true
    }

    /// Populate an account with mock data from DemoDataService (used by App Review).
    private func applyDemoData(for account: Account) {
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        let snap = DemoDataService.snapshot(for: account.serviceType)
        accounts[index].isDemoAccount = true
        accounts[index].username = snap.username
        accounts[index].planName = snap.planName
        accounts[index].organizationName = snap.organizationName
        accounts[index].currentUsage = snap.currentUsage
        accounts[index].usageLimit = snap.usageLimit
        accounts[index].usageUnit = snap.usageUnit
        accounts[index].resetDate = snap.resetDate
        accounts[index].fiveHourUsage = snap.fiveHourUsage
        accounts[index].fiveHourResetDate = snap.fiveHourResetDate
        accounts[index].sevenDayUsage = snap.sevenDayUsage
        accounts[index].sevenDayResetDate = snap.sevenDayResetDate
        accounts[index].openRouterTotalCredits = snap.openRouterTotalCredits
        accounts[index].openRouterTotalUsage = snap.openRouterTotalUsage
        accounts[index].monthlySpendUSD = nil
        accounts[index].monthlySpendLimitUSD = nil
        accounts[index].openAICreditsBalance = nil
        accounts[index].openAICreditsUnlimited = nil
        accounts[index].todayTokenCount = nil
        accounts[index].last30DayTokenCount = nil
        save()
    }

    private func recordSpendSnapshot(index: Int, cumulativeUSD: Double) {
        let key = Self.spendDayKey(for: Date())
        if accounts[index].spendHistoryByDay == nil {
            accounts[index].spendHistoryByDay = [:]
        }
        accounts[index].spendHistoryByDay?[key] = max(cumulativeUSD, 0)

        let cutoff = Calendar.current.date(byAdding: .day, value: -45, to: Date()) ?? Date.distantPast
        let cutoffKey = Self.spendDayKey(for: cutoff)
        accounts[index].spendHistoryByDay = accounts[index].spendHistoryByDay?.filter { $0.key >= cutoffKey }
    }

    private func replaceSpendHistory(index: Int, cumulativeByDay: [String: Double]) {
        let cutoff = Calendar.current.date(byAdding: .day, value: -45, to: Date()) ?? Date.distantPast
        let cutoffKey = Self.spendDayKey(for: cutoff)
        accounts[index].spendHistoryByDay = cumulativeByDay.filter { $0.key >= cutoffKey }
    }

    private static func spendDayKey(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    func refreshAccount(_ account: Account) async {
        refreshingIds.insert(account.id)
        defer { refreshingIds.remove(account.id) }

        // App Review demo mode: if the account's API key is the magic demo key,
        // return mock data instead of making real network calls.
        if isDemoKey(for: account) {
            applyDemoData(for: account)
            return
        }

        switch account.serviceType {
        case .copilot:
            if let usage = await githubUsage.fetchCopilotUsage(for: account.id) {
                if let index = accounts.firstIndex(where: { $0.id == account.id }) {
                    accounts[index].usageLimit = usage.entitlement
                    accounts[index].currentUsage = usage.used
                    accounts[index].usageUnit = "premium requests"
                    accounts[index].planName = usage.plan?.capitalized
                    if let reset = usage.resetDate {
                        accounts[index].resetDate = reset
                    }
                    // Store chat quota
                    if let chatPct = usage.chatPercentRemaining {
                        accounts[index].chatPercentRemaining = chatPct
                        accounts[index].chatLimit = usage.chatEntitlement
                        accounts[index].chatUsage = max(0, 100 - chatPct)
                    }
                    save()
                }
            }

        case .claude:
            if account.authMethod == .apiKey {
                // API key: verify it's still valid
                let valid = await claudeAuth.verifyAPIKey(for: account.id)
                if let index = accounts.firstIndex(where: { $0.id == account.id }) {
                    accounts[index].usageUnit = valid ? "Connected" : "Inactive"
                    save()
                }
            } else {
                // Fetch usage
                let usage = await claudeUsage.fetchUsage(for: account.id)

                if let usage {
                    if let index = accounts.firstIndex(where: { $0.id == account.id }) {
                        // Store both windows (API returns percentages directly, e.g. 31.0 = 31%)
                        accounts[index].fiveHourUsage = usage.fiveHourUtilization
                        accounts[index].fiveHourResetDate = usage.fiveHourResetsAt
                        accounts[index].sevenDayUsage = usage.sevenDayUtilization
                        accounts[index].sevenDayResetDate = usage.sevenDayResetsAt

                        // Show the binding constraint (whichever window is fuller)
                        if usage.sevenDayUtilization >= usage.fiveHourUtilization {
                            accounts[index].currentUsage = usage.sevenDayUtilization
                            if let reset = usage.sevenDayResetsAt {
                                accounts[index].resetDate = reset
                            }
                        } else {
                            accounts[index].currentUsage = usage.fiveHourUtilization
                            if let reset = usage.fiveHourResetsAt {
                                accounts[index].resetDate = reset
                            }
                        }
                        accounts[index].usageLimit = 100
                        accounts[index].usageUnit = "% used"

                        // Plan tier from usage response
                        if let plan = usage.planTier {
                            accounts[index].planName = plan
                        }
                        if let org = usage.organizationName {
                            accounts[index].organizationName = org
                        }
                        accounts[index].monthlySpendUSD = usage.monthlySpendUSD ?? 0
                        accounts[index].monthlySpendLimitUSD = usage.monthlySpendLimitUSD
                        accounts[index].todayTokenCount = nil
                        accounts[index].last30DayTokenCount = nil
                        recordSpendSnapshot(index: index, cumulativeUSD: usage.monthlySpendUSD ?? 0)

                        if let local = claudeUsage.fetchLocalUsageSummary(lastDays: 30) {
                            accounts[index].monthlySpendUSD = max(accounts[index].monthlySpendUSD ?? 0, local.last30DayCostUSD)
                            accounts[index].todayTokenCount = local.todayTokens
                            accounts[index].last30DayTokenCount = local.last30DayTokens
                            replaceSpendHistory(index: index, cumulativeByDay: local.dailyCumulativeSpendByDay)
                        }
                    }
                }
                save()
            }

        case .chatgpt:
            storeLogger.info("ChatGPT refresh: authMethod=\(account.authMethod.rawValue, privacy: .public) id=\(account.id)")
            if account.authMethod == .codexCLI {
                await refreshCodexCLIUsage(for: account)
                return
            }
            if account.authMethod == .apiKey {
                // API key: verify it's still valid
                let valid = await openaiAuth.verifyAPIKey(for: account.id)
                if let index = accounts.firstIndex(where: { $0.id == account.id }) {
                    accounts[index].usageUnit = valid ? "Connected" : "Inactive"
                    save()
                }
            } else if let status = await openaiUsage.fetchStatus(for: account.id) {
                if let index = accounts.firstIndex(where: { $0.id == account.id }) {
                    storeLogger.info("ChatGPT store: plan=\(status.planName, privacy: .public) 5h=\(status.fiveHourUsedPercent ?? -1) weekly=\(status.weeklyUsedPercent ?? -1)")
                    accounts[index].planName = status.planName

                    // Store rate limit windows (reuse Claude's dual window fields)
                    if let fiveHour = status.fiveHourUsedPercent {
                        accounts[index].fiveHourUsage = Double(fiveHour)
                        accounts[index].fiveHourResetDate = status.fiveHourResetAt

                        // Primary usage for progress bar
                        accounts[index].currentUsage = Double(fiveHour)
                        accounts[index].usageLimit = 100
                        accounts[index].usageUnit = "% used"
                        if let reset = status.fiveHourResetAt {
                            accounts[index].resetDate = reset
                        }
                    }
                    if let weekly = status.weeklyUsedPercent {
                        accounts[index].sevenDayUsage = Double(weekly)
                        accounts[index].sevenDayResetDate = status.weeklyResetAt
                    }

                    accounts[index].openAICreditsBalance = status.creditsBalance
                    accounts[index].openAICreditsUnlimited = status.creditsUnlimited

                    // If no rate limit data, fall back to status display
                    if status.fiveHourUsedPercent == nil {
                        accounts[index].usageUnit = status.planName
                    }

                    let storedAccount = accounts[index]
                    storeLogger.info("ChatGPT stored: fiveHour=\(storedAccount.fiveHourUsage ?? -1) sevenDay=\(storedAccount.sevenDayUsage ?? -1) isStatusOnly=\(storedAccount.isStatusOnly) hasDualWindows=\(storedAccount.hasDualWindows)")
                    save()
                } else {
                    storeLogger.error("ChatGPT store: account NOT FOUND in array!")
                }
            } else {
                storeLogger.warning("ChatGPT refresh: fetchStatus returned nil")
            }

        case .kimi:
            if let usage = await kimiUsage.fetchUsage(for: account.id) {
                if let index = accounts.firstIndex(where: { $0.id == account.id }) {
                    if usage.hasQuotaData {
                        // Real billing data from Kimi API
                        accounts[index].kimiWeeklyUsed = usage.weeklyUsed
                        accounts[index].kimiWeeklyLimit = usage.weeklyLimit
                        accounts[index].kimiWeeklyResetDate = usage.weeklyResetDate
                        accounts[index].kimiRateLimitUsed = usage.rateLimitUsed
                        accounts[index].kimiRateLimitMax = usage.rateLimitMax
                        accounts[index].kimiRateLimitResetDate = usage.rateLimitResetDate

                        // Use weekly quota as primary usage
                        let weeklyPct = usage.weeklyLimit > 0
                            ? (usage.weeklyUsed / usage.weeklyLimit) * 100
                            : 0
                        accounts[index].currentUsage = weeklyPct
                        accounts[index].usageLimit = 100
                        accounts[index].usageUnit = "% used"
                        if let reset = usage.weeklyResetDate {
                            accounts[index].resetDate = reset
                        }
                    } else {
                        accounts[index].usageUnit = usage.isActive ? "Connected" : "Inactive"
                    }
                    save()
                }
            }

        case .gemini:
            if account.authMethod == .oauth {
                // OAuth: fetch real quota data from Gemini CLI credentials
                if let usage = await geminiUsage.fetchOAuthUsage(for: account.id) {
                    if let index = accounts.firstIndex(where: { $0.id == account.id }) {
                        // Store Pro as primary (fiveHourUsage) and Flash as secondary (sevenDayUsage)
                        accounts[index].fiveHourUsage = usage.proPercentUsed
                        accounts[index].fiveHourResetDate = usage.proResetDate
                        if let flash = usage.flashPercentUsed {
                            accounts[index].sevenDayUsage = flash
                            accounts[index].sevenDayResetDate = usage.flashResetDate
                        }

                        // Primary usage = binding constraint
                        accounts[index].currentUsage = usage.primaryPercentUsed
                        accounts[index].usageLimit = 100
                        accounts[index].usageUnit = "% used"
                        if let reset = usage.primaryResetDate {
                            accounts[index].resetDate = reset
                        }
                        if let plan = usage.planName {
                            accounts[index].planName = plan
                        }
                        if let email = usage.accountEmail {
                            accounts[index].username = email
                        }
                        save()
                    }
                }
            } else {
                // API key: status-only check
                if let status = await geminiUsage.fetchStatus(for: account.id) {
                    if let index = accounts.firstIndex(where: { $0.id == account.id }) {
                        if status.isActive {
                            let label = status.hasProModels
                                ? "\(status.modelCount) models · Pro"
                                : "\(status.modelCount) models"
                            accounts[index].usageUnit = label
                            accounts[index].planName = status.hasProModels ? "Pro" : "Free"
                        } else {
                            accounts[index].usageUnit = "Inactive"
                        }
                        save()
                    }
                }
            }

        case .cursor:
            if let usage = await cursorUsage.fetchUsage(for: account.id) {
                if let index = accounts.firstIndex(where: { $0.id == account.id }) {
                    accounts[index].currentUsage = usage.planPercentUsed
                    accounts[index].usageLimit = 100
                    accounts[index].fiveHourUsage = usage.autoPercentUsed
                    accounts[index].tertiaryUsage = usage.apiPercentUsed ?? usage.requestPercentUsed
                    accounts[index].planName = usage.planName
                    accounts[index].monthlySpendUSD = usage.planUsedUSD
                    accounts[index].monthlySpendLimitUSD = usage.planLimitUSD > 0 ? usage.planLimitUSD : nil
                    if let reset = usage.billingCycleEnd {
                        accounts[index].resetDate = reset
                    }
                    if usage.hasRequestLane, let used = usage.requestsUsed, let limit = usage.requestsLimit {
                        accounts[index].usageUnit = "\(used)/\(limit) API requests"
                    } else if usage.planLimitUSD > 0 {
                        accounts[index].usageUnit = String(
                            format: "$%.2f / $%.2f plan",
                            usage.planUsedUSD,
                            usage.planLimitUSD)
                    } else {
                        accounts[index].usageUnit = String(format: "%.0f%% Total", usage.planPercentUsed)
                    }
                    if let email = usage.accountEmail ?? usage.accountName {
                        accounts[index].username = email
                    }
                    recordSpendSnapshot(index: index, cumulativeUSD: usage.planUsedUSD)
                    save()
                }
            }

        case .openrouter:
            if let usage = await openrouterUsage.fetchUsage(for: account.id) {
                if let index = accounts.firstIndex(where: { $0.id == account.id }) {
                    if usage.totalCredits > 0 {
                        accounts[index].openRouterTotalCredits = usage.totalCredits
                        accounts[index].openRouterTotalUsage = usage.totalUsage
                        let remaining = max(0, usage.totalCredits - usage.totalUsage)
                        let pct = (usage.totalUsage / usage.totalCredits) * 100
                        accounts[index].currentUsage = pct
                        accounts[index].usageLimit = 100
                        accounts[index].usageUnit = String(format: "$%.2f remaining", remaining)
                        recordSpendSnapshot(index: index, cumulativeUSD: usage.totalUsage)
                    } else {
                        accounts[index].usageUnit = "Connected"
                    }
                    save()
                }
            }

        case .kiro:
            if let usage = await kiroUsage.fetchStatus(for: account.id) {
                if let index = accounts.firstIndex(where: { $0.id == account.id }) {
                    if usage.hasQuotaData {
                        accounts[index].currentUsage = usage.creditsPercent
                        accounts[index].usageLimit = 100
                        accounts[index].usageUnit = "% used"
                        accounts[index].planName = usage.planName
                        if let reset = usage.resetsAt {
                            accounts[index].resetDate = reset
                        }
                    } else {
                        accounts[index].usageUnit = usage.isActive ? "Connected" : "Inactive"
                    }
                    save()
                }
            }

        case .augment:
            if let usage = await augmentUsage.fetchStatus(for: account.id) {
                if let index = accounts.firstIndex(where: { $0.id == account.id }) {
                    accounts[index].usageUnit = usage.isActive ? "Connected" : "Inactive"
                    save()
                }
            }

        case .jetbrainsAI:
            if let usage = await jetbrainsUsage.fetchUsage(for: account.id) {
                if let index = accounts.firstIndex(where: { $0.id == account.id }) {
                    if usage.maximum > 0 {
                        accounts[index].jetbrainsQuotaCurrent = usage.currentUsed
                        accounts[index].jetbrainsQuotaMaximum = usage.maximum
                        accounts[index].jetbrainsQuotaResetDate = usage.resetDate
                        accounts[index].currentUsage = usage.usagePercent
                        accounts[index].usageLimit = 100
                        accounts[index].usageUnit = "% used"
                        if let reset = usage.resetDate {
                            accounts[index].resetDate = reset
                        }
                        if let ide = usage.ideName {
                            accounts[index].planName = ide
                        }
                    } else {
                        accounts[index].usageUnit = usage.isActive ? "Connected" : "Inactive"
                    }
                    save()
                }
            }

        case .codex:
            migrateLegacyCodexAccountsIfNeeded()
            if let migrated = accounts.first(where: { $0.id == account.id }) {
                await refreshAccount(migrated)
            }

        case .zai:
            if let usage = await zaiUsage.fetchUsage(for: account.id) {
                if let index = accounts.firstIndex(where: { $0.id == account.id }) {
                    accounts[index].planName = usage.planName
                    if let token = usage.tokenUsedPercent {
                        accounts[index].fiveHourUsage = token
                        accounts[index].fiveHourResetDate = usage.tokenResetAt
                    }
                    if let mcp = usage.mcpUsedPercent {
                        accounts[index].sevenDayUsage = mcp
                        accounts[index].sevenDayResetDate = usage.mcpResetAt
                    }
                    if let session = usage.sessionUsedPercent {
                        accounts[index].tertiaryUsage = session
                        accounts[index].tertiaryResetDate = usage.sessionResetAt
                    }
                    accounts[index].currentUsage = usage.primaryPercent
                    accounts[index].usageLimit = 100
                    accounts[index].usageUnit = "% used"
                    if let reset = usage.tokenResetAt ?? usage.sessionResetAt ?? usage.mcpResetAt {
                        accounts[index].resetDate = reset
                    }
                    save()
                }
            }
        }
    }

    func refreshAll() async {
        let connected = accounts.filter { isConnected(for: $0) }
        await withTaskGroup(of: Void.self) { group in
            for account in connected {
                group.addTask { @MainActor in
                    await self.refreshAccount(account)
                }
            }
        }
    }

    // MARK: - Status

    func isConnected(for account: Account) -> Bool {
        switch account.serviceType {
        case .claude: claudeAuth.isAuthenticated(for: account.id)
        case .copilot: githubAuth.isAuthenticated(for: account.id)
        case .chatgpt:
            switch account.authMethod {
            case .codexCLI: codexAuth.isAuthenticated(for: account.id)
            case .oauth, .apiKey: openaiAuth.isAuthenticated(for: account.id)
            }
        case .gemini: geminiAuth.isAuthenticated(for: account.id)
        case .kimi: kimiAuth.isAuthenticated(for: account.id)
        case .cursor: cursorAuth.isAuthenticated(for: account.id)
        case .openrouter: openrouterAuth.isAuthenticated(for: account.id)
        case .kiro: kiroAuth.isAuthenticated(for: account.id)
        case .augment: augmentAuth.isAuthenticated(for: account.id)
        case .jetbrainsAI: jetbrainsAuth.isAuthenticated(for: account.id)
        case .codex: codexAuth.isAuthenticated(for: account.id)
        case .zai: zaiAuth.isAuthenticated(for: account.id)
        }
    }

    func isRefreshing(for account: Account) -> Bool {
        refreshingIds.contains(account.id)
    }

    /// The account whose usage drives the menu bar display.
    var menuBarAccount: Account? {
        if let pinnedId = pinnedAccountId,
           let account = accounts.first(where: { $0.id == pinnedId }) {
            return account
        }
        return orderedAccounts.first(where: { isConnected(for: $0) && !$0.isStatusOnly })
    }

    var menuBarLabel: String {
        guard let target = menuBarAccount else { return "—" }
        let pct = accountUsagePercent(target)
        return "\(Int(pct))%"
    }

    func toggleViewMode() {
        viewMode = viewMode == .expanded ? .compact : .expanded
        UserDefaults.standard.set(viewMode.rawValue, forKey: "viewMode")
    }

    /// Accounts grouped by service type
    private func disconnectOpenAI(accountId: UUID, authMethod: AuthMethod) {
        switch authMethod {
        case .codexCLI:
            codexAuth.disconnect(accountId: accountId)
        case .oauth, .apiKey:
            openaiAuth.disconnect(accountId: accountId)
        }
    }

    private func refreshCodexCLIUsage(for account: Account) async {
        guard let usage = await codexUsage.fetchUsage(for: account.id) else { return }
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[index].planName = usage.planName.capitalized
        if let fiveHour = usage.fiveHourUsedPercent {
            accounts[index].fiveHourUsage = Double(fiveHour)
            accounts[index].fiveHourResetDate = usage.fiveHourResetAt
            accounts[index].currentUsage = Double(fiveHour)
            accounts[index].usageLimit = 100
            accounts[index].usageUnit = "% used"
            if let reset = usage.fiveHourResetAt {
                accounts[index].resetDate = reset
            }
        }
        if let weekly = usage.weeklyUsedPercent {
            accounts[index].sevenDayUsage = Double(weekly)
            accounts[index].sevenDayResetDate = usage.weeklyResetAt
        }
        accounts[index].openAICreditsBalance = usage.creditsBalance
        accounts[index].openAICreditsUnlimited = usage.creditsUnlimited
        save()
    }

    var groupedAccounts: [(ServiceType, [Account])] {
        let types = ServiceType.addableCases
        return types.compactMap { type in
            let matching = accounts.filter { $0.serviceType == type }
            return matching.isEmpty ? nil : (type, matching)
        }
    }

    /// Accounts sorted by user-defined order.
    var orderedAccounts: [Account] {
        // Ensure every account has an order entry; append any missing ones
        let knownIds = Set(accountOrder)
        let missing = accounts.filter { !knownIds.contains($0.id) }
        if !missing.isEmpty {
            // Side-effect free: caller should call ensureOrderIntegrity() on load
            return accountOrder.compactMap { id in accounts.first { $0.id == id } } + missing
        }
        return accountOrder.compactMap { id in accounts.first { $0.id == id } }
    }

    /// Ensure every account is in accountOrder and remove stale entries.
    func ensureOrderIntegrity() {
        let accountIds = Set(accounts.map { $0.id })
        var order = accountOrder.filter { accountIds.contains($0) }
        for account in accounts where !order.contains(account.id) {
            order.append(account.id)
        }
        if order != accountOrder {
            accountOrder = order
        }
    }

    /// Move an account up (earlier) in the display order.
    func moveAccountUp(id: UUID) {
        ensureOrderIntegrity()
        guard let idx = accountOrder.firstIndex(of: id), idx > 0 else { return }
        accountOrder.swapAt(idx, idx - 1)
    }

    /// Move an account down (later) in the display order.
    func moveAccountDown(id: UUID) {
        ensureOrderIntegrity()
        guard let idx = accountOrder.firstIndex(of: id), idx < accountOrder.count - 1 else { return }
        accountOrder.swapAt(idx, idx + 1)
    }

    /// Whether the account can be moved up.
    func canMoveUp(id: UUID) -> Bool {
        guard let idx = accountOrder.firstIndex(of: id) else { return false }
        return idx > 0
    }

    /// Whether the account can be moved down.
    func canMoveDown(id: UUID) -> Bool {
        guard let idx = accountOrder.firstIndex(of: id) else { return false }
        return idx < accountOrder.count - 1
    }

    // MARK: - Dynamic Menu Bar Icon

    /// The usage percentage (0–100) for a specific account, using the binding constraint.
    func accountUsagePercent(_ account: Account) -> Double {
        // For dual-window accounts (Claude, ChatGPT, Gemini), use whichever window is fuller
        if let fiveHour = account.fiveHourUsage {
            let sevenDay = account.sevenDayUsage ?? 0
            return max(fiveHour, sevenDay)
        } else if account.usageLimit > 0 {
            return account.usagePercentage * 100
        }
        return 0
    }

    /// The worst-off (highest usage) connected account's percentage (0–100).
    var worstUsagePercent: Double? {
        let connected = accounts.filter { isConnected(for: $0) && !$0.isStatusOnly }
        guard !connected.isEmpty else { return nil }

        var worst: Double = 0
        for account in connected {
            worst = max(worst, accountUsagePercent(account))
        }
        return worst
    }

    /// The percentage to display in the menu bar gauge.
    /// If a specific account is pinned, use that; otherwise use the first ordered account.
    var menuBarPercent: Double? {
        if let pinnedId = pinnedAccountId,
           let account = accounts.first(where: { $0.id == pinnedId }) {
            return accountUsagePercent(account)
        }
        // Fallback: first ordered, connected, non-status-only account
        if let first = orderedAccounts.first(where: { isConnected(for: $0) && !$0.isStatusOnly }) {
            return accountUsagePercent(first)
        }
        return nil
    }

    /// Whether the given account is pinned to the menu bar icon.
    func isPinnedToMenuBar(_ account: Account) -> Bool {
        pinnedAccountId == account.id
    }

    /// Pin or unpin an account from the menu bar icon.
    func togglePinToMenuBar(_ account: Account) {
        if pinnedAccountId == account.id {
            pinnedAccountId = nil
        } else {
            pinnedAccountId = account.id
        }
    }

    /// Generate the current dynamic menu bar icon
    var menuBarIcon: NSImage {
        MenuBarIconRenderer.icon(
            percent: sweepOverridePercent ?? menuBarPercent,
            style: menuBarIconStyle,
            customColor: menuBarIconStyle == .colored ? NSColor(menuBarIconColor) : nil,
            isStale: accounts.isEmpty || accounts.allSatisfy { !isConnected(for: $0) },
            showCheckmark: showMenuBarCheckmark
        )
    }
}
