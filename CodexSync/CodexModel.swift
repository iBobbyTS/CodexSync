import Foundation

/// 预设服务商配置
struct ProviderPreset: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let isOfficial: Bool // 是否为官方网页登录模式
    let providerId: String // "openai" 或自定义 provider
    let model: String
    let baseUrl: String?
    let apiKey: String?
}

/// 当前 Codex 本地状态信息
struct CodexState {
    var currentProvider: String = ""
    var currentModel: String = ""
    var isOfficial: Bool = true
    var totalThreads: Int = 0
    var movableThreads: Int = 0
    var sessionFileCount: Int = 0
    
    var pendingSyncCount: Int {
        return movableThreads
    }
}
