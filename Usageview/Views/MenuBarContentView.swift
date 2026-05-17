import SwiftUI
import AppKit

struct MenuBarContentView: View {
    @Bindable var store: AccountStore
    @State private var screen: Screen = .main
    @State private var screenHistory: [Screen] = []
    @State private var renamingAccountId: UUID?
    @State private var renameText: String = ""
    @State private var detailTab: DetailTab = .overview
    @State private var showCostBreakdownPopover: Bool = false

    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    enum Screen: Equatable {
        case main
        case pickService
        case pickAuthMethod(UUID, ServiceType)
        case connectGitHub(UUID)
        case connectClaude(UUID)
        case connectClaudeAPIKey(UUID)
        case connectOpenAI(UUID)
        case connectOpenAIAPIKey(UUID)
        case connectGemini(UUID)
        case connectGeminiAPIKey(UUID)
        case connectKimi(UUID)
        case connectCursor(UUID)
        case connectOpenRouter(UUID)
        case connectKiro(UUID)
        case connectAugment(UUID)
        case connectJetBrains(UUID)
        case connectCodex(UUID)
        case connectZai(UUID)
        case accountDetail(UUID)
    }

    enum DetailTab: String, CaseIterable {
        case overview = "Overview"
        case usage = "Usage"
    }

    var body: some View {
        Group {
            switch screen {
            case .main:
                mainView
            case .pickService:
                pickServiceView
            case .pickAuthMethod(let id, let type):
                pickAuthMethodView(accountId: id, serviceType: type)
            case .connectGitHub(let id):
                githubConnectView(accountId: id)
            case .connectClaude(let id):
                claudeConnectView(accountId: id)
            case .connectClaudeAPIKey(let id):
                claudeAPIKeyConnectView(accountId: id)
            case .connectOpenAI(let id):
                openaiConnectView(accountId: id)
            case .connectOpenAIAPIKey(let id):
                openaiAPIKeyConnectView(accountId: id)
            case .connectGemini(let id):
                geminiOAuthConnectView(accountId: id)
            case .connectGeminiAPIKey(let id):
                geminiAPIKeyConnectView(accountId: id)
            case .connectKimi(let id):
                kimiConnectView(accountId: id)
            case .connectCursor(let id):
                cursorConnectView(accountId: id)
            case .connectOpenRouter(let id):
                openrouterConnectView(accountId: id)
            case .connectKiro(let id):
                kiroConnectView(accountId: id)
            case .connectAugment(let id):
                augmentConnectView(accountId: id)
            case .connectJetBrains(let id):
                jetbrainsConnectView(accountId: id)
            case .connectCodex(let id):
                codexConnectView(accountId: id)
            case .connectZai(let id):
                zaiConnectView(accountId: id)
            case .accountDetail(let id):
                accountDetailView(accountId: id)
            }
        }
        .frame(width: 320)
        .animation(.easeInOut(duration: 0.15), value: screen)
    }

    // MARK: - Main Screen

    private var mainView: some View {
        VStack(spacing: 0) {
            // Header
            HStack(alignment: .center) {
                Text("Usageview")
                    .font(.title2.weight(.bold))

                Spacer()

                if !store.accounts.isEmpty {
                    Button {
                        store.toggleViewMode()
                    } label: {
                        Image(systemName: store.viewMode == .compact ? "rectangle.expand.vertical" : "rectangle.compress.vertical")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .help(store.viewMode == .compact ? "Expanded view" : "Compact view")

                    Button {
                        Task { await store.refreshAll() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                }

                Button {
                    openSettings()
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help("Settings")
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 10)

            if store.accounts.isEmpty {
                // Empty state
                VStack(spacing: 10) {
                    Image(systemName: "chart.bar.doc.horizontal")
                        .font(.system(size: 28))
                        .foregroundStyle(.quaternary)
                    Text("No accounts yet")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text("Add your AI subscriptions to\ntrack usage across all accounts.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity)
            } else {
                // Scrollable ordered account list
                // Observe dataVersion to force re-render after refresh updates
                let _ = store.dataVersion
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: store.viewMode == .compact ? 1 : 4) {
                        ForEach(store.orderedAccounts) { account in
                            accountView(for: account)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 4)
                }
                .frame(maxHeight: 440)
                .scrollBounceBehavior(.basedOnSize)
                .onAppear { store.ensureOrderIntegrity() }
            }

            Divider().padding(.vertical, 6)

            // Footer: Add + Quit
            HStack {
                Button {
                    navigate(to: .pickService)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus.circle.fill")
                        Text("Add Account")
                    }
                    .font(.caption.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)

                Spacer()

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
    }

    // MARK: - View Helpers

    @ViewBuilder
    private func accountView(for account: Account) -> some View {
        if store.viewMode == .compact {
            CompactAccountRow(
                account: account,
                isConnected: store.isConnected(for: account),
                isRefreshing: store.isRefreshing(for: account),
                renamingId: $renamingAccountId,
                renameText: $renameText,
                onConnect: {
                    switch account.serviceType {
                    case .claude:
                        navigate(to: account.authMethod == .apiKey ? .connectClaudeAPIKey(account.id) : .connectClaude(account.id))
                    case .copilot: navigate(to: .connectGitHub(account.id))
                    case .chatgpt:
                        navigate(to: account.authMethod == .apiKey ? .connectOpenAIAPIKey(account.id) : .connectOpenAI(account.id))
                    case .gemini:
                        navigate(to: account.authMethod == .apiKey ? .connectGeminiAPIKey(account.id) : .connectGemini(account.id))
                    case .kimi: navigate(to: .connectKimi(account.id))
                    case .cursor: navigate(to: .connectCursor(account.id))
                    case .openrouter: navigate(to: .connectOpenRouter(account.id))
                    case .kiro: navigate(to: .connectKiro(account.id))
                    case .augment: navigate(to: .connectAugment(account.id))
                    case .jetbrainsAI: navigate(to: .connectJetBrains(account.id))
                    case .codex: navigate(to: .connectCodex(account.id))
                    case .zai: navigate(to: .connectZai(account.id))
                    }
                },
                onRefresh: { Task { await store.refreshAccount(account) } },
                onSaveRename: {
                    store.renameAccount(id: account.id, label: renameText)
                    renamingAccountId = nil
                },
                onDisconnect: { store.disconnectAccount(id: account.id) },
                onRemove: { store.removeAccount(id: account.id) },
                onTap: { navigate(to: .accountDetail(account.id)) },
                onPin: { store.togglePinToMenuBar(account) },
                onMoveUp: { store.moveAccountUp(id: account.id) },
                onMoveDown: { store.moveAccountDown(id: account.id) },
                isPinned: store.isPinnedToMenuBar(account),
                canMoveUp: store.canMoveUp(id: account.id),
                canMoveDown: store.canMoveDown(id: account.id),
                showWeeklyLimit: store.showWeeklyLimit
            )
        } else {
            AccountCardView(
                account: account,
                isConnected: store.isConnected(for: account),
                isRefreshing: store.isRefreshing(for: account),
                renamingId: $renamingAccountId,
                renameText: $renameText,
                onConnect: {
                    switch account.serviceType {
                    case .claude:
                        navigate(to: account.authMethod == .apiKey ? .connectClaudeAPIKey(account.id) : .connectClaude(account.id))
                    case .copilot: navigate(to: .connectGitHub(account.id))
                    case .chatgpt:
                        navigate(to: account.authMethod == .apiKey ? .connectOpenAIAPIKey(account.id) : .connectOpenAI(account.id))
                    case .gemini:
                        navigate(to: account.authMethod == .apiKey ? .connectGeminiAPIKey(account.id) : .connectGemini(account.id))
                    case .kimi: navigate(to: .connectKimi(account.id))
                    case .cursor: navigate(to: .connectCursor(account.id))
                    case .openrouter: navigate(to: .connectOpenRouter(account.id))
                    case .kiro: navigate(to: .connectKiro(account.id))
                    case .augment: navigate(to: .connectAugment(account.id))
                    case .jetbrainsAI: navigate(to: .connectJetBrains(account.id))
                    case .codex: navigate(to: .connectCodex(account.id))
                    case .zai: navigate(to: .connectZai(account.id))
                    }
                },
                onRefresh: { Task { await store.refreshAccount(account) } },
                onSaveRename: {
                    store.renameAccount(id: account.id, label: renameText)
                    renamingAccountId = nil
                },
                onDisconnect: { store.disconnectAccount(id: account.id) },
                onRemove: { store.removeAccount(id: account.id) },
                onTap: { navigate(to: .accountDetail(account.id)) },
                onPin: { store.togglePinToMenuBar(account) },
                onMoveUp: { store.moveAccountUp(id: account.id) },
                onMoveDown: { store.moveAccountDown(id: account.id) },
                isPinned: store.isPinnedToMenuBar(account),
                canMoveUp: store.canMoveUp(id: account.id),
                canMoveDown: store.canMoveDown(id: account.id),
                showWeeklyLimit: store.showWeeklyLimit
            )
        }
    }

    private func sectionHeader(for type: ServiceType, count: Int) -> some View {
        HStack(spacing: 5) {
            ServiceIconView(serviceType: type, avatarURL: nil, size: 12)
            Text("\(type.displayName)")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("\(count)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
    }

    // MARK: - Pick Service Type

    private var pickServiceView: some View {
        VStack(spacing: 0) {
            navHeader(title: "Add Account") {
                goBack()
            }

            VStack(spacing: 8) {
                ForEach(ServiceType.allCases, id: \.self) { type in
                    Button {
                        if type.supportsMultipleAuthMethods {
                            // Show auth method picker before creating account
                            let account = store.addAccount(serviceType: type)
                            navigate(to: .pickAuthMethod(account.id, type))
                        } else {
                            let account = store.addAccount(
                                serviceType: type,
                                authMethod: (type == .copilot || type == .codex) ? .oauth : .apiKey
                            )
                            switch type {
                            case .copilot: navigate(to: .connectGitHub(account.id))
                            case .kimi: navigate(to: .connectKimi(account.id))
                            case .cursor: navigate(to: .connectCursor(account.id))
                            case .openrouter: navigate(to: .connectOpenRouter(account.id))
                            case .kiro: navigate(to: .connectKiro(account.id))
                            case .augment: navigate(to: .connectAugment(account.id))
                            case .jetbrainsAI: navigate(to: .connectJetBrains(account.id))
                            case .codex: navigate(to: .connectCodex(account.id))
                            case .zai: navigate(to: .connectZai(account.id))
                            case .claude, .chatgpt, .gemini: break // handled above
                            }
                        }
                    } label: {
                        HStack(spacing: 12) {
                            ServiceIconView(serviceType: type, avatarURL: nil, size: 32)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(type.displayName)
                                    .font(.subheadline.weight(.semibold))
                                Text(type.authDescription)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(12)
                        .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 16)
        }
    }

    // MARK: - Auth Method Picker

    private func pickAuthMethodView(accountId: UUID, serviceType: ServiceType) -> some View {
        VStack(spacing: 0) {
            navHeader(title: serviceType.displayName) {
                store.removeAccount(id: accountId)
                goBack()
            }

            VStack(spacing: 12) {
                ServiceIconView(serviceType: serviceType, avatarURL: nil, size: 48)

                Text("Choose how to connect")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)

                VStack(spacing: 10) {
                    // OAuth option
                    Button {
                        if let index = store.accounts.firstIndex(where: { $0.id == accountId }) {
                            store.accounts[index].authMethod = .oauth
                            store.save()
                        }
                        switch serviceType {
                        case .claude: navigate(to: .connectClaude(accountId))
                        case .chatgpt: navigate(to: .connectOpenAI(accountId))
                        case .gemini: navigate(to: .connectGemini(accountId))
                        default: break
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "person.badge.key")
                                .font(.subheadline)
                            Text(serviceType == .gemini ? "Sign in with Google" : "Sign in with OAuth")
                                .font(.subheadline.weight(.medium))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(serviceType.accentColor)
                    .padding(.horizontal, 16)

                    // API Key option
                    Button {
                        if let index = store.accounts.firstIndex(where: { $0.id == accountId }) {
                            store.accounts[index].authMethod = .apiKey
                            store.save()
                        }
                        switch serviceType {
                        case .claude: navigate(to: .connectClaudeAPIKey(accountId))
                        case .chatgpt: navigate(to: .connectOpenAIAPIKey(accountId))
                        case .gemini: navigate(to: .connectGeminiAPIKey(accountId))
                        default: break
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "key")
                                .font(.subheadline)
                            Text("Use API Key")
                                .font(.subheadline.weight(.medium))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(serviceType.accentColor.opacity(0.7))
                    .padding(.horizontal, 16)
                }
            }
            .padding(.bottom, 16)
        }
    }

    // MARK: - GitHub Connect (Inline)

    private func githubConnectView(accountId: UUID) -> some View {
        GitHubInlineConnectView(
            authService: store.githubAuth,
            accountId: accountId,
            onDone: { info in
                if let info {
                    store.updateAccountAfterConnect(
                        id: accountId,
                        username: info.username,
                        avatarURL: info.avatarURL
                    )
                    Task {
                        if let account = store.accounts.first(where: { $0.id == accountId }) {
                            await store.refreshAccount(account)
                        }
                    }
                    goHome()
                } else {
                    store.removeAccount(id: accountId)
                    goBack()
                }
            }
        )
    }

    // MARK: - Claude Connect (Inline - OAuth)

    private func claudeConnectView(accountId: UUID) -> some View {
        ClaudeInlineConnectView(
            authService: store.claudeAuth,
            accountId: accountId,
            onDone: { info in
                if let info {
                    let displayName = info.name ?? info.email ?? nil
                    store.updateAccountAfterConnect(
                        id: accountId,
                        username: displayName,
                        avatarURL: nil,
                        authMethod: .oauth
                    )
                    Task {
                        if let account = store.accounts.first(where: { $0.id == accountId }) {
                            await store.refreshAccount(account)
                        }
                    }
                    goHome()
                } else {
                    goBack()
                }
            }
        )
    }

    // MARK: - Claude Connect (Inline - API Key)

    private func claudeAPIKeyConnectView(accountId: UUID) -> some View {
        ClaudeAPIKeyInlineConnectView(
            authService: store.claudeAuth,
            accountId: accountId,
            onDone: { info in
                if let info {
                    let displayName = info.name ?? info.email ?? nil
                    store.updateAccountAfterConnect(
                        id: accountId,
                        username: displayName,
                        avatarURL: nil,
                        authMethod: .apiKey
                    )
                    Task {
                        if let account = store.accounts.first(where: { $0.id == accountId }) {
                            await store.refreshAccount(account)
                        }
                    }
                    goHome()
                } else {
                    goBack()
                }
            }
        )
    }

    // MARK: - OpenAI Connect (Inline - OAuth)

    private func openaiConnectView(accountId: UUID) -> some View {
        OpenAIInlineConnectView(
            authService: store.openaiAuth,
            accountId: accountId,
            onDone: { info in
                if let info {
                    let displayName = info.name ?? info.email ?? nil
                    store.updateAccountAfterConnect(
                        id: accountId,
                        username: displayName,
                        avatarURL: nil,
                        authMethod: .oauth
                    )
                    Task {
                        if let account = store.accounts.first(where: { $0.id == accountId }) {
                            await store.refreshAccount(account)
                        }
                    }
                    goHome()
                } else {
                    goBack()
                }
            },
            onSwitchToAPIKey: {
                // Switch this account to API key auth method
                if let index = store.accounts.firstIndex(where: { $0.id == accountId }) {
                    store.accounts[index].authMethod = .apiKey
                    store.save()
                }
                navigate(to: .connectOpenAIAPIKey(accountId))
            }
        )
    }

    // MARK: - OpenAI Connect (Inline - API Key)

    private func openaiAPIKeyConnectView(accountId: UUID) -> some View {
        OpenAIAPIKeyInlineConnectView(
            authService: store.openaiAuth,
            accountId: accountId,
            onDone: { info in
                if let info {
                    let displayName = info.name ?? info.email ?? nil
                    store.updateAccountAfterConnect(
                        id: accountId,
                        username: displayName,
                        avatarURL: nil,
                        authMethod: .apiKey
                    )
                    Task {
                        if let account = store.accounts.first(where: { $0.id == accountId }) {
                            await store.refreshAccount(account)
                        }
                    }
                    goHome()
                } else {
                    goBack()
                }
            }
        )
    }

    // MARK: - Gemini Connect (Google OAuth)

    private func geminiOAuthConnectView(accountId: UUID) -> some View {
        GeminiOAuthConnectView(
            authService: store.geminiAuth,
            accountId: accountId,
            onDone: { info in
                if let info {
                    store.updateAccountAfterConnect(
                        id: accountId,
                        username: info.name ?? info.email,
                        avatarURL: nil,
                        authMethod: .oauth
                    )
                    Task {
                        if let account = store.accounts.first(where: { $0.id == accountId }) {
                            await store.refreshAccount(account)
                        }
                    }
                    goHome()
                } else {
                    store.geminiAuth.cancelOAuth()
                    store.removeAccount(id: accountId)
                    goBack()
                }
            }
        )
    }

    // MARK: - Gemini Connect (API Key)

    private func geminiAPIKeyConnectView(accountId: UUID) -> some View {
        GeminiInlineConnectView(
            authService: store.geminiAuth,
            accountId: accountId,
            onDone: { info in
                if let info {
                    store.updateAccountAfterConnect(
                        id: accountId,
                        username: info.name,
                        avatarURL: nil
                    )
                    Task {
                        if let account = store.accounts.first(where: { $0.id == accountId }) {
                            await store.refreshAccount(account)
                        }
                    }
                    goHome()
                } else {
                    store.removeAccount(id: accountId)
                    goBack()
                }
            }
        )
    }

    // MARK: - Kimi Connect (Inline - API Key)

    private func kimiConnectView(accountId: UUID) -> some View {
        KimiInlineConnectView(
            authService: store.kimiAuth,
            accountId: accountId,
            onDone: { info in
                if let info {
                    store.updateAccountAfterConnect(
                        id: accountId,
                        username: info.name,
                        avatarURL: nil
                    )
                    Task {
                        if let account = store.accounts.first(where: { $0.id == accountId }) {
                            await store.refreshAccount(account)
                        }
                    }
                    goHome()
                } else {
                    store.removeAccount(id: accountId)
                    goBack()
                }
            }
        )
    }

    // MARK: - Cursor Connect (Inline - Session Token)

    private func cursorConnectView(accountId: UUID) -> some View {
        CursorInlineConnectView(
            authService: store.cursorAuth,
            accountId: accountId,
            onDone: { info in
                if let info {
                    store.updateAccountAfterConnect(
                        id: accountId,
                        username: info.name ?? info.email,
                        avatarURL: nil
                    )
                    Task {
                        if let account = store.accounts.first(where: { $0.id == accountId }) {
                            await store.refreshAccount(account)
                        }
                    }
                    goHome()
                } else {
                    store.removeAccount(id: accountId)
                    goBack()
                }
            }
        )
    }

    // MARK: - OpenRouter Connect (Inline - API Key)

    private func openrouterConnectView(accountId: UUID) -> some View {
        OpenRouterInlineConnectView(
            authService: store.openrouterAuth,
            accountId: accountId,
            onDone: { info in
                if let info {
                    store.updateAccountAfterConnect(
                        id: accountId,
                        username: info.name,
                        avatarURL: nil
                    )
                    Task {
                        if let account = store.accounts.first(where: { $0.id == accountId }) {
                            await store.refreshAccount(account)
                        }
                    }
                    goHome()
                } else {
                    store.removeAccount(id: accountId)
                    goBack()
                }
            }
        )
    }

    // MARK: - Kiro Connect (Inline - API Key)

    private func kiroConnectView(accountId: UUID) -> some View {
        KiroInlineConnectView(
            authService: store.kiroAuth,
            accountId: accountId,
            onDone: { info in
                if let info {
                    store.updateAccountAfterConnect(
                        id: accountId,
                        username: info.name,
                        avatarURL: nil
                    )
                    Task {
                        if let account = store.accounts.first(where: { $0.id == accountId }) {
                            await store.refreshAccount(account)
                        }
                    }
                    goHome()
                } else {
                    store.removeAccount(id: accountId)
                    goBack()
                }
            }
        )
    }

    // MARK: - Augment Connect (Inline - API Key)

    private func augmentConnectView(accountId: UUID) -> some View {
        AugmentInlineConnectView(
            authService: store.augmentAuth,
            accountId: accountId,
            onDone: { info in
                if let info {
                    store.updateAccountAfterConnect(
                        id: accountId,
                        username: info.name,
                        avatarURL: nil
                    )
                    Task {
                        if let account = store.accounts.first(where: { $0.id == accountId }) {
                            await store.refreshAccount(account)
                        }
                    }
                    goHome()
                } else {
                    store.removeAccount(id: accountId)
                    goBack()
                }
            }
        )
    }

    // MARK: - JetBrains Connect (Inline - Auto-Detect)

    private func jetbrainsConnectView(accountId: UUID) -> some View {
        JetBrainsInlineConnectView(
            authService: store.jetbrainsAuth,
            accountId: accountId,
            onDone: { info in
                if let info {
                    store.updateAccountAfterConnect(
                        id: accountId,
                        username: info.name,
                        avatarURL: nil
                    )
                    Task {
                        if let account = store.accounts.first(where: { $0.id == accountId }) {
                            await store.refreshAccount(account)
                        }
                    }
                    goHome()
                } else {
                    store.removeAccount(id: accountId)
                    goBack()
                }
            }
        )
    }

    private func codexConnectView(accountId: UUID) -> some View {
        CodexInlineConnectView(
            authService: store.codexAuth,
            accountId: accountId,
            onDone: { info in
                if let info {
                    store.updateAccountAfterConnect(
                        id: accountId,
                        username: info.name,
                        avatarURL: nil
                    )
                    Task {
                        if let account = store.accounts.first(where: { $0.id == accountId }) {
                            await store.refreshAccount(account)
                        }
                    }
                    goHome()
                } else {
                    store.removeAccount(id: accountId)
                    goBack()
                }
            }
        )
    }

    private func zaiConnectView(accountId: UUID) -> some View {
        ZaiInlineConnectView(
            authService: store.zaiAuth,
            accountId: accountId,
            onDone: { info in
                if let info {
                    store.updateAccountAfterConnect(
                        id: accountId,
                        username: info.name,
                        avatarURL: nil
                    )
                    Task {
                        if let account = store.accounts.first(where: { $0.id == accountId }) {
                            await store.refreshAccount(account)
                        }
                    }
                    goHome()
                } else {
                    store.removeAccount(id: accountId)
                    goBack()
                }
            }
        )
    }

    // MARK: - Nav Header Helper

    private func navHeader(title: String, onBack: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Button { onBack() } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.medium))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Text(title)
                .font(.headline)

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    /// Navigate to a new screen, pushing current screen onto history
    private func navigate(to newScreen: Screen) {
        screenHistory.append(screen)
        screen = newScreen
    }

    /// Go back to the previous screen in history, or main if no history
    private func goBack() {
        if let prev = screenHistory.popLast() {
            screen = prev
        } else {
            screen = .main
        }
    }

    /// Go back to main, clearing all history
    private func goHome() {
        screenHistory.removeAll()
        screen = .main
    }

    // MARK: - Account Detail View

    private func accountDetailView(accountId: UUID) -> some View {
        let account = store.accounts.first(where: { $0.id == accountId })

        return VStack(spacing: 0) {
            navHeader(title: "Details") {
                goBack()
            }

            if let account {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 16) {
                        // Identity card
                        VStack(spacing: 10) {
                            ServiceIconView(
                                serviceType: account.serviceType,
                                avatarURL: store.isConnected(for: account) ? account.avatarURL : nil,
                                size: 48
                            )

                            VStack(spacing: 2) {
                                Text(account.label.isEmpty
                                    ? (account.username ?? account.serviceType.displayName)
                                    : account.label)
                                    .font(.headline)

                                if !account.label.isEmpty, let username = account.username {
                                    Text(username)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Text(account.serviceType.displayName)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)

                        Picker("", selection: $detailTab) {
                            ForEach(DetailTab.allCases, id: \.self) { tab in
                                Text(tab.rawValue).tag(tab)
                            }
                        }
                        .pickerStyle(.segmented)
                        .controlSize(.small)

                        // Usage section
                        if store.isConnected(for: account) {
                            if detailTab == .overview {
                                VStack(alignment: .leading, spacing: 10) {
                                    detailSectionTitle("Usage")

                                if account.serviceType == .claude && account.authMethod == .oauth {
                                    // Claude OAuth: always show dual windows
                                    detailRateRow(
                                        label: "5-hour limit",
                                        usage: account.fiveHourUsage ?? account.currentUsage,
                                        subtitle: account.fiveHourResetDate == nil && account.fiveHourUsage != nil
                                            ? "\(Int(account.fiveHourUsage ?? 0))% of 5h capacity used"
                                            : nil,
                                        resetDate: account.fiveHourResetDate,
                                        accentColor: account.accentColor,
                                        maxResetHours: 6
                                    )

                                    detailRateRow(
                                        label: "7-day limit",
                                        usage: account.sevenDayUsage ?? account.currentUsage,
                                        subtitle: account.sevenDayResetDate == nil && account.sevenDayUsage != nil
                                            ? "\(Int(account.sevenDayUsage ?? 0))% of weekly capacity used"
                                            : nil,
                                        resetDate: account.sevenDayResetDate,
                                        accentColor: account.accentColor,
                                        maxResetHours: 192
                                    )

                                    if !account.hasDualWindows {
                                        Text("Refresh to load rate window data")
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                            .frame(maxWidth: .infinity)
                                    }

                                    // Toggle to show/hide detailed windows in main view
                                    Toggle(isOn: Binding(
                                        get: { store.showWeeklyLimit },
                                        set: { newValue in
                                            store.showWeeklyLimit = newValue
                                            UserDefaults.standard.set(newValue, forKey: "showWeeklyLimit")
                                        }
                                    )) {
                                        Text("Show 7-day limit in main view")
                                            .font(.caption)
                                    }
                                    .toggleStyle(.switch)
                                    .controlSize(.mini)
                                    .padding(.top, 4)

                                } else if account.hasDualWindows {
                                    detailRateRow(
                                        label: "\(account.serviceType.primaryRateLabel(authMethod: account.authMethod)) limit",
                                        usage: account.fiveHourUsage ?? account.currentUsage,
                                        subtitle: nil,
                                        resetDate: account.fiveHourResetDate,
                                        accentColor: account.accentColor,
                                        maxResetHours: account.serviceType == .gemini ? 25 : 6
                                    )
                                    detailRateRow(
                                        label: "\(account.serviceType.secondaryRateLabel(authMethod: account.authMethod)) limit",
                                        usage: account.sevenDayUsage ?? 0,
                                        subtitle: nil,
                                        resetDate: account.sevenDayResetDate,
                                        accentColor: account.accentColor,
                                        maxResetHours: 192
                                    )
                                    Toggle(isOn: Binding(
                                        get: { store.showWeeklyLimit },
                                        set: { newValue in
                                            store.showWeeklyLimit = newValue
                                            UserDefaults.standard.set(newValue, forKey: "showWeeklyLimit")
                                        }
                                    )) {
                                        Text("Show weekly limit in main view")
                                            .font(.caption)
                                    }
                                    .toggleStyle(.switch)
                                    .controlSize(.mini)
                                    .padding(.top, 4)

                                } else if account.hasZaiTripleWindows {
                                    detailRateRow(
                                        label: "Token quota",
                                        usage: account.fiveHourUsage ?? 0,
                                        subtitle: nil,
                                        resetDate: account.fiveHourResetDate,
                                        accentColor: account.accentColor,
                                        maxResetHours: 24 * 14
                                    )
                                    if let mcp = account.sevenDayUsage {
                                        detailRateRow(
                                            label: "MCP quota",
                                            usage: mcp,
                                            subtitle: nil,
                                            resetDate: account.sevenDayResetDate,
                                            accentColor: account.accentColor,
                                            maxResetHours: 24 * 35
                                        )
                                    }
                                    if let session = account.tertiaryUsage {
                                        detailRateRow(
                                            label: "Short window",
                                            usage: session,
                                            subtitle: nil,
                                            resetDate: account.tertiaryResetDate,
                                            accentColor: account.accentColor,
                                            maxResetHours: 6
                                        )
                                    }

                                } else if account.serviceType == .copilot {
                                    // Copilot: premium requests + chat quota
                                    detailRateRow(
                                        label: "Premium Requests",
                                        usage: account.usageLimit > 0
                                            ? (account.currentUsage / account.usageLimit) * 100
                                            : 0,
                                        subtitle: "\(Int(account.currentUsage)) / \(Int(account.usageLimit)) used",
                                        resetDate: account.resetDate,
                                        accentColor: account.accentColor,
                                        maxResetHours: 792 // ~33 days for monthly reset
                                    )

                                    if account.hasCopilotDualQuotas {
                                        detailRateRow(
                                            label: "Chat Completions",
                                            usage: account.chatUsage ?? 0,
                                            subtitle: account.chatLimit.map {
                                                "\(Int(max(0, $0 * (account.chatPercentRemaining ?? 0) / 100))) / \(Int($0)) remaining"
                                            },
                                            resetDate: account.resetDate,
                                            accentColor: account.accentColor,
                                            maxResetHours: 792
                                        )
                                    }

                                    // Toggle to show/hide both quotas in main view
                                    Toggle(isOn: Binding(
                                        get: { store.showWeeklyLimit },
                                        set: { newValue in
                                            store.showWeeklyLimit = newValue
                                            UserDefaults.standard.set(newValue, forKey: "showWeeklyLimit")
                                        }
                                    )) {
                                        Text("Show all quotas in main view")
                                            .font(.caption)
                                    }
                                    .toggleStyle(.switch)
                                    .controlSize(.mini)
                                    .padding(.top, 4)

                                } else if account.hasKimiBilling {
                                    // Kimi billing: weekly quota + rate limit
                                    let weeklyPct = (account.kimiWeeklyLimit ?? 0) > 0
                                        ? ((account.kimiWeeklyUsed ?? 0) / (account.kimiWeeklyLimit ?? 1)) * 100
                                        : 0

                                    detailRateRow(
                                        label: "Weekly Quota",
                                        usage: weeklyPct,
                                        subtitle: "\(Int(account.kimiWeeklyUsed ?? 0)) / \(Int(account.kimiWeeklyLimit ?? 0)) requests",
                                        resetDate: account.kimiWeeklyResetDate,
                                        accentColor: account.accentColor,
                                        maxResetHours: 192
                                    )

                                    if (account.kimiRateLimitMax ?? 0) > 0 {
                                        let ratePct = ((account.kimiRateLimitUsed ?? 0) / (account.kimiRateLimitMax ?? 1)) * 100
                                        detailRateRow(
                                            label: "Rate Limit (5 min)",
                                            usage: ratePct,
                                            subtitle: "\(Int(account.kimiRateLimitUsed ?? 0)) / \(Int(account.kimiRateLimitMax ?? 0)) requests",
                                            resetDate: account.kimiRateLimitResetDate,
                                            accentColor: account.accentColor,
                                            maxResetHours: 1
                                        )
                                    }

                                } else if account.isStatusOnly {
                                    HStack(spacing: 6) {
                                        Circle()
                                            .fill(account.formattedUsage == "Inactive" ? .orange : .green)
                                            .frame(width: 7, height: 7)
                                        Text(account.formattedUsage)
                                            .font(.subheadline.weight(.medium))
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                    }
                                    .padding(10)
                                    .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                                } else {
                                    VStack(alignment: .leading, spacing: 6) {
                                        GeometryReader { geo in
                                            ZStack(alignment: .leading) {
                                                RoundedRectangle(cornerRadius: 4)
                                                    .fill(.primary.opacity(0.06))
                                                RoundedRectangle(cornerRadius: 4)
                                                    .fill(detailBarColor(account))
                                                    .frame(width: max(0, geo.size.width * account.usagePercentage))
                                            }
                                        }
                                        .frame(height: 8)

                                        HStack {
                                            Text(account.formattedUsage)
                                                .font(.subheadline.weight(.medium))
                                            Spacer()
                                            HStack(spacing: 4) {
                                                Image(systemName: "clock")
                                                    .font(.caption2)
                                                Text("Resets \(account.resetLabel)")
                                            }
                                            .font(.caption)
                                            .foregroundStyle(.tertiary)
                                        }
                                    }
                                    .padding(10)
                                    .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                                }
                                }
                            }

                            if detailTab == .usage {
                                VStack(alignment: .leading, spacing: 10) {
                                    detailSectionTitle("Usage & Spend")

                                    VStack(spacing: 0) {
                                        detailInfoRow(label: "Cycle", value: usageCycleLabel(for: account))
                                        Divider().padding(.horizontal, 10)
                                        detailInfoRow(label: "Primary Metric", value: usagePrimaryMetric(for: account))

                                        if let spend = detailMonthlySpendLabel(for: account) {
                                            Divider().padding(.horizontal, 10)
                                            detailInfoRow(label: "Monthly Spend", value: spend)
                                        }

                                        if let credits = detailCreditsLabel(for: account) {
                                            Divider().padding(.horizontal, 10)
                                            detailInfoRow(label: "Credits", value: credits)
                                        }
                                    }
                                    .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))

                                    let costPoints = detailCostPoints(for: account)
                                    Button {
                                        showCostBreakdownPopover = true
                                    } label: {
                                        VStack(alignment: .leading, spacing: 6) {
                                            HStack {
                                                Text("Cost")
                                                    .font(.headline)
                                                    .foregroundStyle(.white)
                                                Spacer()
                                                Image(systemName: "chevron.right")
                                                    .font(.caption.weight(.semibold))
                                                    .foregroundStyle(.white.opacity(0.9))
                                            }
                                            Text("Today: \(detailTodayCostLabel(for: account))")
                                                .font(.headline.weight(.bold))
                                                .foregroundStyle(.white)
                                            if let tokenLabel = detailTodayTokensLabel(for: account) {
                                                Text("Tokens: \(tokenLabel)")
                                                    .font(.subheadline.weight(.semibold))
                                                    .foregroundStyle(.white.opacity(0.95))
                                            }
                                            Text("Last 30 days: \(detailLast30dCostLabel(for: account))")
                                                .font(.headline.weight(.bold))
                                                .foregroundStyle(.white)
                                            if let tokenLabel = detailLast30dTokensLabel(for: account) {
                                                Text("30d Tokens: \(tokenLabel)")
                                                    .font(.subheadline.weight(.semibold))
                                                    .foregroundStyle(.white.opacity(0.95))
                                            }
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(12)
                                        .background(account.accentColor, in: RoundedRectangle(cornerRadius: 10))
                                    }
                                    .buttonStyle(.plain)
                                    .popover(isPresented: $showCostBreakdownPopover, arrowEdge: .top) {
                                        costBreakdownPopover(points: costPoints, fallbackTotalLabel: detailLast30dCostLabel(for: account))
                                            .frame(width: 360, height: 260)
                                            .padding(16)
                                    }

                                    if costPoints.isEmpty {
                                        Text("Daily history is still collecting. Last 30 days uses the latest provider snapshot for now.")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .padding(.horizontal, 2)
                                    }

                                    VStack(spacing: 0) {
                                        detailInfoRow(label: "Usage Source", value: detailUsageSource(for: account))
                                    }
                                    .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                                }
                            }

                            // Provider diagnostics (CodexBar-style relevance details)
                            if detailTab == .overview {
                                VStack(alignment: .leading, spacing: 10) {
                                detailSectionTitle("Provider")

                                VStack(spacing: 0) {
                                    detailInfoRow(label: "Usage Source", value: detailUsageSource(for: account))
                                    Divider().padding(.horizontal, 10)
                                    detailInfoRow(label: "Tracking", value: account.isStatusOnly ? "Status only" : "Quota tracking")
                                    if account.hasDualWindows {
                                        Divider().padding(.horizontal, 10)
                                        detailInfoRow(label: "Rate Windows", value: account.serviceType == .gemini ? "Pro + Flash" : "5-hour + 7-day")
                                    }
                                    if account.isDemoAccount {
                                        Divider().padding(.horizontal, 10)
                                        detailInfoRow(label: "Data Mode", value: "Demo snapshot")
                                    }
                                }
                                .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))

                                HStack(spacing: 8) {
                                    if let dashboardURL = account.serviceType.dashboardURL {
                                        Button {
                                            NSWorkspace.shared.open(dashboardURL)
                                        } label: {
                                            HStack(spacing: 5) {
                                                Image(systemName: "safari")
                                                    .font(.caption2)
                                                Text("Open Dashboard")
                                                    .font(.caption.weight(.medium))
                                            }
                                            .frame(maxWidth: .infinity)
                                        }
                                        .buttonStyle(.bordered)
                                    }

                                    if let statusURL = account.serviceType.statusPageURL {
                                        Button {
                                            NSWorkspace.shared.open(statusURL)
                                        } label: {
                                            HStack(spacing: 5) {
                                                Image(systemName: "waveform.path.ecg")
                                                    .font(.caption2)
                                                Text("Status Page")
                                                    .font(.caption.weight(.medium))
                                            }
                                            .frame(maxWidth: .infinity)
                                        }
                                        .buttonStyle(.bordered)
                                    }
                                }
                            }
                            }

                            // Account info section
                            if detailTab == .overview {
                                VStack(alignment: .leading, spacing: 10) {
                                    detailSectionTitle("Account")

                                    VStack(spacing: 0) {
                                        detailInfoRow(label: "Service", value: account.serviceType.displayName)
                                        Divider().padding(.horizontal, 10)
                                        detailInfoRow(
                                            label: "Auth",
                                            value: account.authMethod == .oauth ? "OAuth" : "API Key"
                                        )
                                        if let plan = account.planName {
                                            Divider().padding(.horizontal, 10)
                                            detailInfoRow(label: "Plan", value: plan)
                                        }
                                        if let org = account.organizationName {
                                            Divider().padding(.horizontal, 10)
                                            detailInfoRow(label: "Organization", value: org)
                                        }
                                        if let role = account.memberRole {
                                            Divider().padding(.horizontal, 10)
                                            detailInfoRow(label: "Role", value: role.capitalized)
                                        }
                                        if let username = account.username {
                                            Divider().padding(.horizontal, 10)
                                            detailInfoRow(label: "Signed in as", value: username)
                                        }
                                        if !account.label.isEmpty {
                                            Divider().padding(.horizontal, 10)
                                            detailInfoRow(label: "Label", value: account.label)
                                        }
                                    }
                                    .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                                }
                            }

                            // Actions
                            VStack(spacing: 8) {
                                Button {
                                    Task { await store.refreshAccount(account) }
                                } label: {
                                    HStack(spacing: 6) {
                                        if store.isRefreshing(for: account) {
                                            ProgressView().controlSize(.mini)
                                        } else {
                                            Image(systemName: "arrow.clockwise")
                                                .font(.caption)
                                        }
                                        Text("Refresh Now")
                                            .font(.subheadline.weight(.medium))
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 6)
                                }
                                .buttonStyle(.bordered)
                                .tint(account.accentColor)

                                Button {
                                    store.disconnectAccount(id: account.id)
                                    goHome()
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: "person.badge.minus")
                                            .font(.caption)
                                        Text("Disconnect")
                                            .font(.subheadline.weight(.medium))
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 6)
                                }
                                .buttonStyle(.bordered)
                                .tint(.secondary)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }
                .task {
                    // Auto-refresh if dual window data is missing
                    if account.serviceType == .claude && account.authMethod == .oauth && !account.hasDualWindows {
                        await store.refreshAccount(account)
                    }
                }
                .onAppear {
                    detailTab = .overview
                    showCostBreakdownPopover = false
                }
            } else {
                Spacer()
                Text("Account not found")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    // MARK: - Detail View Helpers

    private func detailSectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    private func detailBarColor(_ account: Account) -> Color {
        if account.usagePercentage >= 1.0 { return .red }
        if account.usagePercentage >= 0.8 { return .orange }
        return account.accentColor
    }

    private func detailRateBarColor(_ usage: Double, accent: Color) -> Color {
        if usage >= 100 { return .red }
        if usage >= 80 { return .orange }
        return accent
    }

    private func detailRateRow(label: String, usage: Double, subtitle: String? = nil, resetDate: Date?, accentColor: Color, maxResetHours: Double = 192) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                    .font(.caption.weight(.medium))
                Spacer()
                Text("\(Int(usage))%")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(usage >= 100 ? .red : .primary)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.primary.opacity(0.08))
                    RoundedRectangle(cornerRadius: 4)
                        .fill(detailRateBarColor(usage, accent: accentColor))
                        .frame(width: max(0, geo.size.width * min(usage / 100, 1.0)))
                }
            }
            .frame(height: 8)

            HStack {
                if let subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if Account.isResetReasonable(resetDate, maxHours: maxResetHours) {
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .font(.system(size: 9))
                        Text("Resets in \(Account.resetLabel(for: resetDate))")
                            .font(.caption2)
                    }
                    .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(10)
        .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    private func detailInfoRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private func detailUsageSource(for account: Account) -> String {
        switch (account.serviceType, account.authMethod) {
        case (.claude, .oauth):
            return "Claude CLI OAuth (fallback: Usageview OAuth)"
        case (.claude, .apiKey):
            return "Anthropic API key"
        case (.chatgpt, .oauth):
            return "OpenAI OAuth usage API"
        case (.chatgpt, .apiKey):
            return "OpenAI API key"
        case (.gemini, .oauth):
            return "Gemini CLI credentials"
        case (.gemini, .apiKey):
            return "Gemini API key"
        case (.copilot, _):
            return "GitHub Copilot API"
        case (.cursor, _):
            return "Cursor session API"
        case (.openrouter, _):
            return "OpenRouter credits API"
        case (.kimi, _):
            return "Moonshot billing API"
        case (.kiro, _):
            return "Kiro authentication probe"
        case (.augment, _):
            return "Augment authentication probe"
        case (.jetbrainsAI, _):
            return "JetBrains local quota source"
        case (.codex, _):
            return "Codex CLI OAuth · chatgpt.com/wham/usage"
        case (.zai, _):
            return "Z.ai quota API (api.z.ai / open.bigmodel.cn)"
        }
    }

    private func usageCycleLabel(for account: Account) -> String {
        switch account.serviceType {
        case .claude, .chatgpt, .codex:
            return "5-hour and weekly rolling windows"
        case .zai:
            return "Token, MCP, and short-window quotas"
        case .copilot, .cursor:
            return "Monthly billing cycle"
        case .openrouter:
            return "Credit balance tracking"
        case .gemini:
            return account.authMethod == .oauth ? "Pro and Flash quota windows" : "Connection status"
        case .kimi:
            return account.hasKimiBilling ? "Weekly quota and short-term limit" : "Connection status"
        case .kiro, .augment, .jetbrainsAI:
            return "Provider-specific quota/status"
        }
    }

    private func usagePrimaryMetric(for account: Account) -> String {
        if account.serviceType == .cursor, account.usageLimit > 0 {
            return String(format: "$%.2f / $%.2f used this cycle", account.currentUsage / 100.0, account.usageLimit / 100.0)
        }
        if account.hasOpenRouterCredits,
           let used = account.openRouterTotalUsage,
           let total = account.openRouterTotalCredits
        {
            return String(format: "$%.2f / $%.2f credits used", used, total)
        }
        if account.hasKimiBilling,
           let used = account.kimiWeeklyUsed,
           let limit = account.kimiWeeklyLimit
        {
            return "\(Int(used)) / \(Int(limit)) requests this week"
        }
        return account.formattedUsage
    }

    private func detailMonthlySpendLabel(for account: Account) -> String? {
        if let spend = account.monthlySpendUSD {
            if let limit = account.monthlySpendLimitUSD, limit > 0 {
                return String(format: "$%.2f / $%.2f", spend, limit)
            }
            return String(format: "$%.2f", spend)
        }
        if account.serviceType == .cursor, account.usageLimit > 0 {
            let used = account.currentUsage / 100.0
            let limit = account.usageLimit / 100.0
            return String(format: "$%.2f / $%.2f", used, limit)
        }
        return nil
    }

    private func detailCreditsLabel(for account: Account) -> String? {
        if account.serviceType == .chatgpt,
           let unlimited = account.openAICreditsUnlimited,
           unlimited
        {
            return "Unlimited"
        }
        if account.serviceType == .chatgpt,
           let balance = account.openAICreditsBalance
        {
            return String(format: "$%.2f balance", balance)
        }
        if account.hasOpenRouterCredits,
           let used = account.openRouterTotalUsage,
           let total = account.openRouterTotalCredits
        {
            return String(format: "$%.2f remaining", max(total - used, 0))
        }
        return nil
    }

    private func detailCostPoints(for account: Account) -> [(date: String, value: Double)] {
        guard let history = account.spendHistoryByDay, !history.isEmpty else { return [] }
        let sorted = history.keys.sorted()
        guard !sorted.isEmpty else { return [] }

        var daily: [(String, Double)] = []
        var previousCumulative: Double?
        for day in sorted {
            let cumulative = history[day] ?? 0
            let delta = max(cumulative - (previousCumulative ?? 0), 0)
            daily.append((day, delta))
            previousCumulative = cumulative
        }

        return Array(daily.suffix(30))
    }

    private func detailTodayCostLabel(for account: Account) -> String {
        let points = detailCostPoints(for: account)
        guard let today = points.last?.value else {
            return "Not available"
        }
        return String(format: "$%.2f", today)
    }

    private func detailLast30dCostLabel(for account: Account) -> String {
        let points = detailCostPoints(for: account)
        if !points.isEmpty {
            let total = points.reduce(0) { $0 + $1.value }
            return String(format: "$%.2f", total)
        }

        if let spend = account.monthlySpendUSD {
            return String(format: "$%.2f", spend)
        }

        if account.hasOpenRouterCredits, let used = account.openRouterTotalUsage {
            return String(format: "$%.2f", used)
        }

        if account.serviceType == .cursor, account.usageLimit > 0 {
            return String(format: "$%.2f", account.currentUsage / 100.0)
        }

        return "Not available"
    }

    private func detailTodayTokensLabel(for account: Account) -> String? {
        guard account.serviceType == .claude,
              account.authMethod == .oauth,
              let tokens = account.todayTokenCount,
              tokens > 0
        else {
            return nil
        }
        return formatTokenCount(tokens)
    }

    private func detailLast30dTokensLabel(for account: Account) -> String? {
        guard account.serviceType == .claude,
              account.authMethod == .oauth,
              let tokens = account.last30DayTokenCount,
              tokens > 0
        else {
            return nil
        }
        return formatTokenCount(tokens)
    }

    private func formatTokenCount(_ count: Int64) -> String {
        let value = Double(count)
        switch value {
        case 1_000_000_000...:
            return String(format: "%.2fB", value / 1_000_000_000)
        case 1_000_000...:
            return String(format: "%.2fM", value / 1_000_000)
        case 1_000...:
            return String(format: "%.1fK", value / 1_000)
        default:
            return "\(count)"
        }
    }

    private func costBreakdownPopover(points: [(date: String, value: Double)], fallbackTotalLabel: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Cost")
                .font(.title3.weight(.semibold))

            if points.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No daily history yet")
                        .font(.subheadline.weight(.medium))
                    Text("Keep refreshing usage and the 30-day bars will appear automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Current 30d summary: \(fallbackTotalLabel)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                GeometryReader { geo in
                    let maxValue = max(points.map { $0.value }.max() ?? 1, 1)
                    let barCount = max(points.count, 1)
                    let gap: CGFloat = 4
                    let totalGap = gap * CGFloat(barCount - 1)
                    let barWidth = max((geo.size.width - totalGap) / CGFloat(barCount), 3)

                    HStack(alignment: .bottom, spacing: gap) {
                        ForEach(Array(points.enumerated()), id: \.offset) { _, item in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color(hex: "#C87857"))
                                .frame(width: barWidth, height: max(2, geo.size.height * CGFloat(item.value / maxValue)))
                                .help("\(item.date): \(String(format: "$%.2f", item.value))")
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                }
                .frame(height: 120)

                Text("Hover a bar for details")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("Total (30d): \(String(format: "$%.2f", points.reduce(0) { $0 + $1.value }))")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - GitHub Inline Connect

struct GitHubInlineConnectView: View {
    let authService: GitHubAuthService
    let accountId: UUID
    let onDone: (GitHubAccountInfo?) -> Void
    @State private var started = false
    @State private var copied = false

    var body: some View {
        VStack(spacing: 16) {
            navHeader

            ServiceIconView(serviceType: .copilot, avatarURL: nil, size: 48)

            if let code = authService.userCode {
                Text("Enter this code on GitHub:")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(code)
                    .font(.system(.title2, design: .monospaced, weight: .bold))
                    .kerning(4)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(ServiceType.copilot.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        copied = false
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        Text(copied ? "Copied!" : "Copy code")
                    }
                    .font(.caption.weight(.medium))
                }
                .buttonStyle(.bordered)
                .tint(ServiceType.copilot.accentColor)
                .controlSize(.small)

                ProgressView()
                    .controlSize(.small)
            } else if authService.isLoading {
                ProgressView()
                Text("Connecting...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Sign in with your GitHub account\nto track Copilot premium request usage.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            }

            if !started {
                Button {
                    started = true
                    Task {
                        let info = await authService.startDeviceFlow(for: accountId)
                        onDone(info)
                    }
                } label: {
                    Text("Sign in with GitHub")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(ServiceType.copilot.accentColor)
                .padding(.horizontal, 16)
            }

            Spacer().frame(height: 4)
        }
        .padding(.bottom, 12)
    }

    private var navHeader: some View {
        HStack(spacing: 8) {
            Button { onDone(nil) } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.medium))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Text("Connect GitHub")
                .font(.headline)

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 4)
    }
}

// MARK: - Claude Inline Connect

struct ClaudeInlineConnectView: View {
    let authService: AnthropicAuthService
    let accountId: UUID
    let onDone: (ClaudeAccountInfo?) -> Void
    @State private var oauthStarted = false
    @State private var authCode: String = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 16) {
            navHeader

            ServiceIconView(serviceType: .claude, avatarURL: nil, size: 48)

            if oauthStarted {
                Text("Sign in on the browser, then\npaste the authorization code:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)

                VStack(alignment: .leading, spacing: 4) {
                    TextField("Paste authorization code...", text: $authCode)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                }
                .padding(.horizontal, 16)

                Button {
                    Task {
                        errorMessage = nil
                        let info = await authService.exchangeCode(authCode, for: accountId)
                        if info != nil {
                            onDone(info)
                        } else {
                            errorMessage = "Invalid code. Try again."
                        }
                    }
                } label: {
                    Group {
                        if authService.isLoading {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Connect")
                                .font(.subheadline.weight(.medium))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(ServiceType.claude.accentColor)
                .disabled(authCode.isEmpty || authService.isLoading)
                .padding(.horizontal, 16)
            } else {
                Text("Sign in with your Claude Pro/Max\naccount to track usage.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)

                Button {
                    authService.startOAuth(for: accountId)
                    oauthStarted = true
                } label: {
                    Text("Sign in with Claude")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(ServiceType.claude.accentColor)
                .padding(.horizontal, 16)
            }

            Spacer().frame(height: 4)
        }
        .padding(.bottom, 12)
    }

    private var navHeader: some View {
        HStack(spacing: 8) {
            Button { onDone(nil) } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.medium))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Text("Connect Claude")
                .font(.headline)

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 4)
    }
}

// MARK: - OpenAI Inline Connect (Device Flow)

struct OpenAIInlineConnectView: View {
    let authService: OpenAIAuthService
    let accountId: UUID
    let onDone: (OpenAIAccountInfo?) -> Void
    var onSwitchToAPIKey: (() -> Void)? = nil
    @State private var copied = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 16) {
            navHeader

            ServiceIconView(serviceType: .chatgpt, avatarURL: nil, size: 48)

            if let code = authService.userCode {
                Text("Enter this code on OpenAI:")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(code)
                    .font(.system(.title2, design: .monospaced, weight: .bold))
                    .kerning(4)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(
                        ServiceType.chatgpt.accentColor.opacity(0.1),
                        in: RoundedRectangle(cornerRadius: 10)
                    )

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        copied = false
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        Text(copied ? "Copied!" : "Copy code")
                    }
                    .font(.caption.weight(.medium))
                }
                .buttonStyle(.bordered)
                .tint(ServiceType.chatgpt.accentColor)
                .controlSize(.small)

                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Waiting for authorization...")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Button {
                    cancelFlow()
                } label: {
                    Text("Cancel")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

            } else if authService.isLoading {
                ProgressView()
                Text("Connecting to OpenAI...")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if onSwitchToAPIKey != nil {
                    Button {
                        cancelFlow()
                        onSwitchToAPIKey?()
                    } label: {
                        Text("Use API Key Instead")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(ServiceType.chatgpt.accentColor)
                }

                Button {
                    cancelFlow()
                } label: {
                    Text("Cancel")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

            } else if errorMessage != nil {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title2)
                    .foregroundStyle(.orange)

                Text(errorMessage ?? "Sign-in failed.\nUse an API key instead, or try again later.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)

                if onSwitchToAPIKey != nil {
                    Button {
                        cancelFlow()
                        onSwitchToAPIKey?()
                    } label: {
                        Text("Use API Key Instead")
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(ServiceType.chatgpt.accentColor)
                    .padding(.horizontal, 16)
                }

                Button {
                    startFlow()
                } label: {
                    Text("Try Again")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            } else {
                Text("Sign in with your OpenAI account\nto connect OpenAI.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)

                Button {
                    startFlow()
                } label: {
                    Text("Sign in with OpenAI")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(ServiceType.chatgpt.accentColor)
                .padding(.horizontal, 16)

                if onSwitchToAPIKey != nil {
                    Button {
                        onSwitchToAPIKey?()
                    } label: {
                        Text("Use API Key Instead")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }

            Spacer().frame(height: 4)
        }
        .padding(.bottom, 12)
        .onAppear {
            // If a flow is already active for this account, just observe it.
            if authService.isFlowActive(for: accountId) {
                // Flow is running, view will observe userCode/isLoading
            } else if authService.flowFinished && authService.finishedFlowAccountId == accountId {
                // Flow finished while window was closed — consume result only if it's for THIS account
                let result = authService.consumeResult()
                if result != nil {
                    onDone(result)
                } else {
                    errorMessage = authService.lastFlowError ?? "Sign-in failed"
                }
            }
            // Otherwise show the "Sign in with OpenAI" button
        }
        .onChange(of: authService.flowFinished) { _, finished in
            if finished && authService.finishedFlowAccountId == accountId {
                let result = authService.consumeResult()
                if result != nil {
                    onDone(result)
                } else {
                    errorMessage = authService.lastFlowError ?? "Sign-in failed"
                }
            }
        }
    }

    private func startFlow() {
        errorMessage = nil
        authService.beginDeviceFlow(for: accountId)
    }

    private func cancelFlow() {
        authService.cancelDeviceFlow()
        errorMessage = nil
    }

    private var navHeader: some View {
        HStack(spacing: 8) {
            Button {
                cancelFlow()
                onDone(nil)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.medium))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Text("Connect OpenAI")
                .font(.headline)

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 4)
    }
}

// MARK: - Claude API Key Inline Connect

struct ClaudeAPIKeyInlineConnectView: View {
    let authService: AnthropicAuthService
    let accountId: UUID
    let onDone: (ClaudeAccountInfo?) -> Void
    @State private var apiKey: String = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 16) {
            navHeader

            ServiceIconView(serviceType: .claude, avatarURL: nil, size: 48)

            Text("Enter your Anthropic API key\nto connect Claude.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)

            VStack(alignment: .leading, spacing: 4) {
                SecureField("sk-ant-...", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 16)

            Button {
                let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    errorMessage = "Please enter an API key."
                    return
                }
                let info = authService.saveAPIKey(trimmed, for: accountId)
                onDone(info)
            } label: {
                Text("Connect")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(ServiceType.claude.accentColor)
            .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .padding(.horizontal, 16)

            Link(destination: URL(string: "https://console.anthropic.com/settings/keys")!) {
                Text("Get an API key →")
                    .font(.caption)
                    .foregroundStyle(.blue)
            }

            Spacer().frame(height: 4)
        }
        .padding(.bottom, 12)
    }

    private var navHeader: some View {
        HStack(spacing: 8) {
            Button { onDone(nil) } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.medium))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Text("Connect Claude")
                .font(.headline)

            HStack(spacing: 4) {
                Image(systemName: "key")
                    .font(.caption2)
                Text("API Key")
                    .font(.caption2.weight(.medium))
            }
            .foregroundStyle(ServiceType.claude.accentColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(ServiceType.claude.accentColor.opacity(0.1), in: Capsule())

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 4)
    }
}

// MARK: - OpenAI API Key Inline Connect

struct OpenAIAPIKeyInlineConnectView: View {
    let authService: OpenAIAuthService
    let accountId: UUID
    let onDone: (OpenAIAccountInfo?) -> Void
    @State private var apiKey: String = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 16) {
            navHeader

            ServiceIconView(serviceType: .chatgpt, avatarURL: nil, size: 48)

            Text("Enter your OpenAI API key\nto connect OpenAI.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)

            VStack(alignment: .leading, spacing: 4) {
                SecureField("sk-...", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 16)

            Button {
                let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    errorMessage = "Please enter an API key."
                    return
                }
                let info = authService.saveAPIKey(trimmed, for: accountId)
                onDone(info)
            } label: {
                Text("Connect")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(ServiceType.chatgpt.accentColor)
            .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .padding(.horizontal, 16)

            Link(destination: URL(string: "https://platform.openai.com/api-keys")!) {
                Text("Get an API key →")
                    .font(.caption)
                    .foregroundStyle(.blue)
            }

            Spacer().frame(height: 4)
        }
        .padding(.bottom, 12)
    }

    private var navHeader: some View {
        HStack(spacing: 8) {
            Button { onDone(nil) } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.medium))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Text("Connect OpenAI")
                .font(.headline)

            HStack(spacing: 4) {
                Image(systemName: "key")
                    .font(.caption2)
                Text("API Key")
                    .font(.caption2.weight(.medium))
            }
            .foregroundStyle(ServiceType.chatgpt.accentColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(ServiceType.chatgpt.accentColor.opacity(0.1), in: Capsule())

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 4)
    }
}

// MARK: - Kimi Inline Connect (API Key)

struct KimiInlineConnectView: View {
    let authService: KimiAuthService
    let accountId: UUID
    let onDone: (KimiAccountInfo?) -> Void
    @State private var apiKey: String = ""
    @State private var errorMessage: String?
    @State private var isImportingFromBrowser = false

    var body: some View {
        VStack(spacing: 16) {
            navHeader

            ServiceIconView(serviceType: .kimi, avatarURL: nil, size: 48)

            Text("Import from a browser where you’re signed in at kimi.com,\nor paste your kimi-auth token manually.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)

            Button {
                isImportingFromBrowser = true
                errorMessage = nil
                Task {
                    do {
                        let info = try authService.saveFromBrowser(for: accountId)
                        onDone(info)
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                    isImportingFromBrowser = false
                }
            } label: {
                HStack(spacing: 6) {
                    if isImportingFromBrowser {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "globe")
                            .font(.subheadline)
                    }
                    Text(isImportingFromBrowser ? "Reading browser cookies…" : "Import from browser")
                        .font(.subheadline.weight(.medium))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(ServiceType.kimi.accentColor)
            .disabled(isImportingFromBrowser)
            .padding(.horizontal, 16)

            Text("Safari works without extra prompts. Chrome and Arc may ask for Keychain access once — choose Always Allow.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)

            VStack(alignment: .leading, spacing: 4) {
                SecureField("Or paste kimi-auth JWT…", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 16)

            Button {
                let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    errorMessage = "Please enter a token."
                    return
                }
                let info = authService.saveAPIKey(trimmed, for: accountId)
                onDone(info)
            } label: {
                Text("Connect with pasted token")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.bordered)
            .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isImportingFromBrowser)
            .padding(.horizontal, 16)

            Link(destination: URL(string: "https://www.kimi.com/code/console")!) {
                Text("Open Kimi Code console →")
                    .font(.caption)
                    .foregroundStyle(.blue)
            }

            Spacer().frame(height: 4)
        }
        .padding(.bottom, 12)
    }

    private var navHeader: some View {
        HStack(spacing: 8) {
            Button { onDone(nil) } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.medium))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Text("Connect Kimi AI")
                .font(.headline)

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 4)
    }
}

// MARK: - Gemini OAuth Connect (Google Account)

struct GeminiOAuthConnectView: View {
    let authService: GeminiAuthService
    let accountId: UUID
    let onDone: (GeminiAccountInfo?) -> Void
    @State private var isConnecting: Bool = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 16) {
            navHeader

            ServiceIconView(serviceType: .gemini, avatarURL: nil, size: 48)

            VStack(spacing: 6) {
                Text("Sign in with Google")
                    .font(.subheadline.weight(.medium))

                Text(isConnecting
                    ? "Complete sign-in in your browser.\nThis window will update automatically."
                    : "Sign in with your Google account\nto show real-time quota & usage data.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 10) {
                Button {
                    isConnecting = true
                    errorMessage = nil
                    Task {
                        do {
                            let info = try await authService.startOAuth(for: accountId)
                            onDone(info)
                        } catch is CancellationError {
                            // User cancelled
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                        isConnecting = false
                    }
                } label: {
                    HStack(spacing: 6) {
                        if isConnecting {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "person.badge.key")
                                .font(.subheadline)
                        }
                        Text(isConnecting ? "Waiting for browser..." : "Sign in with Google")
                            .font(.subheadline.weight(.medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(ServiceType.gemini.accentColor)
                .disabled(isConnecting)
                .padding(.horizontal, 16)
            }

            Text("Opens Google sign-in in your default browser.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)

            Spacer().frame(height: 4)
        }
        .padding(.bottom, 12)
    }

    private var navHeader: some View {
        HStack(spacing: 8) {
            Button { onDone(nil) } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.medium))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Text("Connect Gemini")
                .font(.headline)

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 4)
    }
}

// MARK: - Gemini Inline Connect (API Key)

struct GeminiInlineConnectView: View {
    let authService: GeminiAuthService
    let accountId: UUID
    let onDone: (GeminiAccountInfo?) -> Void
    @State private var apiKey: String = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 16) {
            navHeader

            ServiceIconView(serviceType: .gemini, avatarURL: nil, size: 48)

            Text("Enter your Google AI API key\nto connect Gemini.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)

            VStack(alignment: .leading, spacing: 4) {
                SecureField("AI...", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 16)

            Button {
                let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    errorMessage = "Please enter an API key."
                    return
                }
                let info = authService.saveAPIKey(trimmed, for: accountId)
                onDone(info)
            } label: {
                Text("Connect")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(ServiceType.gemini.accentColor)
            .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .padding(.horizontal, 16)

            Link(destination: URL(string: "https://aistudio.google.com/apikey")!) {
                Text("Get an API key →")
                    .font(.caption)
                    .foregroundStyle(.blue)
            }

            Spacer().frame(height: 4)
        }
        .padding(.bottom, 12)
    }

    private var navHeader: some View {
        HStack(spacing: 8) {
            Button { onDone(nil) } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.medium))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Text("Connect Gemini")
                .font(.headline)

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 4)
    }
}

// MARK: - Cursor Inline Connect (Session Token)

struct CursorInlineConnectView: View {
    let authService: CursorAuthService
    let accountId: UUID
    let onDone: (CursorAccountInfo?) -> Void
    @State private var token: String = ""
    @State private var errorMessage: String?
    @State private var isImportingFromBrowser = false

    var body: some View {
        VStack(spacing: 16) {
            navHeader

            ServiceIconView(serviceType: .cursor, avatarURL: nil, size: 48)

            Text("Sign in at cursor.com in Safari, then tap Import below.\nSafari avoids the extra Keychain prompts that Chrome needs.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)

            Button {
                isImportingFromBrowser = true
                errorMessage = nil
                Task {
                    do {
                        let info = try authService.saveFromBrowser(for: accountId)
                        onDone(info)
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                    isImportingFromBrowser = false
                }
            } label: {
                HStack(spacing: 6) {
                    if isImportingFromBrowser {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "safari")
                            .font(.subheadline)
                    }
                    Text(isImportingFromBrowser ? "Reading Safari cookies…" : "Import from Safari")
                        .font(.subheadline.weight(.medium))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(ServiceType.cursor.accentColor)
            .disabled(isImportingFromBrowser)
            .padding(.horizontal, 16)

            Text("You can keep using Chrome for Cursor day to day — only Safari needs your cursor.com login for this one-time import.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)

            VStack(alignment: .leading, spacing: 4) {
                SecureField("Or paste cookie header…", text: $token)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 16)

            Button {
                let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    errorMessage = "Please enter a session token."
                    return
                }
                let info = authService.saveToken(trimmed, for: accountId)
                onDone(info)
            } label: {
                Text("Connect with pasted token")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.bordered)
            .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isImportingFromBrowser)
            .padding(.horizontal, 16)

            Text("Manual fallback: Safari → Develop → Show Web Inspector → Storage → Cookies → WorkosCursorSessionToken.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)

            Spacer().frame(height: 4)
        }
        .padding(.bottom, 12)
    }

    private var navHeader: some View {
        HStack(spacing: 8) {
            Button { onDone(nil) } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.medium))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Text("Connect Cursor")
                .font(.headline)

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 4)
    }
}

// MARK: - OpenRouter Inline Connect (API Key)

struct OpenRouterInlineConnectView: View {
    let authService: OpenRouterAuthService
    let accountId: UUID
    let onDone: (OpenRouterAccountInfo?) -> Void
    @State private var apiKey: String = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 16) {
            navHeader

            ServiceIconView(serviceType: .openrouter, avatarURL: nil, size: 48)

            Text("Enter your OpenRouter API key\nto track credit usage.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)

            VStack(alignment: .leading, spacing: 4) {
                SecureField("sk-or-...", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 16)

            Button {
                let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    errorMessage = "Please enter an API key."
                    return
                }
                let info = authService.saveAPIKey(trimmed, for: accountId)
                onDone(info)
            } label: {
                Text("Connect")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(ServiceType.openrouter.accentColor)
            .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .padding(.horizontal, 16)

            Link(destination: URL(string: "https://openrouter.ai/keys")!) {
                Text("Get an API key →")
                    .font(.caption)
                    .foregroundStyle(.blue)
            }

            Spacer().frame(height: 4)
        }
        .padding(.bottom, 12)
    }

    private var navHeader: some View {
        HStack(spacing: 8) {
            Button { onDone(nil) } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.medium))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Text("Connect OpenRouter")
                .font(.headline)

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 4)
    }
}

// MARK: - Kiro Inline Connect (API Key)

struct KiroInlineConnectView: View {
    let authService: KiroAuthService
    let accountId: UUID
    let onDone: (KiroAccountInfo?) -> Void
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 16) {
            navHeader

            ServiceIconView(serviceType: .kiro, avatarURL: nil, size: 48)

            Text("Usageview reads quotas from your local\nkiro-cli login (same as CodexBar).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
            }

            Button {
                if let info = authService.linkCLI(for: accountId) {
                    onDone(info)
                } else {
                    errorMessage = "Install kiro-cli and run “kiro-cli login” first."
                }
            } label: {
                Text("Use kiro-cli")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(ServiceType.kiro.accentColor)
            .padding(.horizontal, 16)

            Link(destination: URL(string: "https://kiro.dev/docs/cli")!) {
                Text("Install kiro-cli →")
                    .font(.caption)
                    .foregroundStyle(.blue)
            }

            Spacer().frame(height: 4)
        }
        .padding(.bottom, 12)
    }

    private var navHeader: some View {
        HStack(spacing: 8) {
            Button { onDone(nil) } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.medium))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Text("Connect Kiro")
                .font(.headline)

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 4)
    }
}

// MARK: - Augment Inline Connect (API Key)

struct AugmentInlineConnectView: View {
    let authService: AugmentAuthService
    let accountId: UUID
    let onDone: (AugmentAccountInfo?) -> Void
    @State private var apiKey: String = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 16) {
            navHeader

            ServiceIconView(serviceType: .augment, avatarURL: nil, size: 48)

            Text("Enter your Augment API key\nto track usage.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)

            VStack(alignment: .leading, spacing: 4) {
                SecureField("API key...", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 16)

            Button {
                let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    errorMessage = "Please enter an API key."
                    return
                }
                let info = authService.saveAPIKey(trimmed, for: accountId)
                onDone(info)
            } label: {
                Text("Connect")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(ServiceType.augment.accentColor)
            .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .padding(.horizontal, 16)

            Text("Usage tracking is status-only for now.")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Spacer().frame(height: 4)
        }
        .padding(.bottom, 12)
    }

    private var navHeader: some View {
        HStack(spacing: 8) {
            Button { onDone(nil) } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.medium))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Text("Connect Augment")
                .font(.headline)

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 4)
    }
}

// MARK: - JetBrains Inline Connect (Auto-Detect)

struct JetBrainsInlineConnectView: View {
    let authService: JetBrainsAuthService
    let accountId: UUID
    let onDone: (JetBrainsAccountInfo?) -> Void
    @State private var detecting: Bool = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 16) {
            navHeader

            ServiceIconView(serviceType: .jetbrainsAI, avatarURL: nil, size: 48)

            Text("Usageview can auto-detect your\nJetBrains IDE AI quota.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
            }

            Button {
                detecting = true
                errorMessage = nil
                if let info = authService.autoEnable(for: accountId) {
                    onDone(info)
                } else {
                    errorMessage = "No JetBrains IDE with AI Assistant found.\nMake sure a JetBrains IDE is installed."
                    detecting = false
                }
            } label: {
                HStack(spacing: 6) {
                    if detecting {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(detecting ? "Detecting..." : "Auto-Detect IDE")
                        .font(.subheadline.weight(.medium))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(ServiceType.jetbrainsAI.accentColor)
            .disabled(detecting)
            .padding(.horizontal, 16)

            Text("Reads AIAssistantQuotaManager2.xml\nfrom your IDE config folder.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)

            Spacer().frame(height: 4)
        }
        .padding(.bottom, 12)
    }

    private var navHeader: some View {
        HStack(spacing: 8) {
            Button { onDone(nil) } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.medium))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Text("Connect JetBrains AI")
                .font(.headline)

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 4)
    }
}

// MARK: - Codex Inline Connect (CLI)

struct CodexInlineConnectView: View {
    let authService: CodexAuthService
    let accountId: UUID
    let onDone: (CodexAccountInfo?) -> Void
    @State private var isConnecting = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 16) {
            navHeader

            ServiceIconView(serviceType: .codex, avatarURL: nil, size: 48)

            Text("Sign in with Codex CLI first (`codex` in Terminal), then import your session here for 5-hour and weekly usage.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
                    .multilineTextAlignment(.center)
            }

            Button {
                isConnecting = true
                errorMessage = nil
                do {
                    let info = try authService.connectFromCLI(for: accountId)
                    onDone(info)
                } catch {
                    errorMessage = error.localizedDescription
                }
                isConnecting = false
            } label: {
                HStack(spacing: 6) {
                    if isConnecting {
                        ProgressView().controlSize(.small)
                    }
                    Text(isConnecting ? "Reading ~/.codex/auth.json…" : "Import from Codex CLI")
                        .font(.subheadline.weight(.medium))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(ServiceType.codex.accentColor)
            .disabled(isConnecting)
            .padding(.horizontal, 16)

            Link(destination: URL(string: "https://chatgpt.com/codex/settings/usage")!) {
                Text("Open Codex usage dashboard →")
                    .font(.caption)
                    .foregroundStyle(.blue)
            }

            Spacer().frame(height: 4)
        }
        .padding(.bottom, 12)
    }

    private var navHeader: some View {
        HStack(spacing: 8) {
            Button { onDone(nil) } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.medium))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Text("Connect Codex")
                .font(.headline)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 4)
    }
}

// MARK: - Z.ai / GLM Inline Connect

struct ZaiInlineConnectView: View {
    let authService: ZaiAuthService
    let accountId: UUID
    let onDone: (ZaiAccountInfo?) -> Void
    @State private var apiKey: String = ""
    @State private var region: ZaiAPIRegion = .global
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 16) {
            navHeader

            ServiceIconView(serviceType: .zai, avatarURL: nil, size: 48)

            Text("Enter your Z.ai / GLM API key. Usage shows token, MCP, and short-window quotas from the BigModel API.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)

            Picker("API region", selection: $region) {
                ForEach(ZaiAPIRegion.allCases, id: \.self) { r in
                    Text(r.displayName).tag(r)
                }
            }
            .pickerStyle(.menu)
            .padding(.horizontal, 16)

            VStack(alignment: .leading, spacing: 4) {
                SecureField("API key…", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 16)

            Button {
                let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    errorMessage = "Please enter an API key."
                    return
                }
                let info = authService.saveAPIKey(trimmed, for: accountId, region: region)
                onDone(info)
            } label: {
                Text("Connect")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(ServiceType.zai.accentColor)
            .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .padding(.horizontal, 16)

            Link(destination: URL(string: "https://z.ai/manage-apikey")!) {
                Text("Get an API key →")
                    .font(.caption)
                    .foregroundStyle(.blue)
            }

            Spacer().frame(height: 4)
        }
        .padding(.bottom, 12)
    }

    private var navHeader: some View {
        HStack(spacing: 8) {
            Button { onDone(nil) } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.medium))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Text("Connect Z.ai")
                .font(.headline)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 4)
    }
}
