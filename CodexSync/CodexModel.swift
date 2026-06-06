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
    let authJson: String? // 官方网页登录的 auth.json 原始 JSON 字符串
    /// 自动探测到的余额查询供应商（nil = 未探测或探测失败）
    var detectedBalanceProvider: String?
}

/// 当前 Codex 本地状态信息
struct CodexState {
    var currentProvider: String = ""
    var currentModel: String = ""
    var isOfficial: Bool = true
    var totalThreads: Int = 0
    var movableThreads: Int = 0
    var sessionFileCount: Int = 0
    
    // 新增字段用于预设的动态导入与更新校验
    var currentAccountId: String? = nil
    var currentIdToken: String? = nil
    var currentAccessToken: String? = nil
    var currentRefreshToken: String? = nil
    var currentLastRefresh: String? = nil
    var currentApiKey: String? = nil
    var currentBaseUrl: String? = nil
    var currentCustomProviderName: String = ""
    
    var pendingSyncCount: Int {
        return movableThreads
    }
}
