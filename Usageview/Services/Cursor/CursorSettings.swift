import Foundation

/// App-wide Cursor provider preferences (CodexBar settings.cursor pattern).
enum CursorSettings {
    enum CookieSource: String, CaseIterable, Identifiable {
        case auto
        case manual
        case off

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .auto: "Automatic (browser + cache)"
            case .manual: "Manual cookie header"
            case .off: "Off"
            }
        }
    }

    private static let sourceKey = "cursorCookieSource"
    private static let manualHeaderKey = "cursorManualCookieHeader"

    static var cookieSource: CookieSource {
        get {
            guard let raw = UserDefaults.standard.string(forKey: sourceKey),
                  let value = CookieSource(rawValue: raw)
            else { return .auto }
            return value
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: sourceKey) }
    }

    static var manualCookieHeader: String? {
        get {
            let raw = UserDefaults.standard.string(forKey: manualHeaderKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let raw, !raw.isEmpty else { return nil }
            return CookieHeaderNormalizer.normalize(raw)
        }
        set {
            if let newValue, let normalized = CookieHeaderNormalizer.normalize(newValue), !normalized.isEmpty {
                UserDefaults.standard.set(normalized, forKey: manualHeaderKey)
            } else {
                UserDefaults.standard.removeObject(forKey: manualHeaderKey)
            }
        }
    }

    static var isEnabled: Bool { cookieSource != .off }
}
