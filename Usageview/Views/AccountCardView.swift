import SwiftUI

struct AccountCardView: View {
    let account: Account
    let isConnected: Bool
    let isRefreshing: Bool
    @Binding var renamingId: UUID?
    @Binding var renameText: String
    var onConnect: () -> Void = {}
    var onRefresh: () -> Void = {}
    var onSaveRename: () -> Void = {}
    var onDisconnect: () -> Void = {}
    var onRemove: () -> Void = {}
    var onTap: () -> Void = {}
    var onPin: () -> Void = {}
    var onSwitchCodexSession: () -> Void = {}
    var onCaptureCodexSession: () -> Void = {}
    var onEnableCodexCLI: () -> Void = {}
    var onMoveUp: () -> Void = {}
    var onMoveDown: () -> Void = {}
    var isPinned: Bool = false
    var isActiveCodexSession: Bool = false
    var canSwitchCodexSession: Bool = false
    var canCaptureCodexSession: Bool = false
    var canEnableCodexCLI: Bool = false
    var canMoveUp: Bool = false
    var canMoveDown: Bool = false
    var showWeeklyLimit: Bool = false

    private var isRenaming: Bool { renamingId == account.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header: icon + name + menu
            HStack(spacing: 10) {
                ServiceIconView(
                    serviceType: account.serviceType,
                    avatarURL: isConnected ? account.avatarURL : nil,
                    size: 28
                )
                .overlay(alignment: .bottomTrailing) {
                    if isConnected && isActiveCodexSession {
                        Circle()
                            .fill(.green)
                            .frame(width: 8, height: 8)
                            .overlay(
                                Circle()
                                    .stroke(.white.opacity(0.9), lineWidth: 1)
                            )
                    }
                }

                if isRenaming {
                    HStack(spacing: 4) {
                        TextField("Name", text: $renameText)
                            .textFieldStyle(.roundedBorder)
                            .font(.subheadline)
                            .onSubmit { onSaveRename() }

                        Button {
                            onSaveRename()
                        } label: {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(account.accentColor)
                        }
                        .buttonStyle(.plain)

                        Button {
                            renamingId = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(isConnected
                            ? (account.label.isEmpty
                                ? (account.username ?? account.serviceType.displayName)
                                : account.label)
                            : account.serviceType.displayName)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)

                        if isConnected, (account.username != nil || !account.label.isEmpty) {
                            Text(account.serviceType.displayName)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    if account.isAtLimit && isConnected {
                        Text("LIMIT")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(.red, in: Capsule())
                    }

                    AccountMenuButton(
                        isConnected: isConnected,
                        isPinned: isPinned,
                        canMoveUp: canMoveUp,
                        canMoveDown: canMoveDown,
                        onRefresh: onRefresh,
                        onRename: {
                            renameText = account.label.isEmpty ? (account.username ?? "") : account.label
                            renamingId = account.id
                        },
                        onPin: onPin,
                        onSwitchCodexSession: onSwitchCodexSession,
                        onCaptureCodexSession: onCaptureCodexSession,
                        onEnableCodexCLI: onEnableCodexCLI,
                        onMoveUp: onMoveUp,
                        onMoveDown: onMoveDown,
                        onDisconnect: onDisconnect,
                        onRemove: onRemove,
                        isActiveCodexSession: isActiveCodexSession,
                        canSwitchCodexSession: canSwitchCodexSession,
                        canCaptureCodexSession: canCaptureCodexSession,
                        canEnableCodexCLI: canEnableCodexCLI
                    )
                }
            }

            if isConnected {
                if account.isStatusOnly {
                    // Status-only: show a clean status badge
                    HStack(spacing: 6) {
                        if isRefreshing {
                            ProgressView()
                                .controlSize(.mini)
                        }

                        HStack(spacing: 4) {
                            Circle()
                                .fill(account.formattedUsage == "Inactive" ? .orange : .green)
                                .frame(width: 6, height: 6)
                            Text(account.formattedUsage)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        HStack(spacing: 3) {
                            Image(systemName: "key")
                                .font(.system(size: 9))
                            Text("API Key")
                                .font(.caption2)
                        }
                        .foregroundStyle(.tertiary)
                    }
                } else if account.hasDualWindows {
                    // Dual rate windows (Claude/ChatGPT: 5h/7d, Gemini: Pro/Flash)
                    if showWeeklyLimit {
                        // Show both windows, labeled
                        if isRefreshing {
                            HStack {
                                ProgressView()
                                    .controlSize(.mini)
                                Spacer()
                            }
                        }

                        claudeRateRow(
                            label: account.serviceType.primaryRateLabel(authMethod: account.authMethod),
                            usage: account.fiveHourUsage ?? 0,
                            resetDate: account.fiveHourResetDate
                        )

                        claudeRateRow(
                            label: account.serviceType.secondaryRateLabel(authMethod: account.authMethod),
                            usage: account.sevenDayUsage ?? 0,
                            resetDate: account.sevenDayResetDate
                        )
                    } else {
                        // Show the short window in collapsed mode (5h for Claude/ChatGPT, Pro for Gemini)
                        let primaryUsage = account.fiveHourUsage ?? 0
                        let primaryPct = min(primaryUsage / 100.0, 1.0)
                        let primaryResetDate = account.fiveHourResetDate
                        let primaryMaxHours: Double = account.serviceType == .gemini ? 25 : 6

                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(.primary.opacity(0.08))
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(rateBarColor(primaryUsage))
                                    .frame(width: max(0, geo.size.width * primaryPct))
                                    .animation(.easeInOut(duration: 0.5), value: primaryPct)
                            }
                        }
                        .frame(height: 5)

                        HStack(spacing: 0) {
                            if isRefreshing {
                                ProgressView()
                                    .controlSize(.mini)
                                    .padding(.trailing, 6)
                            }

                            Text("\(Int(primaryUsage))% used")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Spacer()

                            if Account.isResetReasonable(primaryResetDate, maxHours: primaryMaxHours) {
                                Text("resets \(Account.resetLabel(for: primaryResetDate))")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                } else if account.hasCursorLanes {
                    if isRefreshing {
                        HStack {
                            ProgressView()
                                .controlSize(.mini)
                            Spacer()
                        }
                    }
                    claudeRateRow(
                        label: account.serviceType.primaryRateLabel(authMethod: account.authMethod),
                        usage: account.currentUsage,
                        resetDate: account.resetDate
                    )
                    if let auto = account.fiveHourUsage {
                        claudeRateRow(
                            label: account.serviceType.secondaryRateLabel(authMethod: account.authMethod),
                            usage: auto,
                            resetDate: account.resetDate
                        )
                    }
                    if let api = account.tertiaryUsage {
                        claudeRateRow(
                            label: account.serviceType.tertiaryRateLabel() ?? "API",
                            usage: api,
                            resetDate: account.resetDate
                        )
                    }
                    if let spend = account.monthlySpendUSD, let limit = account.monthlySpendLimitUSD, limit > 0 {
                        Text(String(format: "Plan spend $%.2f / $%.2f", spend, limit))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                } else if account.hasZaiTripleWindows {
                    if isRefreshing {
                        HStack {
                            ProgressView()
                                .controlSize(.mini)
                            Spacer()
                        }
                    }
                    claudeRateRow(
                        label: "Tokens",
                        usage: account.fiveHourUsage ?? 0,
                        resetDate: account.fiveHourResetDate
                    )
                    if let mcp = account.sevenDayUsage {
                        claudeRateRow(
                            label: "MCP",
                            usage: mcp,
                            resetDate: account.sevenDayResetDate
                        )
                    }
                    if let session = account.tertiaryUsage {
                        claudeRateRow(
                            label: account.serviceType.tertiaryRateLabel() ?? "5h",
                            usage: session,
                            resetDate: account.tertiaryResetDate
                        )
                    }
                } else if account.hasCopilotDualQuotas && showWeeklyLimit {
                    // Copilot: premium + chat quotas (shown when toggle is on)
                    if isRefreshing {
                        HStack {
                            ProgressView()
                                .controlSize(.mini)
                            Spacer()
                        }
                    }

                    copilotQuotaRow(
                        label: "Premium",
                        used: account.currentUsage,
                        limit: account.usageLimit
                    )

                    copilotQuotaRow(
                        label: "Chat",
                        used: account.chatUsage ?? 0,
                        limit: 100,
                        isPercent: true
                    )
                } else if account.hasKimiBilling {
                    // Kimi: weekly quota bar
                    let weeklyPct = (account.kimiWeeklyLimit ?? 0) > 0
                        ? min((account.kimiWeeklyUsed ?? 0) / (account.kimiWeeklyLimit ?? 1), 1.0)
                        : 0

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(.primary.opacity(0.06))
                            RoundedRectangle(cornerRadius: 3)
                                .fill(kimiBarColor(weeklyPct))
                                .frame(width: max(0, geo.size.width * weeklyPct))
                                .animation(.easeInOut(duration: 0.5), value: weeklyPct)
                        }
                    }
                    .frame(height: 5)

                    HStack(spacing: 0) {
                        if isRefreshing {
                            ProgressView()
                                .controlSize(.mini)
                                .padding(.trailing, 6)
                        }

                        Text("\(Int(account.kimiWeeklyUsed ?? 0))/\(Int(account.kimiWeeklyLimit ?? 0)) weekly")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Spacer()

                        if let reset = account.kimiWeeklyResetDate,
                           reset.timeIntervalSince(.now) > 0 {
                            Text("resets \(Account.resetLabel(for: reset))")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                } else {
                    // Usage bar
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(.primary.opacity(0.06))
                            RoundedRectangle(cornerRadius: 3)
                                .fill(barColor)
                                .frame(width: max(0, geo.size.width * account.usagePercentage))
                                .animation(.easeInOut(duration: 0.5), value: account.usagePercentage)
                        }
                    }
                    .frame(height: 5)

                    // Footer: usage text + reset
                    HStack(spacing: 0) {
                        if isRefreshing {
                            ProgressView()
                                .controlSize(.mini)
                                .padding(.trailing, 6)
                        }

                        Text(account.formattedUsage)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Spacer()

                        Text("resets \(account.resetLabel)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            } else {
                Button { onConnect() } label: {
                    Text("Connect")
                        .font(.caption.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                }
                .buttonStyle(.bordered)
                .tint(account.accentColor)
            }
        }
        .padding(10)
        .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture {
            if isConnected && !isRenaming { onTap() }
        }
    }

    private var barColor: Color {
        if account.usagePercentage >= 1.0 { return .red }
        if account.usagePercentage >= 0.8 { return .orange }
        return account.accentColor
    }

    private func rateBarColor(_ pct: Double) -> Color {
        if pct >= 100 { return .red }
        if pct >= 80 { return .orange }
        return account.accentColor
    }

    private func claudeRateRow(label: String? = nil, usage: Double, resetDate: Date?) -> some View {
        HStack(spacing: 8) {
            if let label {
                Text(label)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .frame(width: 18, alignment: .leading)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2.5)
                        .fill(.primary.opacity(0.08))
                    RoundedRectangle(cornerRadius: 2.5)
                        .fill(rateBarColor(usage))
                        .frame(width: max(0, geo.size.width * min(usage / 100, 1.0)))
                        .animation(.easeInOut(duration: 0.5), value: usage)
                }
            }
            .frame(height: 4)

            Text("\(Int(usage))%")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(usage >= 100 ? .red : .secondary)
                .frame(width: 30, alignment: .trailing)

            if Account.isResetReasonable(resetDate, maxHours: 192) {
                Text(Account.resetLabel(for: resetDate))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .frame(width: 42, alignment: .trailing)
            } else {
                Color.clear.frame(width: 42)
            }
        }
    }

    private func copilotQuotaRow(label: String, used: Double, limit: Double, isPercent: Bool = false) -> some View {
        let pct = isPercent ? min(used / 100.0, 1.0) : (limit > 0 ? min(used / limit, 1.0) : 0)
        return HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.tertiary)
                .frame(width: 42, alignment: .leading)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2.5)
                        .fill(.primary.opacity(0.08))
                    RoundedRectangle(cornerRadius: 2.5)
                        .fill(rateBarColor(pct * 100))
                        .frame(width: max(0, geo.size.width * pct))
                        .animation(.easeInOut(duration: 0.5), value: pct)
                }
            }
            .frame(height: 4)

            if isPercent {
                Text("\(Int(used))%")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(used >= 100 ? .red : .secondary)
                    .frame(width: 36, alignment: .trailing)
            } else {
                Text("\(Int(used))/\(Int(limit))")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(used >= limit ? .red : .secondary)
                    .frame(width: 50, alignment: .trailing)
            }
        }
    }

    private func kimiBarColor(_ pct: Double) -> Color {
        if pct >= 1.0 { return .red }
        if pct >= 0.8 { return .orange }
        return account.accentColor
    }
}

// MARK: - Service Icon (bundled logos + AsyncImage for user avatars)

struct ServiceIconView: View {
    let serviceType: ServiceType
    let avatarURL: String?
    let size: CGFloat

    var body: some View {
        if let avatarURL, let url = URL(string: avatarURL) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable()
                        .aspectRatio(contentMode: .fill)
                case .failure:
                    brandIcon
                default:
                    brandIcon
                }
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
        } else {
            brandIcon
        }
    }

    private var brandIcon: some View {
        Group {
            if let symbol = serviceType.symbolName {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.45, weight: .semibold))
                    .foregroundStyle(serviceType.accentColor)
                    .frame(width: size, height: size)
                    .background(serviceType.accentColor.opacity(0.12), in: Circle())
            } else {
                Image(serviceType.assetName)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            }
        }
    }
}

// MARK: - Compact Account Row (single-line, dense)

struct CompactAccountRow: View {
    let account: Account
    let isConnected: Bool
    let isRefreshing: Bool
    @Binding var renamingId: UUID?
    @Binding var renameText: String
    var onConnect: () -> Void = {}
    var onRefresh: () -> Void = {}
    var onSaveRename: () -> Void = {}
    var onDisconnect: () -> Void = {}
    var onRemove: () -> Void = {}
    var onTap: () -> Void = {}
    var onPin: () -> Void = {}
    var onSwitchCodexSession: () -> Void = {}
    var onCaptureCodexSession: () -> Void = {}
    var onEnableCodexCLI: () -> Void = {}
    var onMoveUp: () -> Void = {}
    var onMoveDown: () -> Void = {}
    var isPinned: Bool = false
    var isActiveCodexSession: Bool = false
    var canSwitchCodexSession: Bool = false
    var canCaptureCodexSession: Bool = false
    var canEnableCodexCLI: Bool = false
    var canMoveUp: Bool = false
    var canMoveDown: Bool = false
    var showWeeklyLimit: Bool = false

    private var isRenaming: Bool { renamingId == account.id }

    var body: some View {
        HStack(spacing: 6) {
            ServiceIconView(
                serviceType: account.serviceType,
                avatarURL: isConnected ? account.avatarURL : nil,
                size: 20
            )
            .overlay(alignment: .bottomTrailing) {
                if isConnected && isActiveCodexSession {
                    Circle()
                        .fill(.green)
                        .frame(width: 7, height: 7)
                        .overlay(
                            Circle()
                                .stroke(.white.opacity(0.9), lineWidth: 1)
                        )
                }
            }

            if isRenaming {
                TextField("Name", text: $renameText)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .onSubmit { onSaveRename() }

                Button {
                    onSaveRename()
                } label: {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(account.accentColor)
                }
                .buttonStyle(.plain)

                Button {
                    renamingId = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            } else {
                Text(isConnected
                    ? (account.label.isEmpty
                        ? (account.username ?? account.serviceType.displayName)
                        : account.label)
                    : account.serviceType.displayName)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(minWidth: 60, alignment: .leading)


                if isConnected {
                    Spacer(minLength: 4)

                    if account.isStatusOnly {
                        // Status-only: compact dot + label
                        Circle()
                            .fill(account.formattedUsage == "Inactive" ? .orange : .green)
                            .frame(width: 5, height: 5)
                        Text(account.formattedUsage)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    } else if account.hasDualWindows {
                        if showWeeklyLimit {
                            // Both rate windows with countdown labels
                            VStack(alignment: .trailing, spacing: 2) {
                                compactRateRow(usage: account.fiveHourUsage ?? 0, resetDate: account.fiveHourResetDate)
                                compactRateRow(usage: account.sevenDayUsage ?? 0, resetDate: account.sevenDayResetDate)
                            }
                            .frame(maxWidth: 120)
                        } else {
                            // Single bar — short window only (5h for Claude/ChatGPT, Pro for Gemini)
                            let primaryUsage = account.fiveHourUsage ?? 0
                            let primaryPct = min(primaryUsage / 100.0, 1.0)
                            let primaryResetDate = account.fiveHourResetDate
                            let primaryMaxHours: Double = account.serviceType == .gemini ? 25 : 6

                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(.primary.opacity(0.08))
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(compactRateBarColor(primaryUsage))
                                        .frame(width: max(0, geo.size.width * primaryPct))
                                        .animation(.easeInOut(duration: 0.5), value: primaryPct)
                                }
                            }
                            .frame(maxWidth: 60, maxHeight: 4)

                            Text("\(Int(primaryUsage))%")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(primaryUsage >= 100 ? .red : .secondary)
                                .fixedSize()

                            if Account.isResetReasonable(primaryResetDate, maxHours: primaryMaxHours) {
                                Text(Account.resetLabel(for: primaryResetDate))
                                    .font(.system(size: 9))
                                    .foregroundStyle(.tertiary)
                                    .fixedSize()
                            }
                        }
                    } else if account.hasKimiBilling {
                        // Kimi with billing data: show usage bar
                        let weeklyPct = (account.kimiWeeklyLimit ?? 0) > 0
                            ? min((account.kimiWeeklyUsed ?? 0) / (account.kimiWeeklyLimit ?? 1), 1.0)
                            : 0
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(.primary.opacity(0.06))
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(compactKimiBarColor(weeklyPct))
                                    .frame(width: max(0, geo.size.width * weeklyPct))
                                    .animation(.easeInOut(duration: 0.5), value: weeklyPct)
                            }
                        }
                        .frame(maxWidth: 60, maxHeight: 4)

                        Text("\(Int(account.kimiWeeklyUsed ?? 0))/\(Int(account.kimiWeeklyLimit ?? 0))")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(weeklyPct >= 1.0 ? .red : .secondary)
                            .fixedSize()
                    } else {
                        // Inline usage bar
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(.primary.opacity(0.06))
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(barColor)
                                    .frame(width: max(0, geo.size.width * account.usagePercentage))
                                    .animation(.easeInOut(duration: 0.5), value: account.usagePercentage)
                            }
                        }
                        .frame(maxWidth: 60, maxHeight: 4)

                        Text(compactUsage)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(account.isAtLimit ? .red : .secondary)
                            .fixedSize()

                        Text(account.resetLabel)
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .fixedSize()
                    }

                    if isRefreshing {
                        ProgressView().controlSize(.mini)
                    }

                    AccountMenuButton(
                        isConnected: isConnected,
                        compact: true,
                        isPinned: isPinned,
                        canMoveUp: canMoveUp,
                        canMoveDown: canMoveDown,
                        onRefresh: onRefresh,
                        onRename: {
                            renameText = account.label.isEmpty ? (account.username ?? "") : account.label
                            renamingId = account.id
                        },
                        onPin: onPin,
                        onSwitchCodexSession: onSwitchCodexSession,
                        onCaptureCodexSession: onCaptureCodexSession,
                        onEnableCodexCLI: onEnableCodexCLI,
                        onMoveUp: onMoveUp,
                        onMoveDown: onMoveDown,
                        onDisconnect: onDisconnect,
                        onRemove: onRemove,
                        isActiveCodexSession: isActiveCodexSession,
                        canSwitchCodexSession: canSwitchCodexSession,
                        canCaptureCodexSession: canCaptureCodexSession,
                        canEnableCodexCLI: canEnableCodexCLI
                    )
                } else {
                    Spacer()
                    Button { onConnect() } label: {
                        Text("Connect")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .tint(account.accentColor)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture {
            if isConnected && !isRenaming { onTap() }
        }
    }

    private var compactUsage: String {
        if account.usageUnit == "% used" {
            return "\(Int(account.currentUsage))%"
        }
        return "\(Int(account.currentUsage))/\(Int(account.usageLimit))"
    }

    private var barColor: Color {
        if account.usagePercentage >= 1.0 { return .red }
        if account.usagePercentage >= 0.8 { return .orange }
        return account.accentColor
    }

    private func compactRateBarColor(_ usage: Double) -> Color {
        let pct = usage / 100.0
        if pct >= 1.0 { return .red }
        if pct >= 0.8 { return .orange }
        return account.accentColor
    }

    private func compactKimiBarColor(_ pct: Double) -> Color {
        if pct >= 1.0 { return .red }
        if pct >= 0.8 { return .orange }
        return account.accentColor
    }

    @ViewBuilder
    private func compactRateRow(usage: Double, resetDate: Date?) -> some View {
        let pct = min(usage / 100.0, 1.0)
        HStack(spacing: 3) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(.primary.opacity(0.08))
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(compactRateBarColor(usage))
                        .frame(width: max(0, geo.size.width * pct))
                        .animation(.easeInOut(duration: 0.5), value: pct)
                }
            }
            .frame(maxWidth: 40, maxHeight: 3)

            Text("\(Int(usage))%")
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .foregroundStyle(usage >= 100 ? .red : .secondary)
                .frame(width: 26, alignment: .trailing)

            if let resetDate, resetDate.timeIntervalSince(.now) > 0 {
                Text(Account.resetLabel(for: resetDate))
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                    .frame(width: 32, alignment: .trailing)
            } else {
                Color.clear.frame(width: 32)
            }
        }
    }
}

// MARK: - Account Menu Button (visible ... menu with Refresh/Disconnect/Remove)

struct AccountMenuButton: View {
    let isConnected: Bool
    var compact: Bool = false
    var isPinned: Bool = false
    var canMoveUp: Bool = false
    var canMoveDown: Bool = false
    var onRefresh: () -> Void = {}
    var onRename: () -> Void = {}
    var onPin: () -> Void = {}
    var onSwitchCodexSession: () -> Void = {}
    var onCaptureCodexSession: () -> Void = {}
    var onEnableCodexCLI: () -> Void = {}
    var onMoveUp: () -> Void = {}
    var onMoveDown: () -> Void = {}
    var onDisconnect: () -> Void = {}
    var onRemove: () -> Void = {}
    var isActiveCodexSession: Bool = false
    var canSwitchCodexSession: Bool = false
    var canCaptureCodexSession: Bool = false
    var canEnableCodexCLI: Bool = false

    var body: some View {
        Menu {
            if isConnected {
                Button { onRefresh() } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                Button { onRename() } label: {
                    Label("Rename", systemImage: "pencil")
                }
                Divider()
                Button { onPin() } label: {
                    Label(isPinned ? "Unpin from Menu Bar" : "Pin to Menu Bar",
                          systemImage: isPinned ? "pin.slash.fill" : "pin.fill")
                }
                if canSwitchCodexSession {
                    Button { onSwitchCodexSession() } label: {
                        Label(isActiveCodexSession ? "Current in Codex" : "Switch to This in Codex",
                              systemImage: isActiveCodexSession ? "checkmark.seal.fill" : "arrow.triangle.2.circlepath")
                    }
                    .disabled(isActiveCodexSession)
                    if canCaptureCodexSession {
                        Button { onCaptureCodexSession() } label: {
                            Label("Save Codex Desktop session…", systemImage: "arrow.down.doc.fill")
                        }
                    }
                } else if canCaptureCodexSession {
                    Button { onCaptureCodexSession() } label: {
                        Label("Save Codex Desktop session…", systemImage: "arrow.down.doc.fill")
                    }
                }
            }
            Divider()
            if canMoveUp {
                Button { onMoveUp() } label: {
                    Label("Move Up", systemImage: "arrow.up")
                }
            }
            if canMoveDown {
                Button { onMoveDown() } label: {
                    Label("Move Down", systemImage: "arrow.down")
                }
            }
            if isConnected {
                Divider()
                Button { onDisconnect() } label: {
                    Label("Disconnect", systemImage: "person.crop.circle.badge.minus")
                }
            }
            Button(role: .destructive) { onRemove() } label: {
                Label("Remove Account", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: compact ? 10 : 11))
                .foregroundStyle(.tertiary)
                .frame(width: compact ? 24 : 28, height: compact ? 24 : 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: compact ? 24 : 28)
    }
}
