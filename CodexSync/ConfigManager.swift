import Foundation
import Combine
import SQLite3

/// 核心配置文件管理器（读取与修改 config.toml 与 auth.json）
class ConfigManager: ObservableObject {
    @Published var state = CodexState()
    @Published var presets: [ProviderPreset] = []
    
    // Codex 本地主路径
    let codexHome: URL
    let configURL: URL
    let authURL: URL
    let presetsURL: URL
    
    init() {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        self.codexHome = homeDir.appendingPathComponent(".codex")
        self.configURL = codexHome.appendingPathComponent("config.toml")
        self.authURL = codexHome.appendingPathComponent("auth.json")
        
        // 预设列表的持久化存储路径
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("CodexSync")
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true, attributes: nil)
        self.presetsURL = appDir.appendingPathComponent("presets.json")
        
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
            ProviderPreset(name: "官方 ChatGPT 网页账号", isOfficial: true, providerId: "openai", model: "gpt-4o", baseUrl: nil, apiKey: nil),
            ProviderPreset(name: "自定义 API 模式 (DeepSeek)", isOfficial: false, providerId: "deepseek", model: "deepseek-chat", baseUrl: "https://api.deepseek.com/v1", apiKey: "sk-your-key-here")
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
            
            // 3. 读取 auth.json 鉴别官方网页模式
            if FileManager.default.fileExists(atPath: authURL.path) {
                let authData = try Data(contentsOf: authURL)
                if let authObj = try? JSONSerialization.jsonObject(with: authData, options: []) as? [String: Any] {
                    let authMode = authObj["auth_mode"] as? String
                    newState.isOfficial = (authMode == "chatgpt")
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
                // 官方模式：移除第三方的 custom-scoped 配置，使用 auth.json 网页登录态
                editor.setValue(nil, forKey: "base_url")
                editor.setValue(nil, forKey: "experimental_bearer_token")
                
                // 清理 model_providers 表下的自定义字段（若有）
                editor.setValue(nil, forKey: "base_url", inSection: "model_providers.\(preset.providerId)")
                editor.setValue(nil, forKey: "experimental_bearer_token", inSection: "model_providers.\(preset.providerId)")
                
                // 如果 auth.json 不存在，初始化一个标准的网页模式空框架
                if !FileManager.default.fileExists(atPath: authURL.path) {
                    let initialAuth: [String: Any] = ["auth_mode": "chatgpt"]
                    let authData = try JSONSerialization.data(withJSONObject: initialAuth, options: [.prettyPrinted])
                    try authData.write(to: authURL, options: .atomic)
                }
            } else {
                // API 模式：安全地写入特定 Provider Section，绝不破坏 auth.json 中已存的官方网页登录态
                let sectionName = "model_providers.\(preset.providerId)"
                editor.setValue(preset.name, forKey: "name", inSection: sectionName)
                editor.setValue(preset.baseUrl ?? "", forKey: "base_url", inSection: sectionName)
                editor.setValue("responses", forKey: "wire_api", inSection: sectionName)
                editor.setValue(preset.apiKey ?? "", forKey: "experimental_bearer_token", inSection: sectionName)
                
                // 确保顶级没有残留导致冲突
                editor.setValue(nil, forKey: "base_url")
                editor.setValue(nil, forKey: "experimental_bearer_token")
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
            let model = editor.getValue(forKey: "model") ?? "gpt-4o"
            
            // 3. 读取 auth.json 判别是否是官方网页登录模式
            var isOfficial = (providerId == "openai")
            var authApiKey: String? = nil
            
            if FileManager.default.fileExists(atPath: authURL.path) {
                let authData = try Data(contentsOf: authURL)
                if let authObj = try? JSONSerialization.jsonObject(with: authData, options: []) as? [String: Any] {
                    let authMode = authObj["auth_mode"] as? String
                    if authMode == "chatgpt" {
                        isOfficial = true
                    }
                    authApiKey = authObj["OPENAI_API_KEY"] as? String
                }
            }
            
            let preset: ProviderPreset
            
            if isOfficial {
                // 官方网页登录模式
                preset = ProviderPreset(
                    name: "导入的官方账号 (\(model))",
                    isOfficial: true,
                    providerId: "openai",
                    model: model,
                    baseUrl: nil,
                    apiKey: nil
                )
            } else {
                // API 密钥登录模式
                // 优先从对应的 model_providers.<providerId> 表中读取，没有则回退到 top-level
                let sectionName = "model_providers.\(providerId)"
                let name = editor.getValue(forKey: "name", inSection: sectionName) ?? "导入的预设 (\(providerId))"
                let baseUrl = editor.getValue(forKey: "base_url", inSection: sectionName) ?? editor.getValue(forKey: "base_url") ?? "https://api.openai.com/v1"
                let apiKey = editor.getValue(forKey: "experimental_bearer_token", inSection: sectionName) ?? editor.getValue(forKey: "experimental_bearer_token") ?? authApiKey ?? ""
                
                preset = ProviderPreset(
                    name: name,
                    isOfficial: false,
                    providerId: providerId,
                    model: model,
                    baseUrl: baseUrl,
                    apiKey: apiKey
                )
            }
            
            // 4. 将预设加入列表，避免重复添加相同的 providerId + isOfficial 组合
            if let existingIndex = presets.firstIndex(where: { $0.providerId == preset.providerId && $0.isOfficial == preset.isOfficial }) {
                // 覆盖已存在的同类型预设
                presets[existingIndex] = preset
            } else {
                // 追加新预设
                presets.append(preset)
            }
            
            savePresets()
            refreshState()
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
    
    func toString() -> String {
        return lines.joined(separator: "\n")
    }
}
