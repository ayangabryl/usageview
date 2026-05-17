import Foundation
import LocalAuthentication
import Security

/// Applies non-interactive keychain query options so reads fail fast instead of showing macOS prompts.
///
/// Mirrors CodexBar's approach: `LAContext.interactionNotAllowed` plus `kSecUseAuthenticationUIFail`.
enum KeychainNoUIQuery {
    private static let uiFailPolicy = resolveUIFailPolicy()

    static func apply(to query: inout [String: Any]) {
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        query[kSecUseAuthenticationUI as String] = uiFailPolicy as CFString
    }

    private static func resolveUIFailPolicy() -> String {
        let securityPath = "/System/Library/Frameworks/Security.framework/Security"
        guard let handle = dlopen(securityPath, RTLD_NOW) else {
            return "u_AuthUIF"
        }
        defer { dlclose(handle) }

        guard let symbol = dlsym(handle, "kSecUseAuthenticationUIFail") else {
            return "u_AuthUIF"
        }
        let valuePointer = symbol.assumingMemoryBound(to: CFString?.self)
        return (valuePointer.pointee as String?) ?? "u_AuthUIF"
    }
}
