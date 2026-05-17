import AppKit
import Foundation
#if os(macOS)
import SweetCookieKit
#endif

struct KeychainPromptContext: Sendable {
    enum Kind: Sendable {
        case claudeCLI
        case geminiCLI
    }

    let kind: Kind
}

/// In-app heads-up before macOS may show a Keychain dialog (CodexBar `KeychainPromptCoordinator`).
enum KeychainPromptCoordinator {
    private static let lock = NSLock()

    static func install() {
        KeychainPromptHandler.handler = { context in
            presentPrompt(context)
        }
        #if os(macOS)
        BrowserCookieKeychainPromptHandler.handler = { context in
            presentBrowserCookiePrompt(context)
        }
        #endif
    }

    static func notify(_ context: KeychainPromptContext) {
        KeychainPromptHandler.handler?(context)
    }

    private static func presentPrompt(_ context: KeychainPromptContext) {
        lock.lock()
        defer { lock.unlock() }

        let (title, message) = copy(for: context)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertSecondButtonReturn {
            ClaudeKeychainAccessGate.recordDenied()
        }
    }

    #if os(macOS)
    private static func presentBrowserCookiePrompt(_ context: BrowserCookieKeychainPromptContext) {
        lock.lock()
        defer { lock.unlock() }

        let title = "Keychain Access"
        let message = [
            "Usageview will ask macOS Keychain for “\(context.label)” so it can read browser cookies",
            "for Cursor or Kimi. When prompted, enter your Mac password and choose Always Allow.",
        ].joined(separator: "\n")
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        _ = alert.runModal()
    }
    #endif

    private static func copy(for context: KeychainPromptContext) -> (String, String) {
        let title = "Keychain Access"
        switch context.kind {
        case .claudeCLI:
            return (title, [
                "Usageview will ask macOS Keychain for your Claude Code login so it can show usage.",
                "",
                "When prompted, enter your Mac password and choose Always Allow.",
            ].joined(separator: "\n"))
        case .geminiCLI:
            return (title, [
                "Usageview will ask macOS Keychain for your Gemini CLI login so it can show usage.",
                "",
                "When prompted, enter your Mac password and choose Always Allow.",
            ].joined(separator: "\n"))
        }
    }
}

enum KeychainPromptHandler {
    nonisolated(unsafe) static var handler: ((KeychainPromptContext) -> Void)?
}
