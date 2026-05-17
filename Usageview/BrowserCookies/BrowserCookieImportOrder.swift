#if os(macOS)
import SweetCookieKit

typealias BrowserCookieImportOrder = [Browser]

extension BrowserCookieImportOrder {
    /// Safari first, then SweetCookieKit default order (CodexBar `cursorCookieImportOrder`).
    static var cursorCookieImportOrder: BrowserCookieImportOrder {
        [.safari] + Browser.defaultImportOrder.filter { $0 != .safari }
    }

    func cookieImportCandidates(allowKeychainPrompt: Bool = false) -> [Browser] {
        let detection = BrowserDetection.shared
        return filter { browser in
            if KeychainAccessGate.isDisabled, browser.usesKeychainForCookieDecryption {
                return false
            }
            guard detection.isCookieSourceAvailable(browser) else { return false }
            return BrowserCookieAccessGate.shouldAttempt(browser, allowKeychainPrompt: allowKeychainPrompt)
        }
    }

    /// Safari first for user-initiated import (avoids Chromium Keychain prompt when possible).
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
