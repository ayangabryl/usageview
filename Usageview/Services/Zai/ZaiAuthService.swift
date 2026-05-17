import Foundation

struct ZaiAccountInfo: Sendable {
    var name: String?
}

@Observable
@MainActor
final class ZaiAuthService: Sendable {

    func isAuthenticated(for accountId: UUID) -> Bool {
        loadToken(key: apiKey(for: accountId)) != nil
    }

    func saveAPIKey(_ key: String, for accountId: UUID, region: ZaiAPIRegion) -> ZaiAccountInfo {
        saveToken(key: apiKey(for: accountId), value: key)
        saveRegion(region, for: accountId)
        let masked = key.count > 8 ? String(key.prefix(8)) + "…" : key
        return ZaiAccountInfo(name: "\(region.displayName) · \(masked)")
    }

    func getAPIKey(for accountId: UUID) -> String? {
        loadToken(key: apiKey(for: accountId))
    }

    func region(for accountId: UUID) -> ZaiAPIRegion {
        guard let raw = loadToken(key: regionKey(for: accountId)),
              let region = ZaiAPIRegion(rawValue: raw)
        else { return .global }
        return region
    }

    func disconnect(accountId: UUID) {
        removeToken(key: apiKey(for: accountId))
        removeToken(key: regionKey(for: accountId))
    }

    private func apiKey(for id: UUID) -> String {
        "com.ayangabryl.usage.zai-apikey-\(id.uuidString)"
    }

    private func regionKey(for id: UUID) -> String {
        "com.ayangabryl.usage.zai-region-\(id.uuidString)"
    }

    private func saveRegion(_ region: ZaiAPIRegion, for accountId: UUID) {
        saveToken(key: regionKey(for: accountId), value: region.rawValue)
    }

    private func saveToken(key: String, value: String) { KeychainHelper.save(value, forKey: key) }
    private func loadToken(key: String) -> String? { KeychainHelper.load(forKey: key) }
    private func removeToken(key: String) { KeychainHelper.remove(forKey: key) }
}
