import Foundation
import AppKit
import os

private let logger = Logger(subsystem: "com.ayangabryl.usage", category: "CodexOAuth")
// Key v3: points to the root Codex folder (captures Local Storage + Partitions).
private let bookmarkKey = "CodexOAuthFolderBookmarkV3"

/// Saves and restores Codex Desktop OAuth sessions per account.
/// Codex Desktop is an Electron app — its session lives in:
///   ~/Library/Application Support/Codex/{Cookies, Local Storage/leveldb/, Session Storage/}
/// We snapshot those files into Usageview's container per account,
/// then restore on demand (after quitting Codex first).
@Observable
@MainActor
final class CodexOAuthSessionService: Sendable {

    // MARK: - Session Files

    /// Items to snapshot from the root `~/Library/Application Support/Codex/` folder.
    ///
    /// The actual encrypted OAuth access token lives in **root-level `Local Storage/`**
    /// (encrypted by the "Codex Safe Storage" macOS Keychain key, which is app-wide and
    /// identical for every account on the same machine — so swapping the leveldb files works).
    ///
    /// The `Partitions/codex-browser-app/` sub-directory holds the Chromium session
    /// cookies used by the embedded web view. Both layers are needed for a clean switch.
    private static let sessionItems = [
        "Local Storage",            // root-level — contains the encrypted access/refresh token
        "Cookies",                  // root-level — Chromium cookie store
        "Cookies-journal",
        "DIPS",
        "DIPS-wal",
        "Local State",
        "Network Persistent State",
        "Preferences",
        "Partitions",               // entire partition tree (codex-browser-app session)
    ]

    // MARK: - Paths

    /// Root app-support folder for Codex Desktop.
    static func codexAppSupportURL() -> URL {
        CodexAuthService.realHomeDirectory()
            .appendingPathComponent("Library/Application Support/Codex", isDirectory: true)
    }

    private static func snapshotsRootURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("UsageviewCodexOAuth", isDirectory: true)
    }

    private static func snapshotURL(for accountId: UUID) -> URL {
        snapshotsRootURL().appendingPathComponent(accountId.uuidString, isDirectory: true)
    }

    /// Written on capture so restore can reject snapshots saved for the wrong OpenAI user.
    private static let accountIdSidecarName = ".usageview-chatgpt-account-id"

    private static func accountIdSidecarURL(for accountId: UUID) -> URL {
        snapshotURL(for: accountId).appendingPathComponent(accountIdSidecarName)
    }

    private func writeAccountIdSidecar(_ chatgptAccountId: String, for accountId: UUID) {
        let url = Self.accountIdSidecarURL(for: accountId)
        try? chatgptAccountId.write(to: url, atomically: true, encoding: .utf8)
    }

    private func readAccountIdSidecar(for accountId: UUID) -> String? {
        let url = Self.accountIdSidecarURL(for: accountId)
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Security-scoped bookmark

    /// Returns a security-scoped URL for the Codex app support folder, prompting
    /// the user to grant access via NSOpenPanel if no stored bookmark exists.
    /// Returns nil if the user cancelled.
    @MainActor
    func resolveCodexFolderWithPermission() -> URL? {
        // Try stored bookmark first.
        if let data = UserDefaults.standard.data(forKey: bookmarkKey) {
            var isStale = false
            if let url = try? URL(resolvingBookmarkData: data,
                                  options: .withSecurityScope,
                                  relativeTo: nil,
                                  bookmarkDataIsStale: &isStale),
               !isStale {
                return url
            }
            // Stale — fall through and re-prompt.
            UserDefaults.standard.removeObject(forKey: bookmarkKey)
        }

        // Show NSOpenPanel so the user explicitly grants sandbox access.
        let panel = NSOpenPanel()
        panel.message = "Select the \"Codex\" folder inside ~/Library/Application Support/. Usageview needs access to save and restore your account sessions."
        panel.prompt = "Grant Access"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.showsHiddenFiles = true
        panel.directoryURL = Self.codexAppSupportURL()

        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        // Store bookmark for future access.
        if let bookmarkData = try? url.bookmarkData(options: .withSecurityScope,
                                                     includingResourceValuesForKeys: nil,
                                                     relativeTo: nil) {
            UserDefaults.standard.set(bookmarkData, forKey: bookmarkKey)
        }
        return url
    }

    // MARK: - Public API

    func hasSnapshot(for accountId: UUID) -> Bool {
        let snapshotDir = Self.snapshotURL(for: accountId)
        return FileManager.default.fileExists(atPath: snapshotDir.path)
    }

    /// Capture the current Codex session and associate it with `accountId`.
    /// Call this while Codex is running (or just closed) for the account you want to save.
    /// Capture the current Codex Desktop session for `accountId`.
    /// `grantedURL` is a security-scoped URL for the Codex app support folder (from NSOpenPanel).
    /// Throws `CodexOAuthError.captureFailed` with a human-readable reason on failure.
    func captureCurrentSession(for accountId: UUID, from grantedURL: URL, chatgptAccountId: String? = nil) throws {
        let fm = FileManager.default
        let dst = Self.snapshotURL(for: accountId)

        let accessing = grantedURL.startAccessingSecurityScopedResource()
        defer { if accessing { grantedURL.stopAccessingSecurityScopedResource() } }

        do {
            try fm.createDirectory(at: dst, withIntermediateDirectories: true)
        } catch {
            throw CodexOAuthError.captureFailed(reason: "Could not create snapshot folder: \(error.localizedDescription)")
        }

        var copiedCount = 0
        var firstError: String?
        for item in Self.sessionItems {
            let srcItem = grantedURL.appendingPathComponent(item)
            let dstItem = dst.appendingPathComponent(item)
            do {
                if fm.fileExists(atPath: dstItem.path) {
                    try fm.removeItem(at: dstItem)
                }
                try fm.copyItem(at: srcItem, to: dstItem)
                copiedCount += 1
                logger.info("CodexOAuth: captured \(item) for \(accountId)")
            } catch {
                let msg = "[\(item): \(error.localizedDescription)]"
                logger.warning("CodexOAuth: skipped \(msg, privacy: .public)")
                if firstError == nil { firstError = msg }
            }
        }

        if copiedCount == 0 {
            try? fm.removeItem(at: dst)
            let detail = firstError ?? "No session files found in \(grantedURL.path)"
            throw CodexOAuthError.captureFailed(
                reason: "No Codex session files could be saved. \(detail)\n\nMake sure you selected the Codex folder inside ~/Library/Application Support/."
            )
        }

        if let chatgptAccountId, !chatgptAccountId.isEmpty {
            writeAccountIdSidecar(chatgptAccountId, for: accountId)
        } else {
            try? FileManager.default.removeItem(at: Self.accountIdSidecarURL(for: accountId))
        }
    }

    /// Switch to the saved session for `accountId`.
    /// - Fails immediately if Codex is running (sandbox cannot terminate other apps).
    /// - Prompts for Codex folder access if no stored bookmark exists.
    /// - Restores saved session files.
    /// - Re-launches Codex.
    func activateSession(for accountId: UUID) async throws {
        guard hasSnapshot(for: accountId) else {
            throw CodexOAuthError.noSnapshot
        }

        // Sandbox restrictions prevent sending signals or Apple Events to Codex.
        // Fail fast with a clear user-facing message instead of a silent 5-second hang.
        let bundleIds = ["com.openai.chat", "com.openai.codex"]
        let running = bundleIds.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
        if !running.isEmpty {
            throw CodexOAuthError.codexRunning
        }

        guard let grantedURL = await resolveCodexFolderWithPermission() else {
            throw CodexOAuthError.captureFailed(reason: "Access to the Codex folder is required to switch accounts. Please select the Codex folder when prompted.")
        }

        try restoreSnapshot(for: accountId, to: grantedURL)
        reopenCodex()
        logger.info("CodexOAuth: session switched to \(accountId)")
    }

    func removeSnapshot(for accountId: UUID) {
        let dir = Self.snapshotURL(for: accountId)
        try? FileManager.default.removeItem(at: dir)
    }

    /// Removes every per-account Desktop snapshot (does not touch live Codex on disk).
    func removeAllSnapshots() {
        let root = Self.snapshotsRootURL()
        try? FileManager.default.removeItem(at: root)
    }

    func hasAnySnapshot() -> Bool {
        let root = Self.snapshotsRootURL()
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root.path) else {
            return false
        }
        return entries.contains { !$0.hasPrefix(".") }
    }

    /// Restores Local Storage / cookies / partitions when Usageview already has a per-account snapshot.
    /// `codexSupportScopedURL` must be the real `~/Library/Application Support/Codex` directory under an
    /// active security-scoped bookmark (typically the user’s home folder grant).
    /// When `expectedChatgptAccountId` is set, refuses to restore a snapshot tagged for a different user.
    func restoreSnapshotIfPresent(
        for accountId: UUID,
        codexSupportScopedURL: URL,
        expectedChatgptAccountId: String? = nil
    ) throws {
        guard hasSnapshot(for: accountId) else { return }
        if let expected = expectedChatgptAccountId, !expected.isEmpty {
            guard let saved = readAccountIdSidecar(for: accountId) else {
                throw CodexOAuthError.snapshotUntagged
            }
            if saved != expected {
                throw CodexOAuthError.snapshotAccountMismatch(savedAccountId: saved, expectedAccountId: expected)
            }
        }
        try restoreSnapshot(for: accountId, to: codexSupportScopedURL)
    }

    // MARK: - Private Helpers

    private func restoreSnapshot(for accountId: UUID, to grantedURL: URL) throws {
        let src = Self.snapshotURL(for: accountId)
        let fm = FileManager.default

        guard fm.fileExists(atPath: src.path) else {
            throw CodexOAuthError.noSnapshot
        }

        let accessing = grantedURL.startAccessingSecurityScopedResource()
        defer { if accessing { grantedURL.stopAccessingSecurityScopedResource() } }

        // Back up current session before overwriting.
        let backupDir = Self.snapshotsRootURL().appendingPathComponent("_pre_switch_backup", isDirectory: true)
        try? fm.removeItem(at: backupDir)
        try? fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
        for item in Self.sessionItems {
            let currentItem = grantedURL.appendingPathComponent(item)
            if fm.fileExists(atPath: currentItem.path) {
                try? fm.copyItem(at: currentItem, to: backupDir.appendingPathComponent(item))
            }
        }

        // Restore snapshot files.
        for item in Self.sessionItems {
            let srcItem = src.appendingPathComponent(item)
            guard fm.fileExists(atPath: srcItem.path) else { continue }
            let dstItem = grantedURL.appendingPathComponent(item)
            do {
                if fm.fileExists(atPath: dstItem.path) {
                    try fm.removeItem(at: dstItem)
                }
                try fm.copyItem(at: srcItem, to: dstItem)
                logger.info("CodexOAuth: restored \(item)")
            } catch {
                logger.error("CodexOAuth: failed to restore \(item): \(error.localizedDescription, privacy: .public)")
                throw CodexOAuthError.restoreFailed(item: item, reason: error.localizedDescription)
            }
        }
    }

    private func reopenCodex() {
        let workspace = NSWorkspace.shared
        let config = NSWorkspace.OpenConfiguration()
        let bundleIds = ["com.openai.codex", "com.openai.chat"]
        for bundleId in bundleIds {
            if let url = workspace.urlForApplication(withBundleIdentifier: bundleId) {
                workspace.openApplication(at: url, configuration: config, completionHandler: nil)
                return
            }
        }
        let fallback = URL(fileURLWithPath: "/Applications/Codex.app")
        if FileManager.default.fileExists(atPath: fallback.path) {
            workspace.openApplication(at: fallback, configuration: config, completionHandler: nil)
        }
    }
}

enum CodexOAuthError: LocalizedError {
    case noSnapshot
    case codexRunning
    case captureFailed(reason: String)
    case restoreFailed(item: String, reason: String)
    case snapshotAccountMismatch(savedAccountId: String, expectedAccountId: String)
    case snapshotUntagged

    var errorDescription: String? {
        switch self {
        case .noSnapshot:
            return "No saved Codex session for this account. Open Codex logged in as this account first, then save the session from the account menu."
        case .codexRunning:
            return "Codex is still open. Please quit Codex (⌘Q) first, then tap \"Switch to This in Codex\" again."
        case .captureFailed(let reason):
            return reason
        case .restoreFailed(let item, let reason):
            return "Failed to restore Codex session file \"\(item)\": \(reason)"
        case .snapshotAccountMismatch:
            return """
            The saved Codex Desktop session belongs to a different OpenAI account than this Usageview row.

            Use ⋯ → Clear saved Codex Desktop session on this account (and on your other accounts if you mixed them up). Then, for each account: sign into that user in Codex, quit Codex (⌘Q), and Save Codex Desktop session on the matching row.
            """
        case .snapshotUntagged:
            return """
            This Codex Desktop snapshot was saved while Codex was open or before account tagging, so it may be the wrong user.

            Use ⋯ → Clear saved Codex Desktop session, then sign into the correct user in Codex, quit Codex (⌘Q), and Save Codex Desktop session on this row.
            """
        }
    }
}
