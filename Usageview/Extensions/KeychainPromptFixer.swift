import AppKit
import Foundation

/// Plain-language helpers for keychain annoyance — no Keychain Access expertise required.
enum KeychainPromptFixer {

    /// Turns off CLI keychain reads so background refreshes never trigger macOS password dialogs.
    static func stopPasswordPopups(
        claudeAuth: AnthropicAuthService,
        geminiOAuth: GeminiOAuthService
    ) {
        UserDefaults.standard.set(false, forKey: "allowClaudeCLIKeychainAccess")
        UserDefaults.standard.set(false, forKey: "allowGeminiCLIKeychainAccess")
        UserDefaults.standard.set(
            ClaudeKeychainPromptMode.never.rawValue,
            forKey: "claudeOAuthKeychainPromptMode"
        )
        claudeAuth.resetCLIKeychainReadSuppression()
        geminiOAuth.resetCLIKeychainReadSuppression()
        GeminiCLICredentialStore.resetSession()
    }

    /// Prepares for a single macOS keychain dialog (user must click Always Allow when asked).
    static func prepareClaudeCodeOneTimeAccess(claudeAuth: AnthropicAuthService) {
        UserDefaults.standard.set(true, forKey: "allowClaudeCLIKeychainAccess")
        UserDefaults.standard.set(
            ClaudeKeychainPromptMode.onlyOnUserAction.rawValue,
            forKey: "claudeOAuthKeychainPromptMode"
        )
        ClaudeKeychainReadStrategyPreference.set(.securityCLIExperimental)
        claudeAuth.resetCLIKeychainReadSuppression()
    }

    static func showStopPopupsConfirmation() {
        presentAlert(
            title: "Password popups turned off",
            message: [
                "Usageview will no longer read Claude Code or Gemini CLI credentials from Keychain.",
                "",
                "Your accounts still work if you signed in inside Usageview, or if Claude Code stores credentials in a file.",
                "",
                "To show Claude usage from Claude Code only, use “Connect Claude Code once” in Settings → General.",
            ].joined(separator: "\n")
        )
    }

    static func showClaudeCodeSetupInstructions() {
        presentAlert(
            title: "When macOS asks for your password",
            message: [
                "1. Enter your Mac login password.",
                "2. Click Always Allow (not Deny).",
                "",
                "That grants Usageview permanent access so you are not asked every few minutes.",
                "",
                "If you already clicked Deny, open Keychain Access, search “Claude Code-credentials”,",
                "open the item → Access Control → add Usageview under “Always allow access”.",
            ].joined(separator: "\n")
        )
    }

    static func showClaudeCodeConnectResult(success: Bool) {
        if success {
            presentAlert(
                title: "Claude Code connected",
                message: "Usageview can read your Claude Code login. Password popups should stop if you chose Always Allow."
            )
        } else {
            presentAlert(
                title: "Could not connect",
                message: [
                    "Make sure Claude Code is installed and you are signed in.",
                    "",
                    "Or use “Stop password popups” and sign in to Claude from the Usageview menu bar instead.",
                ].joined(separator: "\n")
            )
        }
    }

    static func openKeychainAccessApp() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Keychain Access.app"))
    }

    /// Re-saves GitHub/Cursor/etc. tokens so macOS stops asking on every launch.
    /// User may see one dialog per saved account — choose **Always Allow** each time.
    @MainActor
    static func repairSavedAccountTokens() -> (fixed: Int, total: Int) {
        let keys = KeychainHelper.listUsageviewAccounts()
        guard !keys.isEmpty else { return (0, 0) }

        presentAlert(
            title: "One-time fix for saved accounts",
            message: [
                "Usageview will unlock each saved sign-in token (\(keys.count) total).",
                "",
                "When macOS asks, enter your Mac password and click **Always Allow**.",
                "",
                "After this, launch and refresh should not spam password dialogs.",
            ].joined(separator: "\n")
        )

        var fixed = 0
        for key in keys {
            if KeychainHelper.repairSavedToken(forKey: key) {
                fixed += 1
            }
        }
        KeychainHelper.warmSessionCache()
        return (fixed, keys.count)
    }

    static func showSavedAccountRepairResult(fixed: Int, total: Int) {
        if total == 0 {
            presentAlert(
                title: "Nothing to repair",
                message: "No saved Usageview tokens were found in Keychain."
            )
            return
        }
        if fixed == total {
            presentAlert(
                title: "Saved accounts repaired",
                message: "All \(fixed) token(s) were updated. Restart Usageview — password popups should stop."
            )
        } else {
            presentAlert(
                title: "Partially repaired",
                message: [
                    "Updated \(fixed) of \(total) saved token(s).",
                    "",
                    "For any account that still prompts, open Keychain Access, search “com.ayangabryl.usage”,",
                    "open the item → Access Control → allow Usageview.",
                ].joined(separator: "\n")
            )
        }
    }

    private static func presentAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
