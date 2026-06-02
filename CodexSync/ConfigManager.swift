import Foundation
import Combine
import SQLite3

/// 核心配置文件管理器（读取与修改 config.toml 与 auth.json）
class ConfigManager: ObservableObject {
    @Published var state = CodexState()
    @Published var presets: [ProviderPreset] = []
    @Published var accountQuotas: [String: String] = [:]
    
    private var detectionTasks: [String: Task<Void, Never>] = [:]
    
    // Codex 本地主路径
    let codexHome: URL
    let configURL: URL
    let authURL: URL
    let presetsURL: URL
    
    init(codexHome: URL? = nil, presetsURL: URL? = nil) {
        let actualCodexHome = codexHome ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        self.codexHome = actualCodexHome
        self.configURL = actualCodexHome.appendingPathComponent("config.toml")
        self.authURL = actualCodexHome.appendingPathComponent("auth.json")
        
        if let customPresetsURL = presetsURL {
            self.presetsURL = customPresetsURL
        } else {
            // 预设列表的持久化存储路径
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let appDir = appSupport.appendingPathComponent("CodexSync")
            try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true, attributes: nil)
            self.presetsURL = appDir.appendingPathComponent("presets.json")
        }
        
        loadPresets()
        refreshState()
    }
    
    /// 加载用户预设
    func loadPresets() {
        if FileManager.default.fileExists(atPath: presetsURL.path) {
            do {
                let data = try Data(contentsOf: presetsURL)
                self.presets = try JSONDecoder().decode([ProviderPreset].self, from: data)
            } catch {
                print("加载预设失败: \(error)")
                loadDefaultPresets()
            }
        } else {
            loadDefaultPresets()
        }
    }
    
    /// 加载默认预设
    private func loadDefaultPresets() {
        self.presets = [
            ProviderPreset(id: UUID().uuidString, name: "ChatGPT账号", isOfficial: true, providerId: "openai", model: "gpt-5.5", baseUrl: nil, apiKey: nil, authJson: nil),
            ProviderPreset(id: UUID().uuidString, name: "自定义 API 模式 (DeepSeek)", isOfficial: false, providerId: "deepseek", model: "deepseek-chat", baseUrl: "https://api.deepseek.com/v1", apiKey: "sk-your-key-here", authJson: nil)
        ]
        savePresets()
    }
    
    /// 保存预设列表
    func savePresets() {
        do {
            let data = try JSONEncoder().encode(presets)
            try data.write(to: presetsURL, options: .atomic)
        } catch {
            print("保存预设失败: \(error)")
        }
    }
    
    /// 刷新当前的本地 Codex 状态
    func refreshState() {
        var newState = CodexState()
        
        // 1. 检查是否存在主文件
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            newState.currentProvider = "未安装 / 配置文件不存在"
            self.state = newState
            return
        }
        
        // 2. 读取并解析 config.toml
        do {
            let tomlText = try String(contentsOf: configURL, encoding: .utf8)
            let editor = TomlEditor(text: tomlText)
            
            let provider = editor.getValue(forKey: "model_provider") ?? "openai"
            let model = editor.getValue(forKey: "model") ?? "(默认)"
            
            newState.currentProvider = provider
            newState.currentModel = model
            
            // 获取 model_providers.custom 的 name 字段
            newState.currentCustomProviderName = editor.getValue(forKey: "name", inSection: "model_providers.custom") ?? "自定义 API"
            
            // 3. 读取 auth.json 鉴别官方网页模式与鉴权信息
            if FileManager.default.fileExists(atPath: authURL.path) {
                let authData = try Data(contentsOf: authURL)
                if let authObj = try? JSONSerialization.jsonObject(with: authData, options: []) as? [String: Any] {
                    let authMode = authObj["auth_mode"] as? String
                    newState.isOfficial = (authMode == "chatgpt")
                    
                    // 读取 API Key
                    if let apiKey = authObj["OPENAI_API_KEY"] as? String {
                        newState.currentApiKey = apiKey
                    }
                    
                    // 读取 Tokens 详情 (ChatGPT 模式)
                    if let tokens = authObj["tokens"] as? [String: Any] {
                        let accountId = tokens["account_id"] as? String
                        newState.currentAccountId = accountId
                        newState.currentIdToken = tokens["id_token"] as? String
                        newState.currentAccessToken = tokens["access_token"] as? String
                        newState.currentRefreshToken = tokens["refresh_token"] as? String
                        
                        // 自动更新相同 account_id 预设的 auth.json 内容
                        if let accId = accountId,
                           let currentAuthJsonStr = try? String(contentsOf: authURL, encoding: .utf8) {
                            var updatedAny = false
                            for i in 0..<self.presets.count {
                                let preset = self.presets[i]
                                guard preset.isOfficial, let presetAuthStr = preset.authJson else { continue }
                                
                                if let presetAuthData = presetAuthStr.data(using: .utf8),
                                   let presetAuthObj = try? JSONSerialization.jsonObject(with: presetAuthData, options: []) as? [String: Any],
                                   let presetTokens = presetAuthObj["tokens"] as? [String: Any],
                                   let presetAccId = presetTokens["account_id"] as? String,
                                   presetAccId == accId {
                                    
                                    if presetAuthStr != currentAuthJsonStr {
                                        self.presets[i].authJson = currentAuthJsonStr
                                        updatedAny = true
                                    }
                                }
                            }
                            if updatedAny {
                                self.savePresets()
                            }
                        }
                    }
                    
                    // 读取 last_refresh
                    if let lastRefresh = authObj["last_refresh"] {
                        newState.currentLastRefresh = "\(lastRefresh)"
                    }
                }
            } else {
                newState.isOfficial = (provider == "openai")
            }
            
            // 4. 获取会话文件数量
            let sessionsDir = codexHome.appendingPathComponent("sessions")
            if FileManager.default.fileExists(atPath: sessionsDir.path) {
                let files = try FileManager.default.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil)
                newState.sessionFileCount = files.filter { $0.lastPathComponent.hasPrefix("rollout-") && $0.pathExtension == "jsonl" }.count
            }
            
            // 5. 读取 SQLite 数据库，获取总线程数与可移动/不匹配的线程数
            let dbPath = codexHome.appendingPathComponent("state_5.sqlite")
            if FileManager.default.fileExists(atPath: dbPath.path) {
                let (total, movable) = queryDatabaseStats(dbPath: dbPath.path, currentProvider: provider, currentModel: model)
                newState.totalThreads = total
                newState.movableThreads = movable
            }
            
        } catch {
            print("刷新状态失败: \(error)")
        }
        
        self.state = newState
        fetchAllQuotas()
    }
    
    /// 执行预设切换
    func switchPreset(_ preset: ProviderPreset) -> Bool {
        do {
            // 1. 读取当前的 config.toml
            var tomlText = ""
            if FileManager.default.fileExists(atPath: configURL.path) {
                tomlText = try String(contentsOf: configURL, encoding: .utf8)
            }
            
            var editor = TomlEditor(text: tomlText)
            
            // 2. 写入基础路由字段
            editor.setValue(preset.providerId, forKey: "model_provider")
            editor.setValue(preset.model, forKey: "model")
            
            // 3. 针对不同模式单独设置参数与鉴权
            if preset.isOfficial {
                // 官方模式：移除顶级和特定官方 section 的自定义配置
                editor.setValue(nil, forKey: "base_url")
                editor.setValue(nil, forKey: "experimental_bearer_token")
                
                // 彻底清除所有第三方的 model_providers.xxx 段，保持 config.toml 纯净
                editor.removeAllModelProvidersExcept(activeProviderId: nil)
                
                // 彻底覆盖重写 auth.json 写入网页登录态，绝不保留任何第三方 API 的残留
                if let authJsonStr = preset.authJson, !authJsonStr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    try authJsonStr.write(to: authURL, atomically: true, encoding: .utf8)
                } else {
                    let initialAuth: [String: Any] = ["auth_mode": "chatgpt"]
                    let authData = try JSONSerialization.data(withJSONObject: initialAuth, options: [.prettyPrinted])
                    try authData.write(to: authURL, options: .atomic)
                }
            } else {
                // API 模式：彻底清除其他第三方的 model_providers.xxx 段，只保留当前激活的 API 供应商配置
                editor.removeAllModelProvidersExcept(activeProviderId: preset.providerId)
                
                // 写入当前特定 Provider Section
                let sectionName = "model_providers.\(preset.providerId)"
                editor.setValue(preset.name, forKey: "name", inSection: sectionName)
                editor.setValue(preset.baseUrl ?? "", forKey: "base_url", inSection: sectionName)
                editor.setValue("responses", forKey: "wire_api", inSection: sectionName)
                editor.setValue(preset.apiKey ?? "", forKey: "experimental_bearer_token", inSection: sectionName)
                
                // 确保顶级没有残留导致冲突
                editor.setValue(nil, forKey: "base_url")
                editor.setValue(nil, forKey: "experimental_bearer_token")
                
                // API 模式下彻底清除/覆盖 auth.json 里的 chatgpt 网页登录态，以防冲突
                // 写入 `bearer_only` 告知 Codex 跳过网页/OAuth 登录态校验，仅走 API key
                let apiAuth: [String: Any] = ["auth_mode": "bearer_only"]
                let authData = try JSONSerialization.data(withJSONObject: apiAuth, options: [.prettyPrinted])
                try authData.write(to: authURL, options: .atomic)
            }
            
            // 4. 原子性写入修改后的 config.toml
            let newTomlText = editor.toString()
            try newTomlText.write(to: configURL, atomically: true, encoding: .utf8)
            
            refreshState()
            return true
        } catch {
            print("切换预设失败: \(error)")
            return false
        }
    }
    
    
    /// 从当前用户 .codex 实际配置中读取并导入为一个预设卡片
    func importCurrentConfigAsPreset() -> (success: Bool, message: String) {
        // 1. 检查是否存在 config.toml
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            return (false, "本地配置文件 config.toml 不存在")
        }
        
        do {
            let tomlText = try String(contentsOf: configURL, encoding: .utf8)
            let editor = TomlEditor(text: tomlText)
            
            // 2. 读取必要的路由字段
            let providerId = editor.getValue(forKey: "model_provider") ?? "openai"
            let model = editor.getValue(forKey: "model") ?? "gpt-5.5"
            
            // 3. 读取 auth.json 判别是否是官方网页登录模式
            var isOfficial = (providerId == "openai")
            var authApiKey: String? = nil
            var accountId: String? = nil
            
            if FileManager.default.fileExists(atPath: authURL.path) {
                let authData = try Data(contentsOf: authURL)
                if let authObj = try? JSONSerialization.jsonObject(with: authData, options: []) as? [String: Any] {
                    let authMode = authObj["auth_mode"] as? String
                    if authMode == "chatgpt" {
                        isOfficial = true
                    }
                    authApiKey = authObj["OPENAI_API_KEY"] as? String
                    
                    if let tokens = authObj["tokens"] as? [String: Any] {
                        accountId = tokens["account_id"] as? String
                    }
                }
            }
            
            // 4. 读取该配置下的详细字段
            let presetName: String
            let presetBaseUrl: String?
            let presetApiKey: String?
            let presetAuthJson: String?
            
            if isOfficial {
                presetName = "导入的ChatGPT账号 (\(model))"
                presetBaseUrl = nil
                presetApiKey = nil
                if FileManager.default.fileExists(atPath: authURL.path) {
                    presetAuthJson = try? String(contentsOf: authURL, encoding: .utf8)
                } else {
                    presetAuthJson = nil
                }
            } else {
                let sectionName = "model_providers.\(providerId)"
                presetName = editor.getValue(forKey: "name", inSection: sectionName) ?? "导入的预设 (\(providerId))"
                presetBaseUrl = editor.getValue(forKey: "base_url", inSection: sectionName) ?? editor.getValue(forKey: "base_url") ?? "https://api.openai.com/v1"
                presetApiKey = editor.getValue(forKey: "experimental_bearer_token", inSection: sectionName) ?? editor.getValue(forKey: "experimental_bearer_token") ?? authApiKey ?? ""
                presetAuthJson = nil
            }
            
            // 5. 校验当前配置是否已经在预设列表中（基于核心配置字段对比，对于官方账号匹配 account_id）
            let matchedIndex = presets.firstIndex { preset in
                if preset.isOfficial && isOfficial {
                    guard let currentAccountId = accountId,
                          let presetAuthStr = preset.authJson,
                          let presetAuthData = presetAuthStr.data(using: .utf8),
                          let presetAuthObj = try? JSONSerialization.jsonObject(with: presetAuthData, options: []) as? [String: Any],
                          let presetTokens = presetAuthObj["tokens"] as? [String: Any],
                          let presetAccountId = presetTokens["account_id"] as? String else {
                        return false
                    }
                    return presetAccountId == currentAccountId
                } else {
                    return preset.providerId == providerId &&
                           preset.isOfficial == isOfficial &&
                           preset.model == model &&
                           (preset.baseUrl ?? "") == (presetBaseUrl ?? "") &&
                           (preset.apiKey ?? "") == (presetApiKey ?? "")
                }
            }
            
            if let index = matchedIndex {
                let old = presets[index]
                // 覆盖更新 auth.json 登录凭证，并保留用户修改的名字和原 ID
                let updated = ProviderPreset(
                    id: old.id,
                    name: old.name,
                    isOfficial: old.isOfficial,
                    providerId: old.providerId,
                    model: old.model,
                    baseUrl: old.baseUrl,
                    apiKey: old.apiKey,
                    authJson: presetAuthJson,
                    detectedBalanceProvider: old.detectedBalanceProvider
                )
                presets[index] = updated
                savePresets()
                refreshState()
                return (true, "当前配置已在列表中（「\(old.name)」），已成功同步最新的 auth.json 登录凭证！")
            }
            
            // 6. 不存在，则作为新预设追加在列表尾部
            let preset = ProviderPreset(
                id: UUID().uuidString,
                name: presetName,
                isOfficial: isOfficial,
                providerId: providerId,
                model: model,
                baseUrl: presetBaseUrl,
                apiKey: presetApiKey,
                authJson: presetAuthJson,
                detectedBalanceProvider: nil
            )
            
            presets.append(preset)
            savePresets()
            refreshState()
            
            if !isOfficial {
                detectAndSaveBalanceProvider(for: preset, debounce: false)
            }
            
            return (true, "已成功导入「\(preset.name)」并添加至列表！")
            
        } catch {
            return (false, "导入失败: \(error.localizedDescription)")
        }
    }
    
    /// 本地 SQLite 状态的快速轻量级只读查询（无需完整连接 SyncEngine）
    private func queryDatabaseStats(dbPath: String, currentProvider: String, currentModel: String) -> (total: Int, movable: Int) {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return (0, 0)
        }
        defer {
            sqlite3_close(db)
        }
        
        var total = 0
        var movable = 0
        
        // 1. 查询总数
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM threads", -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW {
                total = Int(sqlite3_column_int(stmt, 0))
            }
            sqlite3_finalize(stmt)
        }
        
        // 2. 检查 threads 表的列名中是否包含 model 字段
        var hasModelColumn = false
        if sqlite3_prepare_v2(db, "PRAGMA table_info(threads)", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let nameBytes = sqlite3_column_text(stmt, 1) {
                    let colName = String(cString: nameBytes)
                    if colName == "model" {
                        hasModelColumn = true
                    }
                }
            }
            sqlite3_finalize(stmt)
        }
        
        // 3. 查询待移动/不匹配数量
        let querySql: String
        if hasModelColumn {
            querySql = "SELECT COUNT(*) FROM threads WHERE (model_provider IS NULL OR model_provider <> ?) OR (model IS NULL OR model <> ?)"
        } else {
            querySql = "SELECT COUNT(*) FROM threads WHERE model_provider IS NULL OR model_provider <> ?"
        }
        
        if sqlite3_prepare_v2(db, querySql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, currentProvider, -1, nil)
            if hasModelColumn {
                sqlite3_bind_text(stmt, 2, currentModel, -1, nil)
            }
            if sqlite3_step(stmt) == SQLITE_ROW {
                movable = Int(sqlite3_column_int(stmt, 0))
            }
            sqlite3_finalize(stmt)
        }
        
        return (total, movable)
    }
    
    /// 更新指定预设的 auth.json 内容
    func updatePresetAuthJson(id: String) {
        guard let index = presets.firstIndex(where: { $0.id == id }) else { return }
        let old = presets[index]
        if let authJsonStr = try? String(contentsOf: authURL, encoding: .utf8) {
            let updated = ProviderPreset(
                id: old.id,
                name: old.name,
                isOfficial: old.isOfficial,
                providerId: old.providerId,
                model: old.model,
                baseUrl: old.baseUrl,
                apiKey: old.apiKey,
                authJson: authJsonStr,
                detectedBalanceProvider: old.detectedBalanceProvider
            )
            presets[index] = updated
            savePresets()
            refreshState()
        }
    }
    
    /// 从当前实际配置中全新导入为一个预设卡片并应用
    func importCurrentConfigAsNewPreset() {
        guard FileManager.default.fileExists(atPath: configURL.path) else { return }
        
        do {
            let tomlText = try String(contentsOf: configURL, encoding: .utf8)
            let editor = TomlEditor(text: tomlText)
            
            let providerId = editor.getValue(forKey: "model_provider") ?? "openai"
            let model = editor.getValue(forKey: "model") ?? "gpt-5.5"
            
            var isOfficial = (providerId == "openai")
            if FileManager.default.fileExists(atPath: authURL.path) {
                let authData = try Data(contentsOf: authURL)
                if let authObj = try? JSONSerialization.jsonObject(with: authData, options: []) as? [String: Any] {
                    let authMode = authObj["auth_mode"] as? String
                    if authMode == "chatgpt" {
                        isOfficial = true
                    }
                }
            }
            
            let preset: ProviderPreset
            if isOfficial {
                let authJsonStr = try? String(contentsOf: authURL, encoding: .utf8)
                preset = ProviderPreset(
                    id: UUID().uuidString,
                    name: "导入的ChatGPT账号 (\(model))",
                    isOfficial: true,
                    providerId: providerId,
                    model: model,
                    baseUrl: nil,
                    apiKey: nil,
                    authJson: authJsonStr,
                    detectedBalanceProvider: nil
                )
            } else {
                let sectionName = "model_providers.\(providerId)"
                let name = editor.getValue(forKey: "name", inSection: sectionName) ?? "导入的预设 (\(providerId))"
                let baseUrl = editor.getValue(forKey: "base_url", inSection: sectionName) ?? editor.getValue(forKey: "base_url") ?? "https://api.openai.com/v1"
                
                var apiKey = ""
                if FileManager.default.fileExists(atPath: authURL.path) {
                    let authData = try Data(contentsOf: authURL)
                    if let authObj = try? JSONSerialization.jsonObject(with: authData, options: []) as? [String: Any] {
                        apiKey = authObj["OPENAI_API_KEY"] as? String ?? ""
                    }
                }
                if apiKey.isEmpty {
                    apiKey = editor.getValue(forKey: "experimental_bearer_token", inSection: sectionName) ?? editor.getValue(forKey: "experimental_bearer_token") ?? ""
                }
                
                preset = ProviderPreset(
                    id: UUID().uuidString,
                    name: name,
                    isOfficial: false,
                    providerId: providerId,
                    model: model,
                    baseUrl: baseUrl,
                    apiKey: apiKey,
                    authJson: nil,
                    detectedBalanceProvider: nil
                )
            }
            
            presets.append(preset)
            savePresets()
            refreshState()
            
            if !isOfficial {
                detectAndSaveBalanceProvider(for: preset, debounce: false)
            }
        } catch {
            print("导入失败: \(error)")
        }
    }
    
    /// 异步获取所有 ChatGPT 预设的额度
    func fetchAllQuotas() {
        for preset in presets {
            guard preset.isOfficial else { continue }
            guard let authJson = preset.authJson,
                  let authData = authJson.data(using: .utf8),
                  let authObj = try? JSONSerialization.jsonObject(with: authData, options: []) as? [String: Any],
                  let tokens = authObj["tokens"] as? [String: Any],
                  let accessToken = tokens["access_token"] as? String else {
                continue
            }
            
            let accountId = tokens["account_id"] as? String
            let presetId = preset.id
            
            // 异步请求
            var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
            request.httpMethod = "GET"
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("codex-cli", forHTTPHeaderField: "User-Agent")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if let accId = accountId {
                request.setValue(accId, forHTTPHeaderField: "ChatGPT-Account-Id")
            }
            
            URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
                guard let self = self else { return }
                guard error == nil, let data = data else {
                    return
                }
                
                // 解析 JSON
                if let dict = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                   let rateLimit = dict["rate_limit"] as? [String: Any] {
                    
                    var primaryText = "--"
                    var secondaryText = "--"
                    
                    if let primary = rateLimit["primary_window"] as? [String: Any] {
                        // used_percent 是 0-100 的整数百分比，剩余 = 100 - used
                        let usedPercent: Double
                        if let v = primary["used_percent"] as? Double {
                            usedPercent = v
                        } else if let v = primary["used_percent"] as? Int {
                            usedPercent = Double(v)
                        } else {
                            usedPercent = 0
                        }
                        let remaining = Int(round(100.0 - usedPercent))
                        primaryText = "\(remaining)%"
                    }
                    
                    if let secondary = rateLimit["secondary_window"] as? [String: Any] {
                        // used_percent 是 0-100 的整数百分比，剩余 = 100 - used
                        let usedPercent: Double
                        if let v = secondary["used_percent"] as? Double {
                            usedPercent = v
                        } else if let v = secondary["used_percent"] as? Int {
                            usedPercent = Double(v)
                        } else {
                            usedPercent = 0
                        }
                        let remaining = Int(round(100.0 - usedPercent))
                        secondaryText = "\(remaining)%"
                    }
                    
                    let quotaStr = "剩余：5h: \(primaryText) | 7d: \(secondaryText)"
                    
                    DispatchQueue.main.async {
                        self.accountQuotas[presetId] = quotaStr
                    }
                } else {
                    DispatchQueue.main.async {
                        self.accountQuotas[presetId] = "额度获取失败"
                    }
                }
            }.resume()
        }
        
        // API 模式余额查询：使用已探测的供应商类型
        for preset in presets {
            guard !preset.isOfficial else { continue }
            guard let baseUrl = preset.baseUrl, !baseUrl.isEmpty,
                  let apiKey = preset.apiKey, !apiKey.isEmpty else { continue }
            guard let providerRaw = preset.detectedBalanceProvider,
                  let providerType = BalanceProviderType(rawValue: providerRaw),
                  providerType != .unknown else { continue }
            
            let presetId = preset.id
            Task { [weak self] in
                guard let self = self else { return }
                guard let result = await fetchBalance(provider: providerType, baseUrl: baseUrl, apiKey: apiKey) else { return }
                let display = result.displayString
                await MainActor.run { self.accountQuotas[presetId] = display }
            }
        }
    }
    
    /// 触发对指定 API 模式预设的供应商探测，并将结果回写到 preset（支持可选防抖）
    func detectAndSaveBalanceProvider(for preset: ProviderPreset, debounce: Bool = false) {
        guard !preset.isOfficial,
              let baseUrl = preset.baseUrl, !baseUrl.isEmpty,
              let apiKey = preset.apiKey, !apiKey.isEmpty else { return }
        let presetId = preset.id
        
        if debounce {
            detectionTasks[presetId]?.cancel()
            detectionTasks[presetId] = Task { [weak self] in
                do {
                    // 1.5 秒延迟以实现防抖
                    try await Task.sleep(nanoseconds: 1_500_000_000)
                } catch {
                    return // 被取消了
                }
                guard let self = self else { return }
                await self.executeDetection(presetId: presetId, baseUrl: baseUrl, apiKey: apiKey)
            }
        } else {
            Task { [weak self] in
                guard let self = self else { return }
                await self.executeDetection(presetId: presetId, baseUrl: baseUrl, apiKey: apiKey)
            }
        }
    }
    
    private func executeDetection(presetId: String, baseUrl: String, apiKey: String) async {
        let detected = await detectBalanceProvider(baseUrl: baseUrl, apiKey: apiKey)
        await MainActor.run {
            guard let index = self.presets.firstIndex(where: { $0.id == presetId }) else { return }
            let old = self.presets[index]
            self.presets[index] = ProviderPreset(
                id: old.id, name: old.name, isOfficial: old.isOfficial,
                providerId: old.providerId, model: old.model,
                baseUrl: old.baseUrl, apiKey: old.apiKey,
                authJson: old.authJson,
                detectedBalanceProvider: detected.rawValue
            )
            self.savePresets()
            // 探测完成后立刻查一次余额
            if detected != .unknown {
                Task {
                    guard let result = await fetchBalance(provider: detected, baseUrl: baseUrl, apiKey: apiKey) else { return }
                    let display = result.displayString
                    await MainActor.run { self.accountQuotas[presetId] = display }
                }
            }
        }
    }
}

// MARK: - 极轻量语法保留 TOML 编辑器
struct TomlEditor {
    var lines: [String]
    
    init(text: String) {
        self.lines = text.components(separatedBy: .newlines)
    }
    
    /// 获取指定 Table (Section) 下的 Key 对应的值。若 Section 为 nil 则获取 Top-level 字段。
    func getValue(forKey key: String, inSection section: String? = nil) -> String? {
        var currentSection: String? = nil
        let keyPattern = #"^\s*\Q\#(key)\E\s*=\s*"([^"]*)""#
        guard let regex = try? NSRegularExpression(pattern: keyPattern, options: []) else { return nil }
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                currentSection = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                continue
            }
            
            if currentSection == section {
                let range = NSRange(line.startIndex..<line.endIndex, in: line)
                if let match = regex.firstMatch(in: line, options: [], range: range) {
                    if let valRange = Range(match.range(at: 1), in: line) {
                        return String(line[valRange])
                    }
                }
            }
        }
        return nil
    }
    
    /// 设置或删除指定 Table (Section) 下的 Key/Value 值。若 Section 为 nil 则设置 Top-level 字段。
    mutating func setValue(_ value: String?, forKey key: String, inSection section: String? = nil) {
        var currentSection: String? = nil
        var foundSection = section == nil
        var lineIndexToReplace: Int? = nil
        var lastLineOfSection: Int = -1
        
        let keyPattern = #"^\s*\Q\#(key)\E\s*=\s*"#
        guard let regex = try? NSRegularExpression(pattern: keyPattern, options: []) else { return }
        
        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                let secName = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                currentSection = secName
                if secName == section {
                    foundSection = true
                    lastLineOfSection = i
                } else if foundSection && section != nil {
                    // 进入了其他 section
                    break
                }
                continue
            }
            
            if currentSection == section {
                lastLineOfSection = i
                let range = NSRange(line.startIndex..<line.endIndex, in: line)
                if regex.firstMatch(in: line, options: [], range: range) != nil {
                    lineIndexToReplace = i
                    break
                }
            }
        }
        
        let newLine = value != nil ? "\(key) = \"\(value!)\"" : nil
        
        if let idx = lineIndexToReplace {
            if let newLine = newLine {
                lines[idx] = newLine
            } else {
                lines.remove(at: idx)
            }
        } else if let newLine = newLine {
            if section == nil {
                // 顶级 key，插入到任意 section 声明前的最顶部位置
                var insertIdx = 0
                for (i, line) in lines.enumerated() {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("[") {
                        insertIdx = i
                        break
                    }
                }
                lines.insert(newLine, at: insertIdx)
            } else if foundSection {
                // Section 已存在，插入到该 section 的尾部
                lines.insert(newLine, at: lastLineOfSection + 1)
            } else {
                // Section 不存在，在文件尾部新建 section 并追加字段
                lines.append("")
                lines.append("[\(section!)]")
                lines.append(newLine)
            }
        }
    }
    
    /// 彻底删除指定的 Section 及其下的所有配置键值行
    mutating func removeSection(_ section: String) {
        var newLines: [String] = []
        var inTargetSection = false
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                let secName = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                if secName == section {
                    inTargetSection = true
                    continue // 跳过 section 头部行
                } else {
                    inTargetSection = false
                }
            }
            
            if inTargetSection {
                // 跳过目标 section 的行
                continue
            }
            
            newLines.append(line)
        }
        self.lines = newLines
    }
    
    /// 清除所有 model_providers.xxx 段，除了指定的 activeProviderId。
    /// 如果 activeProviderId 为 nil，则彻底清除所有的 model_providers.xxx 配置段。
    mutating func removeAllModelProvidersExcept(activeProviderId: String?) {
        var newLines: [String] = []
        var inRemoveSection = false
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                let secName = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                if secName.hasPrefix("model_providers.") {
                    let providerId = secName.replacingOccurrences(of: "model_providers.", with: "")
                    if activeProviderId == nil || providerId != activeProviderId! {
                        inRemoveSection = true
                        continue
                    } else {
                        inRemoveSection = false
                    }
                } else {
                    inRemoveSection = false
                }
            }
            
            if inRemoveSection {
                // 跳过正在被清理的 section 行
                continue
            }
            
            newLines.append(line)
        }
        self.lines = newLines
    }

    func toString() -> String {
        return lines.joined(separator: "\n")
    }
}
