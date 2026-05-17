#if os(macOS)
import SweetCookieKit

typealias BrowserCookieImportOrder = [Browser]

extension [Browser] {
    func cookieImportCandidates(allowKeychainPrompt: Bool = false) -> [Browser] {
        self.filter { browser in
            if KeychainAccessGate.isDisabled, browser.usesKeychainForCookieDecryption {
                return false
            }
            return BrowserCookieAccessGate.shouldAttempt(browser, allowKeychainPrompt: allowKeychainPrompt)
        }
    }

    /// Safari first for user-initiated import (no Chromium Keychain prompt).
    static func userActionImportOrder() -> [Browser] {
        var order = Browser.defaultImportOrder
        if let index = order.firstIndex(of: .safari) {
            let safari = order.remove(at: index)
            order.insert(safari, at: 0)
        }
        return order
    }
}

extension Browser {
    var usesKeychainForCookieDecryption: Bool {
        switch self {
        case .safari, .firefox, .zen:
            return false
        case .chrome, .chromeBeta, .chromeCanary,
             .arc, .arcBeta, .arcCanary,
             .chatgptAtlas,
             .chromium,
             .brave, .braveBeta, .braveNightly,
             .edge, .edgeBeta, .edgeCanary,
             .helium,
             .vivaldi,
             .dia,
             .yandex,
             .comet:
            return true
        @unknown default:
            return true
        }
    }
}
#endif
