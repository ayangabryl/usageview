#if os(macOS)
import SweetCookieKit

typealias BrowserCookieImportOrder = [Browser]

extension [Browser] {
    func cookieImportCandidates() -> [Browser] {
        Browser.defaultImportOrder.filter { browser in
            if KeychainAccessGate.isDisabled, browser.usesKeychainForCookieDecryption {
                return false
            }
            return BrowserCookieAccessGate.shouldAttempt(browser)
        }
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
