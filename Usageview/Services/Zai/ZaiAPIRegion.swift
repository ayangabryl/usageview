import Foundation

enum ZaiAPIRegion: String, CaseIterable, Codable, Sendable {
    case global
    case bigmodelCN = "bigmodel-cn"

    var displayName: String {
        switch self {
        case .global: "Global (api.z.ai)"
        case .bigmodelCN: "BigModel CN (open.bigmodel.cn)"
        }
    }

    var quotaURL: URL {
        switch self {
        case .global:
            URL(string: "https://api.z.ai/api/monitor/usage/quota/limit")!
        case .bigmodelCN:
            URL(string: "https://open.bigmodel.cn/api/monitor/usage/quota/limit")!
        }
    }
}
