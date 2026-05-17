import Foundation

/// Global switch to disable all Keychain reads/writes (CodexBar-compatible behavior).
enum KeychainAccessGate {
    private static let flagKey = "debugDisableKeychainAccess"

    static var isDisabled: Bool {
        UserDefaults.standard.bool(forKey: flagKey)
    }

    static func setDisabled(_ disabled: Bool) {
        UserDefaults.standard.set(disabled, forKey: flagKey)
    }
}
