#if os(macOS)
import Foundation
import os.lock
import SweetCookieKit

/// Skips browsers without on-disk cookie stores (CodexBar pattern — avoids useless Keychain prompts).
final class BrowserDetection: Sendable {
    static let shared = BrowserDetection()

    private let cache = OSAllocatedUnfairLock<[CacheKey: CachedResult]>(initialState: [:])
    private let homeDirectory: String
    private let cacheTTL: TimeInterval = 60 * 10

    private struct CachedResult {
        let value: Bool
        let timestamp: Date
    }

    private enum ProbeKind: Hashable {
        case usableCookieStore
    }

    private struct CacheKey: Hashable {
        let browser: Browser
        let kind: ProbeKind
    }

    init(homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path) {
        self.homeDirectory = homeDirectory
    }

    func isCookieSourceAvailable(_ browser: Browser) -> Bool {
        if browser == .safari { return true }
        if browser.usesKeychainForCookieDecryption {
            return hasUsableCookieStore(browser)
        }
        return hasUsableProfileData(browser)
    }

    func hasUsableProfileData(_ browser: Browser) -> Bool {
        guard let profilePath = profilePath(for: browser) else { return false }
        guard FileManager.default.fileExists(atPath: profilePath) else { return false }
        if requiresProfileValidation(browser) {
            return hasValidProfileDirectory(for: browser, at: profilePath)
        }
        return true
    }

    private func hasUsableCookieStore(_ browser: Browser) -> Bool {
        cachedBool(browser: browser) {
            guard let profilePath = profilePath(for: browser) else { return false }
            guard FileManager.default.fileExists(atPath: profilePath) else { return false }
            return hasValidCookieStore(for: browser, at: profilePath)
        }
    }

    private func cachedBool(browser: Browser, compute: () -> Bool) -> Bool {
        let now = Date()
        let key = CacheKey(browser: browser, kind: .usableCookieStore)
        if let cached = cache.withLock({ $0[key] }), now.timeIntervalSince(cached.timestamp) < cacheTTL {
            return cached.value
        }
        let result = compute()
        cache.withLock { $0[key] = CachedResult(value: result, timestamp: now) }
        return result
    }

    private func profilePath(for browser: Browser) -> String? {
        if browser == .safari {
            return "\(homeDirectory)/Library/Cookies/Cookies.binarycookies"
        }
        if let relativePath = browser.chromiumProfileRelativePath {
            return "\(homeDirectory)/Library/Application Support/\(relativePath)"
        }
        if let geckoFolder = browser.geckoProfilesFolder {
            return "\(homeDirectory)/Library/Application Support/\(geckoFolder)/Profiles"
        }
        return nil
    }

    private func requiresProfileValidation(_ browser: Browser) -> Bool {
        if browser == .safari || browser == .helium { return false }
        return browser.usesGeckoProfileStore || browser.usesChromiumProfileStore
    }

    private func hasValidProfileDirectory(for browser: Browser, at profilePath: String) -> Bool {
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: profilePath) else { return false }
        if browser.usesGeckoProfileStore {
            return contents.contains { $0.range(of: ".default", options: .caseInsensitive) != nil }
        }
        return contents.contains { $0 == "Default" || $0.hasPrefix("Profile ") || $0.hasPrefix("user-") }
    }

    private func hasValidCookieStore(for browser: Browser, at profilePath: String) -> Bool {
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: profilePath) else { return false }
        if browser.usesGeckoProfileStore {
            for name in contents where name.range(of: ".default", options: .caseInsensitive) != nil {
                if FileManager.default.fileExists(atPath: "\(profilePath)/\(name)/cookies.sqlite") {
                    return true
                }
            }
            return false
        }
        for name in contents where name == "Default" || name.hasPrefix("Profile ") || name.hasPrefix("user-") {
            let legacy = "\(profilePath)/\(name)/Cookies"
            let network = "\(profilePath)/\(name)/Network/Cookies"
            if FileManager.default.fileExists(atPath: legacy) || FileManager.default.fileExists(atPath: network) {
                return true
            }
        }
        return false
    }
}
#endif
