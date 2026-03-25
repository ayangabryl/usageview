import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @Bindable var store: AccountStore
    var sparkle: SparkleUpdater

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var autoRefreshInterval: Int = UserDefaults.standard.integer(forKey: "autoRefreshMinutes")
    @State private var allowClaudeCLIKeychainAccess: Bool = UserDefaults.standard.bool(forKey: "allowClaudeCLIKeychainAccess")
    @State private var allowGeminiCLIKeychainAccess: Bool = UserDefaults.standard.bool(forKey: "allowGeminiCLIKeychainAccess")
    @State private var editingAccountId: UUID? = nil
    @State private var editingLabel: String = ""
    @State private var showResetConfirmation = false
    @State private var selectedTab: SettingsTab = .accounts

    enum SettingsTab: String, CaseIterable {
        case accounts = "Accounts"
        case general = "General"
        case about = "About"

        var icon: String {
            switch self {
            case .accounts: "person.2.fill"
            case .general: "gearshape.fill"
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

    // MARK: - General Content

    private var generalContent: some View {
        VStack(alignment: .leading, spacing: 16) {
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

            // Claude Weekly Limit
            settingsRow(icon: "calendar.badge.clock", title: "Weekly Limit", subtitle: "Show Claude 7-day rate window alongside the 5-hour window") {
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

            // Claude CLI Keychain Access
            settingsRow(icon: "key.fill", title: "Claude CLI Keychain", subtitle: "Allow Usageview to read Claude CLI credentials from Keychain (may trigger macOS prompt)") {
                Toggle("", isOn: Binding(
                    get: { allowClaudeCLIKeychainAccess },
                    set: { newValue in
                        allowClaudeCLIKeychainAccess = newValue
                        UserDefaults.standard.set(newValue, forKey: "allowClaudeCLIKeychainAccess")
                        if newValue {
                            store.claudeAuth.resetCLIKeychainReadSuppression()
                        }
                    }
                ))
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            if allowClaudeCLIKeychainAccess && store.claudeAuth.isCLIKeychainReadSuppressed {
                Text("Claude keychain access not granted yet. Toggle off/on to retry.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 48)
                    .padding(.top, -8)
            }

            // Gemini CLI Keychain Access
            settingsRow(icon: "key.horizontal.fill", title: "Gemini CLI Keychain", subtitle: "Allow Usageview to read Gemini CLI credentials from Keychain (may trigger macOS prompt)") {
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
                    .padding(.leading, 48)
                    .padding(.top, -8)
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
                    UserDefaults.standard.removeObject(forKey: "allowGeminiCLIKeychainAccess")
                    autoRefreshInterval = 0
                    allowClaudeCLIKeychainAccess = false
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
