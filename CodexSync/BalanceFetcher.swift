import Foundation

// MARK: - 余额查询供应商枚举

enum BalanceProviderType: String, Codable {
    case deepseek
    case stepfun
    case siliconflowCN = "siliconflow_cn"
    case siliconflowEN = "siliconflow_en"
    case openrouter
    case novita
    case sub2api   // GET /v1/usage
    case newapi    // GET /api/user/self
    case unknown   // 探测失败
}

// MARK: - 余额结果

struct BalanceResult {
    let remaining: Double?
    let used: Double?
    let total: Double?
    let unit: String
    let planName: String?
    let isValid: Bool
    let invalidMessage: String?

    /// 格式化为侧边栏显示字符串（含"余额："前缀）
    var displayString: String {
        guard let r = remaining else { return "余额获取失败" }
        let fmt = r.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", r)
            : String(format: "%.2f", r)
        let suffix = isValid ? "" : "（已失效）"
        return "余额：\(fmt) \(unit)\(suffix)"
    }
}

// MARK: - 域名识别

private func detectProviderByDomain(_ baseUrl: String) -> BalanceProviderType? {
    let url = baseUrl.lowercased()
    if url.contains("api.deepseek.com")                          { return .deepseek }
    if url.contains("api.stepfun.ai") || url.contains("api.stepfun.com") { return .stepfun }
    if url.contains("api.siliconflow.cn")                        { return .siliconflowCN }
    if url.contains("api.siliconflow.com")                       { return .siliconflowEN }
    if url.contains("openrouter.ai")                             { return .openrouter }
    if url.contains("api.novita.ai")                             { return .novita }
    return nil
}

// MARK: - 各供应商查询

private func queryDeepSeek(apiKey: String) async -> BalanceResult? {
    guard let url = URL(string: "https://api.deepseek.com/user/balance") else { return nil }
    var req = URLRequest(url: url, timeoutInterval: 10)
    req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    req.setValue("application/json", forHTTPHeaderField: "Accept")
    guard let (data, _) = try? await URLSession.shared.data(for: req),
          let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let infos = dict["balance_infos"] as? [[String: Any]],
          let first = infos.first else { return nil }
    let isAvailable = dict["is_available"] as? Bool ?? true
    let currency = first["currency"] as? String ?? "CNY"
    let total = parseDouble(first["total_balance"]) ?? 0
    return BalanceResult(remaining: total, used: nil, total: nil,
                         unit: currency, planName: currency,
                         isValid: isAvailable, invalidMessage: isAvailable ? nil : "Insufficient balance")
}

private func queryStepFun(apiKey: String) async -> BalanceResult? {
    guard let url = URL(string: "https://api.stepfun.com/v1/accounts") else { return nil }
    var req = URLRequest(url: url, timeoutInterval: 10)
    req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    req.setValue("application/json", forHTTPHeaderField: "Accept")
    guard let (data, _) = try? await URLSession.shared.data(for: req),
          let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    let balance = parseDouble(dict["balance"]) ?? 0
    return BalanceResult(remaining: balance, used: nil, total: nil,
                         unit: "CNY", planName: "StepFun", isValid: true, invalidMessage: nil)
}

private func querySiliconFlow(apiKey: String, isCN: Bool) async -> BalanceResult? {
    let domain = isCN ? "api.siliconflow.cn" : "api.siliconflow.com"
    guard let url = URL(string: "https://\(domain)/v1/user/info") else { return nil }
    var req = URLRequest(url: url, timeoutInterval: 10)
    req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    req.setValue("application/json", forHTTPHeaderField: "Accept")
    guard let (data, _) = try? await URLSession.shared.data(for: req),
          let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let dataObj = dict["data"] as? [String: Any] else { return nil }
    let total = parseDouble(dataObj["totalBalance"]) ?? 0
    let unit = isCN ? "CNY" : "USD"
    let name = isCN ? "SiliconFlow" : "SiliconFlow (EN)"
    return BalanceResult(remaining: total, used: nil, total: nil,
                         unit: unit, planName: name, isValid: true, invalidMessage: nil)
}

private func queryOpenRouter(apiKey: String) async -> BalanceResult? {
    guard let url = URL(string: "https://openrouter.ai/api/v1/credits") else { return nil }
    var req = URLRequest(url: url, timeoutInterval: 10)
    req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    req.setValue("application/json", forHTTPHeaderField: "Accept")
    guard let (data, _) = try? await URLSession.shared.data(for: req),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    let dataObj = json["data"] as? [String: Any] ?? json
    let credits = parseDouble(dataObj["total_credits"]) ?? 0
    let usage   = parseDouble(dataObj["total_usage"])   ?? 0
    let remaining = credits - usage
    return BalanceResult(remaining: remaining, used: usage, total: credits,
                         unit: "USD", planName: "OpenRouter",
                         isValid: remaining > 0,
                         invalidMessage: remaining <= 0 ? "No credits remaining" : nil)
}

private func queryNovita(apiKey: String) async -> BalanceResult? {
    guard let url = URL(string: "https://api.novita.ai/v3/user/balance") else { return nil }
    var req = URLRequest(url: url, timeoutInterval: 10)
    req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    req.setValue("application/json", forHTTPHeaderField: "Accept")
    guard let (data, _) = try? await URLSession.shared.data(for: req),
          let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    // Novita 单位为 0.0001 USD
    let available = (parseDouble(dict["availableBalance"]) ?? 0) / 10000.0
    return BalanceResult(remaining: available, used: nil, total: nil,
                         unit: "USD", planName: "Novita AI",
                         isValid: available > 0,
                         invalidMessage: available <= 0 ? "No balance remaining" : nil)
}

/// sub2api：GET {baseUrl}/v1/usage
private func querySub2Api(baseUrl: String, apiKey: String) async -> BalanceResult? {
    let normalized = baseUrl.hasSuffix("/") ? String(baseUrl.dropLast()) : baseUrl
    let urlStr = normalized.hasSuffix("/v1") ? normalized + "/usage" : normalized + "/v1/usage"
    guard let url = URL(string: urlStr) else { return nil }
    var req = URLRequest(url: url, timeoutInterval: 10)
    req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    req.setValue("application/json", forHTTPHeaderField: "Accept")
    guard let (data, resp) = try? await URLSession.shared.data(for: req),
          (resp as? HTTPURLResponse)?.statusCode == 200,
          let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

    let quotaDict = dict["quota"] as? [String: Any]
    let remaining: Double?
    if let v = parseDouble(dict["remaining"])           { remaining = v }
    else if let v = parseDouble(quotaDict?["remaining"]) { remaining = v }
    else if let v = parseDouble(dict["balance"])         { remaining = v }
    else { remaining = nil }

    guard remaining != nil else { return nil } // 探测时要求有有效值

    let unit: String
    if let u = dict["unit"] as? String, !u.isEmpty         { unit = u }
    else if let u = quotaDict?["unit"] as? String, !u.isEmpty { unit = u }
    else                                                    { unit = "USD" }

    let isValid: Bool
    if let v = dict["is_active"] as? Bool  { isValid = v }
    else if let v = dict["isValid"] as? Bool { isValid = v }
    else                                    { isValid = true }

    return BalanceResult(remaining: remaining, used: nil, total: nil,
                         unit: unit, planName: nil, isValid: isValid, invalidMessage: nil)
}

/// newapi：GET {baseUrl}/api/user/self
private func queryNewApi(baseUrl: String, apiKey: String) async -> BalanceResult? {
    let normalized = baseUrl.hasSuffix("/") ? String(baseUrl.dropLast()) : baseUrl
    // 去掉末尾的 /v1 路径，只保留 origin
    let origin: String
    if let range = normalized.range(of: "/v1", options: .backwards) {
        origin = String(normalized[normalized.startIndex..<range.lowerBound])
    } else {
        origin = normalized
    }
    guard let url = URL(string: origin + "/api/user/self") else { return nil }
    var req = URLRequest(url: url, timeoutInterval: 10)
    req.httpMethod = "GET"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    req.setValue("cc-switch/1.0", forHTTPHeaderField: "User-Agent")

    guard let (data, resp) = try? await URLSession.shared.data(for: req),
          (resp as? HTTPURLResponse)?.statusCode == 200,
          let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

    let success = dict["success"] as? Bool ?? false
    guard success, let dataObj = dict["data"] as? [String: Any] else {
        let msg = dict["message"] as? String ?? "查询失败"
        return BalanceResult(remaining: nil, used: nil, total: nil,
                             unit: "USD", planName: nil, isValid: false, invalidMessage: msg)
    }

    let quota     = parseDouble(dataObj["quota"])      ?? 0
    let usedQuota = parseDouble(dataObj["used_quota"]) ?? 0
    let remaining = quota / 500000.0
    let used      = usedQuota / 500000.0
    let total     = (quota + usedQuota) / 500000.0
    let planName  = dataObj["group"] as? String ?? "默认套餐"

    return BalanceResult(remaining: remaining, used: used, total: total,
                         unit: "USD", planName: planName, isValid: true, invalidMessage: nil)
}

// MARK: - 公开 API

/// 根据已探测的供应商类型获取余额（用于日常刷新）
func fetchBalance(provider: BalanceProviderType,
                  baseUrl: String,
                  apiKey: String) async -> BalanceResult? {
    switch provider {
    case .deepseek:      return await queryDeepSeek(apiKey: apiKey)
    case .stepfun:       return await queryStepFun(apiKey: apiKey)
    case .siliconflowCN: return await querySiliconFlow(apiKey: apiKey, isCN: true)
    case .siliconflowEN: return await querySiliconFlow(apiKey: apiKey, isCN: false)
    case .openrouter:    return await queryOpenRouter(apiKey: apiKey)
    case .novita:        return await queryNovita(apiKey: apiKey)
    case .sub2api:       return await querySub2Api(baseUrl: baseUrl, apiKey: apiKey)
    case .newapi:        return await queryNewApi(baseUrl: baseUrl, apiKey: apiKey)
    case .unknown:       return nil
    }
}

/// 自动探测供应商（首次添加或 URL 变化时调用）
/// 优先域名匹配 → sub2api → newapi → unknown
func detectBalanceProvider(baseUrl: String, apiKey: String) async -> BalanceProviderType {
    // 1. 域名精确匹配
    if let domainProvider = detectProviderByDomain(baseUrl) {
        return domainProvider
    }
    // 2. 尝试 sub2api
    if await querySub2Api(baseUrl: baseUrl, apiKey: apiKey) != nil {
        return .sub2api
    }
    // 3. 尝试 newapi
    if let result = await queryNewApi(baseUrl: baseUrl, apiKey: apiKey), result.isValid {
        return .newapi
    }
    return .unknown
}

// MARK: - 辅助

private func parseDouble(_ value: Any?) -> Double? {
    guard let v = value else { return nil }
    if let d = v as? Double { return d }
    if let i = v as? Int    { return Double(i) }
    if let s = v as? String { return Double(s) }
    return nil
}
