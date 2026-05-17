#if os(macOS)
import Foundation

/// Persisted Cursor cookies from a prior login (CodexBar `cursor-session.json` fallback).
actor CursorSessionStore {
    static let shared = CursorSessionStore()

    private var sessionCookies: [HTTPCookie] = []
    private var hasLoadedFromDisk = false
    private let fileURL: URL

    private init() {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        let dir = appSupport.appendingPathComponent("Usageview", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("cursor-session.json")
    }

    func setCookies(_ cookies: [HTTPCookie]) {
        hasLoadedFromDisk = true
        sessionCookies = cookies
        saveToDisk()
    }

    func getCookies() -> [HTTPCookie] {
        loadFromDiskIfNeeded()
        return sessionCookies
    }

    func clearCookies() {
        hasLoadedFromDisk = true
        sessionCookies = []
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func loadFromDiskIfNeeded() {
        guard !hasLoadedFromDisk else { return }
        hasLoadedFromDisk = true
        loadFromDisk()
    }

    private func saveToDisk() {
        let cookieData = sessionCookies.compactMap { cookie -> [String: Any]? in
            guard let props = cookie.properties else { return nil }
            var serializable: [String: Any] = [:]
            for (key, value) in props {
                let keyString = key.rawValue
                if let date = value as? Date {
                    serializable[keyString] = date.timeIntervalSince1970
                    serializable[keyString + "_isDate"] = true
                } else if let url = value as? URL {
                    serializable[keyString] = url.absoluteString
                    serializable[keyString + "_isURL"] = true
                } else if value is String || value is Bool || value is NSNumber {
                    serializable[keyString] = value
                }
            }
            return serializable
        }
        guard !cookieData.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: cookieData, options: [.prettyPrinted])
        else { return }
        try? data.write(to: fileURL)
    }

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: fileURL),
              let cookieArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return }

        sessionCookies = cookieArray.compactMap { props in
            var cookieProps: [HTTPCookiePropertyKey: Any] = [:]
            for (key, value) in props {
                if key.hasSuffix("_isDate") || key.hasSuffix("_isURL") { continue }
                let propKey = HTTPCookiePropertyKey(key)
                if props[key + "_isDate"] as? Bool == true, let interval = value as? TimeInterval {
                    cookieProps[propKey] = Date(timeIntervalSince1970: interval)
                } else if props[key + "_isURL"] as? Bool == true, let urlString = value as? String {
                    cookieProps[propKey] = URL(string: urlString)
                } else {
                    cookieProps[propKey] = value
                }
            }
            return HTTPCookie(properties: cookieProps)
        }
    }
}
#endif
