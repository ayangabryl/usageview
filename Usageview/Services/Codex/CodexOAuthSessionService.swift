import Foundation
import AppKit
import os

private let logger = Logger(subsystem: "com.ayangabryl.usage", category: "CodexOAuth")
private let bookmarkKey = "CodexOAuthFolderBookmark"

/// Saves and restores Codex Desktop OAuth sessions per account.
/// Codex Desktop is an Electron app — its session lives in:
///   ~/Library/Application Support/Codex/{Cookies, Local Storage/leveldb/, Session Storage/}
/// We snapshot those files into Usageview's container per account,
/// then restore on demand (after quitting Codex first).
@Observable
@MainActor
final class CodexOAuthSessionService: Sendable {

    // MARK: - Session Files

    /// Files/directories inside the Codex app support folder that hold OAuth state.
    private static let sessionItems = [
        "Cookies",
        "Cookies-journal",
        "Local Storage",
        "Session Storage",
        "DIPS",
        "Preferences",
        "Local State",
        "Network Persistent State",
    ]

    // MARK: - Paths

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
        panel.message = "Usageview needs access to the Codex session folder to save and restore your account sessions."
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
    func captureCurrentSession(for accountId: UUID, from grantedURL: URL) throws {
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
    }

    /// Switch to the saved session for `accountId`.
    /// - Prompts for Codex folder access if no stored bookmark.
    /// - Quits Codex Desktop (gracefully, then force after timeout).
    /// - Restores saved session files.
    /// - Re-launches Codex.
    func activateSession(for accountId: UUID) async throws {
        guard hasSnapshot(for: accountId) else {
            throw CodexOAuthError.noSnapshot
        }

        guard let grantedURL = await resolveCodexFolderWithPermission() else {
            throw CodexOAuthError.captureFailed(reason: "Access to the Codex folder is required to switch accounts. Please select the Codex folder when prompted.")
        }

        try await terminateCodex()
        try restoreSnapshot(for: accountId, to: grantedURL)
        reopenCodex()
        logger.info("CodexOAuth: session switched to \(accountId)")
    }

    func removeSnapshot(for accountId: UUID) {
        let dir = Self.snapshotURL(for: accountId)
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Private Helpers

    private func terminateCodex() async throws {
        let bundleIds = ["com.openai.chat", "com.openai.codex"]
        var terminated = false
        for bundleId in bundleIds {
            let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
            for app in apps {
                app.terminate()
                terminated = true
            }
        }
        guard terminated else { return }

        // Wait up to 4 seconds for clean termination.
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(100))
            let still = bundleIds.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
            if still.isEmpty { return }
        }

        // Force-kill if still running.
        for bundleId in bundleIds {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleId) {
                app.forceTerminate()
            }
        }
        try? await Task.sleep(for: .milliseconds(500))
    }

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
        let bundleIds = ["com.openai.chat", "com.openai.codex"]
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
    case captureFailed(reason: String)
    case restoreFailed(item: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .noSnapshot:
            return "No saved Codex session for this account. Open Codex logged in as this account first, then save the session from the account menu."
        case .captureFailed(let reason):
            return reason
        case .restoreFailed(let item, let reason):
            return "Failed to restore Codex session file \"\(item)\": \(reason)"
        }
    }
}
