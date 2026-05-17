#if os(macOS)
import Foundation
import os.lock
import SweetCookieKit

/// Suppresses repeated Chromium “Safe Storage” Keychain prompts after denial or preflight failure.
enum BrowserCookieAccessGate {
    private struct State {
        var loaded = false
        var deniedUntilByBrowser: [String: Date] = [:]
    }

    private static let lock = OSAllocatedUnfairLock<State>(initialState: State())
    private static let defaultsKey = "browserCookieAccessDeniedUntil"
    private static let cooldownInterval: TimeInterval = 60 * 60 * 6

    /// - Parameter allowKeychainPrompt: When true (user tapped Import), still try Chromium browsers so macOS can show the one-time Safe Storage prompt.
    static func shouldAttempt(_ browser: Browser, allowKeychainPrompt: Bool = false, now: Date = Date()) -> Bool {
        guard browser.usesKeychainForCookieDecryption else { return true }
        guard !KeychainAccessGate.isDisabled else { return false }

        let shouldCheckKeychain = lock.withLock { state in
            loadIfNeeded(&state)
            if let blockedUntil = state.deniedUntilByBrowser[browser.rawValue], blockedUntil > now {
                return false
            }
            if let blockedUntil = state.deniedUntilByBrowser[browser.rawValue] {
                state.deniedUntilByBrowser.removeValue(forKey: browser.rawValue)
                persist(state)
            }
            return true
        }
        guard shouldCheckKeychain else { return false }
        if allowKeychainPrompt { return true }

        let requiresInteraction = chromiumKeychainRequiresInteraction()
        return lock.withLock { state in
            loadIfNeeded(&state)
            if requiresInteraction {
                state.deniedUntilByBrowser[browser.rawValue] = now.addingTimeInterval(cooldownInterval)
                persist(state)
                return false
            }
            return true
        }
    }

    static func recordIfNeeded(_ error: Error, now: Date = Date()) {
        guard let error = error as? BrowserCookieError else { return }
        guard case .accessDenied = error else { return }
        recordDenied(for: error.browser, now: now)
    }

    static func recordDenied(for browser: Browser, now: Date = Date()) {
        guard browser.usesKeychainForCookieDecryption else { return }
        let blockedUntil = now.addingTimeInterval(cooldownInterval)
        lock.withLock { state in
            loadIfNeeded(&state)
            state.deniedUntilByBrowser[browser.rawValue] = blockedUntil
            persist(state)
        }
    }

    private static func chromiumKeychainRequiresInteraction() -> Bool {
        for label in Browser.safeStorageLabels {
            switch KeychainAccessPreflight.checkGenericPassword(service: label.service, account: label.account) {
            case .allowed:
                return false
            case .interactionRequired:
                return true
            case .notFound, .failure:
                continue
            }
        }
        return false
    }

    private static func loadIfNeeded(_ state: inout State) {
        guard !state.loaded else { return }
        state.loaded = true
        guard let raw = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Double] else {
            return
        }
        state.deniedUntilByBrowser = raw.compactMapValues { Date(timeIntervalSince1970: $0) }
    }

    private static func persist(_ state: State) {
        let raw = state.deniedUntilByBrowser.mapValues { $0.timeIntervalSince1970 }
        UserDefaults.standard.set(raw, forKey: defaultsKey)
    }
}

extension BrowserCookieClient {
    func gatedRecords(
        matching query: BrowserCookieQuery,
        in browser: Browser,
        allowKeychainPrompt: Bool = false,
        logger: ((String) -> Void)? = nil
    ) throws -> [BrowserCookieStoreRecords] {
        guard BrowserCookieAccessGate.shouldAttempt(browser, allowKeychainPrompt: allowKeychainPrompt) else {
            return []
        }
        return try records(matching: query, in: browser, logger: logger)
    }
}
#endif
