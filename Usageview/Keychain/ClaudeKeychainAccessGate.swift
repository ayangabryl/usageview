import Foundation
import os.lock

/// Cooldown after Keychain denial — stops prompt storms (CodexBar `ClaudeOAuthKeychainAccessGate`).
enum ClaudeKeychainAccessGate {
    private struct State {
        var loaded = false
        var deniedUntil: Date?
    }

    private static let lock = OSAllocatedUnfairLock(initialState: State())
    private static let defaultsKey = "claudeOAuthKeychainDeniedUntil"
    private static let cooldownInterval: TimeInterval = 60 * 60 * 6

    static func shouldAllowPrompt(now: Date = Date()) -> Bool {
        guard !KeychainAccessGate.isDisabled else { return false }
        return lock.withLock { state in
            loadIfNeeded(&state)
            if let deniedUntil = state.deniedUntil {
                if deniedUntil > now { return false }
                state.deniedUntil = nil
                persist(state)
            }
            return true
        }
    }

    static func recordDenied(now: Date = Date()) {
        let deniedUntil = now.addingTimeInterval(cooldownInterval)
        lock.withLock { state in
            loadIfNeeded(&state)
            state.deniedUntil = deniedUntil
            persist(state)
        }
    }

    @discardableResult
    static func clearDenied(now: Date = Date()) -> Bool {
        lock.withLock { state in
            loadIfNeeded(&state)
            guard let deniedUntil = state.deniedUntil, deniedUntil > now else {
                state.deniedUntil = nil
                persist(state)
                return false
            }
            state.deniedUntil = nil
            persist(state)
            return true
        }
    }

    private static func loadIfNeeded(_ state: inout State) {
        guard !state.loaded else { return }
        state.loaded = true
        let ts = UserDefaults.standard.double(forKey: defaultsKey)
        if ts > 0 {
            state.deniedUntil = Date(timeIntervalSince1970: ts)
        }
    }

    private static func persist(_ state: State) {
        if let deniedUntil = state.deniedUntil {
            UserDefaults.standard.set(deniedUntil.timeIntervalSince1970, forKey: defaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        }
    }
}
