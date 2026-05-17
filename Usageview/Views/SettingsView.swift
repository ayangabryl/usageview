import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @Bindable var store: AccountStore
    var sparkle: SparkleUpdater

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var autoRefreshInterval: Int = UserDefaults.standard.integer(forKey: "autoRefreshMinutes")
    @State private var allowClaudeCLIKeychainAccess: Bool = UserDefaults.standard.bool(forKey: "allowClaudeCLIKeychainAccess")
    @State private var claudeKeychainPromptModeRaw: String = UserDefaults.standard.string(forKey: "claudeOAuthKeychainPromptMode")
        ?? ClaudeKeychainPromptMode.onlyOnUserAction.rawValue
    @State private var allowGeminiCLIKeychainAccess: Bool = UserDefaults.standard.bool(forKey: "allowGeminiCLIKeychainAccess")
    @State private var cursorCookieSourceRaw: String = UserDefaults.standard.string(forKey: "cursorCookieSource") ?? CursorSettings.CookieSource.auto.rawValue
    @State private var cursorManualCookieHeader: String = UserDefaults.standard.string(forKey: "cursorManualCookieHeader") ?? ""
    @State private var claudeKeychainReadStrategyRaw: String = UserDefaults.standard.string(forKey: "claudeOAuthKeychainReadStrategy")
        ?? ClaudeKeychainReadStrategy.securityCLIExperimental.rawValue
    @State private var claudeKeychainStatusMessage: String?
    @State private var keychainFixBannerMessage: String?
    @State private var keychainMoreOptionsExpanded = false
    @State private var editingAccountId: UUID? = nil
    @State private var editingLabel: String = ""
    @State private var showResetConfirmation = false
    @State private var selectedTab: SettingsTab = .accounts

    enum SettingsTab: String, CaseIterable {
        case accounts = "Accounts"
        case general = "General"
        case providers = "Providers"
        case about = "About"

        var icon: String {
            switch self {
            case .accounts: "person.2.fill"
            case .general: "gearshape.fill"
            case .providers: "slider.horizontal.3"
            case .about: "info.circle"
            }
        }
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab(SettingsTab.accounts.rawValue, systemImage: SettingsTab.accounts.icon, value: .accounts) {
                ScrollView {
                    accountsContent
                        .padding(24)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }

            Tab(SettingsTab.general.rawValue, systemImage: SettingsTab.general.icon, value: .general) {
                ScrollView {
                    generalContent
                        .padding(24)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }

            Tab(SettingsTab.providers.rawValue, systemImage: SettingsTab.providers.icon, value: .providers) {
                ScrollView {
                    providersContent
                        .padding(24)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }

            Tab(SettingsTab.about.rawValue, systemImage: SettingsTab.about.icon, value: .about) {
                ScrollView {
                    aboutContent
                        .padding(24)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
        .tabViewStyle(.automatic)
    }

    // MARK: - Accounts Content

    private var accountsContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Drag to reorder. Rename your connected accounts.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if store.accounts.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "person.crop.circle.badge.questionmark")
                        .font(.system(size: 32))
                        .foregroundStyle(.quaternary)
                    Text("No accounts yet")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                    Text("Add accounts from the menu bar dropdown.")
                        .font(.caption)
                        .foregroundStyle(.quaternary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                let ordered = store.orderedAccounts
                List {
                    ForEach(ordered) { account in
                        accountRow(account)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 3, leading: 0, bottom: 3, trailing: 0))
                    }
                    .onMove { from, to in
                        store.ensureOrderIntegrity()
                        store.accountOrder.move(fromOffsets: from, toOffset: to)
                    }
                }
                .listStyle(.plain)
                .frame(minHeight: CGFloat(ordered.count) * 60, maxHeight: 400)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func accountRow(_ account: Account) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.quaternary)
                .frame(width: 16)

            ServiceIconView(
                serviceType: account.serviceType,
                avatarURL: account.avatarURL,
                size: 28
            )

            if editingAccountId == account.id {
                TextField("Account name", text: $editingLabel, onCommit: {
                    commitRename(for: account.id)
                })
                .textFieldStyle(.roundedBorder)
                .font(.subheadline)

                Button {
                    commitRename(for: account.id)
                } label: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                .buttonStyle(.plain)

                Button {
                    editingAccountId = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.label.isEmpty
                        ? (account.username ?? account.serviceType.displayName)
                        : account.label)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)

                    HStack(spacing: 4) {
                        Circle()
                            .fill(store.isConnected(for: account) ? .green : .gray)
                            .frame(width: 6, height: 6)
                        Text(store.isConnected(for: account) ? "Connected" : "Disconnected")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("·")
                            .foregroundStyle(.quaternary)
                        Text(account.serviceType.displayName)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer()

                Button {
                    editingLabel = account.label.isEmpty
                        ? (account.username ?? account.serviceType.displayName)
                        : account.label
                    editingAccountId = account.id
                } label: {
                    Image(systemName: "pencil.line")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Rename")
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    private func commitRename(for id: UUID) {
        let trimmed = editingLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            store.renameAccount(id: id, label: trimmed)
        }
        editingAccountId = nil
    }

    // MARK: - Keychain quick fix (non-technical users)

    private var keychainQuickFixCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Label("Password prompts", systemImage: "lock.shield")
                    .font(.headline)
                Text("If macOS keeps asking for Keychain access, start with the first fix below.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 0) {
                keychainFixRow(
                    icon: "checkmark.shield.fill",
                    title: "Fix saved account prompts",
                    detail: "Repairs stored tokens (e.g. github-token). Click Always Allow once if macOS asks.",
                    buttonTitle: "Run",
                    isProminent: true,
                    action: repairSavedAccountTokens
                )

                keychainRowDivider

                keychainFixRow(
                    icon: "terminal.fill",
                    title: "Link Claude Code",
                    detail: "One-time setup to read Claude CLI credentials from Keychain.",
                    buttonTitle: "Set up",
                    action: connectClaudeCodeOnce
                )

                keychainRowDivider

                DisclosureGroup(isExpanded: $keychainMoreOptionsExpanded) {
                    VStack(spacing: 0) {
                        keychainFixRow(
                            icon: "bell.slash.fill",
                            title: "Stop CLI password popups",
                            detail: "Disables Claude and Gemini CLI Keychain reads only — not browser import.",
                            buttonTitle: "Turn off",
                            action: applyStopPasswordPopups
                        )

                        keychainRowDivider
                            .padding(.leading, 36)

                        keychainFixRow(
                            icon: "trash.fill",
                            title: "Clean unused entries",
                            detail: "Removes Keychain items left over from deleted accounts.",
                            buttonTitle: "Clean",
                            action: cleanupOrphanedKeychainEntries
                        )
                    }
                    .padding(.top, 8)
                } label: {
                    Text("More options")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                }
                .padding(.vertical, 10)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(.primary.opacity(0.06), lineWidth: 1)
            )

            if let keychainFixBannerMessage {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 1)
                    Text(keychainFixBannerMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var keychainRowDivider: some View {
        Divider()
            .padding(.leading, 36)
    }

    private func keychainFixRow(
        icon: String,
        title: String,
        detail: String,
        buttonTitle: String,
        isProminent: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(isProminent ? Color.accentColor : .secondary)
                .frame(width: 24, alignment: .center)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Group {
                if isProminent {
                    Button(buttonTitle, action: action)
                        .buttonStyle(.borderedProminent)
                } else {
                    Button(buttonTitle, action: action)
                        .buttonStyle(.bordered)
                }
            }
            .controlSize(.small)
            .fixedSize()
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    private func applyStopPasswordPopups() {
        KeychainPromptFixer.stopPasswordPopups(
            claudeAuth: store.claudeAuth,
            geminiOAuth: store.geminiAuth.oauthService
        )
        allowClaudeCLIKeychainAccess = false
        allowGeminiCLIKeychainAccess = false
        claudeKeychainPromptModeRaw = ClaudeKeychainPromptMode.never.rawValue
        claudeKeychainReadStrategyRaw = ClaudeKeychainReadStrategy.securityCLIExperimental.rawValue
        ClaudeKeychainReadStrategyPreference.set(.securityCLIExperimental)
        claudeKeychainStatusMessage = nil
        keychainFixBannerMessage = "CLI Keychain access is off. Popups from Usageview should stop."
        KeychainPromptFixer.showStopPopupsConfirmation()
    }

    private func cleanupOrphanedKeychainEntries() {
        let removed = KeychainPromptFixer.cleanupOrphanedKeychainEntries(
            activeAccountIds: Set(store.accounts.map(\.id))
        )
        KeychainPromptFixer.showOrphanCleanupResult(removed: removed)
        if removed > 0 {
            keychainFixBannerMessage = "Removed \(removed) unused Keychain item(s) from deleted accounts."
        }
    }

    private func repairSavedAccountTokens() {
        let result = KeychainPromptFixer.repairSavedAccountTokens()
        KeychainPromptFixer.showSavedAccountRepairResult(fixed: result.fixed, total: result.total)
        keychainFixBannerMessage = result.total == 0
            ? nil
            : "Repaired \(result.fixed) of \(result.total) saved token(s). Quit and reopen Usageview if popups continue."
    }

    private func connectClaudeCodeOnce() {
        KeychainPromptFixer.prepareClaudeCodeOneTimeAccess(claudeAuth: store.claudeAuth)
        allowClaudeCLIKeychainAccess = true
        claudeKeychainPromptModeRaw = ClaudeKeychainPromptMode.onlyOnUserAction.rawValue
        KeychainPromptFixer.showClaudeCodeSetupInstructions()

        let connected = store.claudeAuth.connectClaudeCodeKeychainOnce()
        KeychainPromptFixer.showClaudeCodeConnectResult(success: connected)
        keychainFixBannerMessage = connected
            ? "Claude Code is linked. If popups continue, choose Always Allow on the next macOS dialog."
            : "Could not read Claude Code. Try “Stop password popups” and sign in from the menu bar instead."
    }

    // MARK: - General Content

    private var generalContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            keychainQuickFixCard

            // Menu Bar Icon Style
            settingsRow(icon: "gauge.medium", title: "Icon Style", subtitle: "Choose how the menu bar gauge is rendered") {
                HStack(spacing: 8) {
                    if store.menuBarIconStyle == .colored {
                        ColorPicker("", selection: Binding(
                            get: { store.menuBarIconColor },
                            set: { store.menuBarIconColor = $0 }
                        ), supportsOpacity: false)
                        .labelsHidden()
                        .frame(width: 24, height: 24)
                    }
                    Picker("", selection: Binding(
                        get: { store.menuBarIconStyle },
                        set: { store.menuBarIconStyle = $0 }
                    )) {
                        ForEach(MenuBarIconStyle.allCases, id: \.self) { style in
                            Text(style.displayName).tag(style)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 260)
                }
            }

            // Launch at Login
            settingsRow(icon: "power", title: "Launch at Login", subtitle: "Start Usage automatically when your Mac boots") {
                Toggle("", isOn: $launchAtLogin)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .onChange(of: launchAtLogin) { _, newValue in
                do {
                    if newValue {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                } catch {
                    launchAtLogin = !newValue
                }
            }

            // Default View
            settingsRow(icon: "rectangle.split.3x1", title: "Default View", subtitle: "Choose between expanded or compact layout") {
                Picker("", selection: Binding(
                    get: { store.viewMode },
                    set: { _ in store.toggleViewMode() }
                )) {
                    Text("Expanded").tag(ViewMode.expanded)
                    Text("Compact").tag(ViewMode.compact)
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
            }

            // Auto Refresh
            settingsRow(icon: "arrow.clockwise", title: "Auto Refresh", subtitle: "Automatically refresh usage data periodically") {
                Picker("", selection: $autoRefreshInterval) {
                    Text("Off").tag(0)
                    Text("5 min").tag(5)
                    Text("15 min").tag(15)
                    Text("30 min").tag(30)
                    Text("1 hour").tag(60)
                }
                .pickerStyle(.menu)
                .frame(width: 100)
            }
            .onChange(of: autoRefreshInterval) { _, newValue in
                UserDefaults.standard.set(newValue, forKey: "autoRefreshMinutes")
            }
        }
    }

    private var providersContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Provider-specific settings")
                .font(.headline)

            Text("Tune usage windows, keychain access, and authentication behavior for each provider.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            providerCard(
                serviceType: .claude,
                title: "Claude",
                subtitle: "5-hour/7-day window display and CLI keychain behavior"
            ) {
                settingsRow(
                    icon: "calendar.badge.clock",
                    title: "Show 7-day limit",
                    subtitle: "Show weekly/secondary quota in list rows (Claude 7d, ChatGPT, Codex, Gemini Flash)"
                ) {
                    Toggle("", isOn: Binding(
                        get: { store.showWeeklyLimit },
                        set: { newValue in
                            store.showWeeklyLimit = newValue
                            UserDefaults.standard.set(newValue, forKey: "showWeeklyLimit")
                        }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }

                settingsRow(
                    icon: "key.fill",
                    title: "Claude CLI Keychain",
                    subtitle: "Allow reading Claude CLI credentials from Keychain"
                ) {
                    Toggle("", isOn: Binding(
                        get: { allowClaudeCLIKeychainAccess },
                        set: { newValue in
                            allowClaudeCLIKeychainAccess = newValue
                            UserDefaults.standard.set(newValue, forKey: "allowClaudeCLIKeychainAccess")
                            claudeKeychainStatusMessage = nil
                            if newValue {
                                store.claudeAuth.resetCLIKeychainReadSuppression()
                            }
                        }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }

                settingsRow(
                    icon: "terminal",
                    title: "Keychain Read Strategy",
                    subtitle: "security CLI is recommended (CodexBar default); avoids most password popups"
                ) {
                    Picker("", selection: Binding(
                        get: { claudeKeychainReadStrategyRaw },
                        set: { newValue in
                            claudeKeychainReadStrategyRaw = newValue
                            if let strategy = ClaudeKeychainReadStrategy(rawValue: newValue) {
                                ClaudeKeychainReadStrategyPreference.set(strategy)
                            }
                            store.claudeAuth.resetCLIKeychainReadSuppression()
                        }
                    )) {
                        ForEach(ClaudeKeychainReadStrategy.allCases, id: \.rawValue) { strategy in
                            Text(strategy.displayName).tag(strategy.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 220)
                    .disabled(!allowClaudeCLIKeychainAccess)
                }

                settingsRow(
                    icon: "exclamationmark.shield",
                    title: "Keychain Prompt Mode",
                    subtitle: "Security.framework prompts only when allowed; CLI strategy uses file + security first"
                ) {
                    Picker("", selection: Binding(
                        get: { claudeKeychainPromptModeRaw },
                        set: { newValue in
                            claudeKeychainPromptModeRaw = newValue
                            UserDefaults.standard.set(newValue, forKey: "claudeOAuthKeychainPromptMode")
                            claudeKeychainStatusMessage = nil
                            store.claudeAuth.resetCLIKeychainReadSuppression()
                        }
                    )) {
                        ForEach(ClaudeKeychainPromptMode.allCases, id: \.rawValue) { mode in
                            Text(mode.displayName).tag(mode.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 190)
                    .disabled(!allowClaudeCLIKeychainAccess)
                }

                HStack {
                    Spacer()
                    Button("Test Claude Keychain Access") {
                        let creds = store.claudeAuth.readClaudeCLICredentials(interaction: .userInitiated)
                        if creds != nil {
                            claudeKeychainStatusMessage = "Claude keychain credentials loaded successfully."
                        } else {
                            claudeKeychainStatusMessage = "Could not read credentials (denied, missing, or cooldown active)."
                        }
                    }
                    .controlSize(.small)
                    .disabled(!allowClaudeCLIKeychainAccess)
                }

                if allowClaudeCLIKeychainAccess && store.claudeAuth.isCLIKeychainReadSuppressed {
                    Text("Keychain access was denied in this session. Change mode or retry with the test button.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.top, -4)
                }

                if let claudeKeychainStatusMessage {
                    Text(claudeKeychainStatusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.top, -4)
                }
            }

            providerCard(
                serviceType: .gemini,
                title: "Gemini",
                subtitle: "CLI keychain import preferences"
            ) {
                settingsRow(
                    icon: "key.horizontal.fill",
                    title: "Gemini CLI Keychain",
                    subtitle: "Allow reading Gemini CLI credentials from Keychain"
                ) {
                    Toggle("", isOn: Binding(
                        get: { allowGeminiCLIKeychainAccess },
                        set: { newValue in
                            allowGeminiCLIKeychainAccess = newValue
                            UserDefaults.standard.set(newValue, forKey: "allowGeminiCLIKeychainAccess")
                            if newValue {
                                store.geminiAuth.oauthService.resetCLIKeychainReadSuppression()
                            }
                        }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }

                if allowGeminiCLIKeychainAccess && store.geminiAuth.oauthService.isCLIKeychainReadSuppressed {
                    Text("Gemini keychain access not granted yet. Toggle off/on to retry.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.top, -4)
                }
            }

            providerCard(
                serviceType: .cursor,
                title: "Cursor",
                subtitle: "Browser cookies, cache, and manual session (CodexBar-style)"
            ) {
                settingsRow(
                    icon: "globe",
                    title: "Cookie source",
                    subtitle: "Automatic reads Safari/Chrome; manual uses pasted Cookie header"
                ) {
                    Picker("", selection: Binding(
                        get: { cursorCookieSourceRaw },
                        set: { newValue in
                            cursorCookieSourceRaw = newValue
                            if let source = CursorSettings.CookieSource(rawValue: newValue) {
                                CursorSettings.cookieSource = source
                            }
                        }
                    )) {
                        ForEach(CursorSettings.CookieSource.allCases) { source in
                            Text(source.displayName).tag(source.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 240)
                }

                if cursorCookieSourceRaw == CursorSettings.CookieSource.manual.rawValue {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Manual Cookie header")
                            .font(.caption.weight(.medium))
                        TextField("WorkosCursorSessionToken=… or full Cookie:", text: $cursorManualCookieHeader, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(3...6)
                            .onChange(of: cursorManualCookieHeader) { _, newValue in
                                CursorSettings.manualCookieHeader = newValue
                            }
                    }
                    .padding(.horizontal, 12)
                }
            }

        }
    }

    // MARK: - About Content

    private var aboutContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            #if !MAS
            // Check for Updates
            settingsRow(icon: "arrow.triangle.2.circlepath", title: "Check for Updates", subtitle: "Download and install the latest version") {
                Button("Check Now") {
                    sparkle.checkForUpdates()
                }
                .controlSize(.small)
                .disabled(!sparkle.canCheckForUpdates)
            }

            // Auto Updates
            settingsRow(icon: "arrow.clockwise.circle", title: "Automatic Updates", subtitle: "Automatically check for and install updates") {
                Toggle("", isOn: Binding(
                    get: { sparkle.automaticallyChecksForUpdates },
                    set: { sparkle.automaticallyChecksForUpdates = $0 }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
            }

            Divider()
            #endif

            // Reset All Data
            settingsRow(icon: "trash", iconColor: .red, title: "Reset All Data", subtitle: "Remove all accounts, tokens, and cached data") {
                Button("Reset…", role: .destructive) {
                    showResetConfirmation = true
                }
                .controlSize(.small)
            }
            .confirmationDialog(
                "Reset all data?",
                isPresented: $showResetConfirmation,
                titleVisibility: .visible
            ) {
                Button("Reset Everything", role: .destructive) {
                    for account in store.accounts {
                        store.removeAccount(id: account.id)
                    }
                    UserDefaults.standard.removeObject(forKey: "autoRefreshMinutes")
                    UserDefaults.standard.removeObject(forKey: "allowClaudeCLIKeychainAccess")
                    UserDefaults.standard.removeObject(forKey: "claudeOAuthKeychainPromptMode")
                    UserDefaults.standard.removeObject(forKey: "claudeOAuthKeychainDeniedUntil")
                    UserDefaults.standard.removeObject(forKey: "allowGeminiCLIKeychainAccess")
                    autoRefreshInterval = 0
                    allowClaudeCLIKeychainAccess = false
                    claudeKeychainPromptModeRaw = ClaudeKeychainPromptMode.onlyOnUserAction.rawValue
                    allowGeminiCLIKeychainAccess = false
                }
            } message: {
                Text("This will disconnect and remove all accounts. This cannot be undone.")
            }

            Divider()

            // App Info
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Usageview")
                        .font(.subheadline.weight(.medium))
                    Text("AI usage tracker for your menu bar")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0")")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.primary.opacity(0.05), in: Capsule())
            }
        }
    }

    // MARK: - Reusable Settings Row

    private func providerCard<Content: View>(
        serviceType: ServiceType,
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ServiceIconView(serviceType: serviceType, avatarURL: nil, size: 26)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            content()
        }
        .padding(14)
        .background(.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private func settingsRow<Content: View>(
        icon: String,
        iconColor: Color = .secondary,
        title: String,
        subtitle: String,
        @ViewBuilder trailing: () -> Content
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(iconColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            trailing()
        }
        .padding(12)
        .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }
}
