import Foundation
import Combine
import SQLite3

/// 核心数据同步与对齐引擎
class SyncEngine: ObservableObject {
    @Published var isSyncing = false
    @Published var progressMessage = ""
    @Published var syncError: String? = nil
    @Published var syncSuccess = false
    
    @Published var isCleaning = false
    @Published var cleanError: String? = nil
    @Published var cleanSuccess = false
    
    let codexHome: URL
    let dbURL: URL
    let backupDir: URL
    let sessionIndexURL: URL
    let sessionsDir: URL
    
    init() {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        self.codexHome = homeDir.appendingPathComponent(".codex")
        self.dbURL = codexHome.appendingPathComponent("state_5.sqlite")
        self.backupDir = codexHome.appendingPathComponent("history_sync_backups")
        self.sessionIndexURL = codexHome.appendingPathComponent("session_index.jsonl")
        self.sessionsDir = codexHome.appendingPathComponent("sessions")
    }
    
    /// 开始对齐同步核心逻辑
    func startSync(currentProvider: String, currentModel: String, completion: @escaping (Bool) -> Void) {
        guard !currentProvider.isEmpty else {
            self.syncError = "当前 Provider 为空，无法执行同步"
            completion(false)
            return
        }
        
        self.isSyncing = true
        self.progressMessage = "正在准备安全备份..."
        self.syncError = nil
        self.syncSuccess = false
        
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                // 1. 创建安全备份
                let backupURL = try self.makeSafetyBackup()
                print("安全备份已创建: \(backupURL.path)")
                
                // 2. 更新 SQLite 数据库的 threads 表
                DispatchQueue.main.async {
                    self.progressMessage = "正在同步本地数据库记录..."
                }
                let updatedRows = try self.executeUpdateInDatabase(provider: currentProvider, model: currentModel)
                
                // 3. 更新会话 JSONL 元数据
                DispatchQueue.main.async {
                    self.progressMessage = "正在更新会话元数据文件..."
                }
                let updatedSessionFiles = try self.syncSessionFiles(provider: currentProvider, model: currentModel)
                
                // 4. 重建侧边栏列表索引
                DispatchQueue.main.async {
                    self.progressMessage = "正在对齐侧边栏索引排序..."
                }
                let indexedCount = try self.rebuildSessionIndex(provider: currentProvider)
                
                DispatchQueue.main.async {
                    self.isSyncing = false
                    self.syncSuccess = true
                    self.progressMessage = "同步成功！已更新数据记录 \(updatedRows) 行，更新会话文件 \(updatedSessionFiles) 个，对齐索引 \(indexedCount) 条。"
                    completion(true)
                }
                
            } catch {
                DispatchQueue.main.async {
                    self.isSyncing = false
                    self.syncError = error.localizedDescription
                    completion(false)
                }
            }
        }
    }
    
    /// 创建安全备份
    private func makeSafetyBackup() throws -> URL {
        try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true, attributes: nil)
        
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let timestamp = formatter.string(from: Date())
        
        let backupURL = backupDir.appendingPathComponent("state_5.sqlite.pre-sync.\(timestamp).bak")
        
        // 备份 SQLite 文件
        if FileManager.default.fileExists(atPath: dbURL.path) {
            try FileManager.default.copyItem(at: dbURL, to: backupURL)
        } else {
            throw NSError(domain: "CodexSync", code: 404, userInfo: [NSLocalizedDescriptionKey: "本地历史数据库未找到: \(dbURL.path)。请确保已安装并至少打开过一次 Codex。"])
        }
        
        // 备份侧边栏索引以保万全
        if FileManager.default.fileExists(atPath: sessionIndexURL.path) {
            let indexBackupURL = backupDir.appendingPathComponent("state_5.sqlite.pre-sync.\(timestamp).bak.session_index.jsonl")
            try? FileManager.default.copyItem(at: sessionIndexURL, to: indexBackupURL)
        }
        
        return backupURL
    }
    
    /// 更新 SQLite 数据库 threads 字段，包含写锁高频重试逻辑
    private func executeUpdateInDatabase(provider: String, model: String) throws -> Int {
        var db: OpaquePointer?
        let dbPath = dbURL.path
        
        let openResult = sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE, nil)
        guard openResult == SQLITE_OK else {
            throw NSError(domain: "SQLite", code: Int(openResult), userInfo: [NSLocalizedDescriptionKey: "无法打开数据库"])
        }
        defer {
            sqlite3_close(db)
        }
        
        // 设置 30 秒的 SQLite busy timeout
        sqlite3_busy_timeout(db, 30000)
        
        // 检查 threads 表的列名中是否包含 model 字段
        var hasModelColumn = false
        var stmt: OpaquePointer?
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
        
        var attempts = 0
        let maxAttempts = 40
        let retryDelayMicroseconds: useconds_t = 250_000 // 0.25 秒
        
        while attempts < maxAttempts {
            attempts += 1
            
            // 显式开始写事务，控制重试节奏
            let beginResult = sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil)
            if beginResult == SQLITE_OK {
                let querySql: String
                if hasModelColumn {
                    querySql = "UPDATE threads SET model_provider = ?, model = ? WHERE (model_provider IS NULL OR model_provider <> ?) OR (model IS NULL OR model <> ?)"
                } else {
                    querySql = "UPDATE threads SET model_provider = ? WHERE model_provider IS NULL OR model_provider <> ?"
                }
                
                var updateStmt: OpaquePointer?
                let prepareResult = sqlite3_prepare_v2(db, querySql, -1, &updateStmt, nil)
                if prepareResult == SQLITE_OK {
                    let SQLITE_TRANSIENT = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)
                    sqlite3_bind_text(updateStmt, 1, provider, -1, SQLITE_TRANSIENT)
                    if hasModelColumn {
                        sqlite3_bind_text(updateStmt, 2, model, -1, SQLITE_TRANSIENT)
                        sqlite3_bind_text(updateStmt, 3, provider, -1, SQLITE_TRANSIENT)
                        sqlite3_bind_text(updateStmt, 4, model, -1, SQLITE_TRANSIENT)
                    } else {
                        sqlite3_bind_text(updateStmt, 2, provider, -1, SQLITE_TRANSIENT)
                    }
                    
                    let stepResult = sqlite3_step(updateStmt)
                    let updatedRows = Int(sqlite3_changes(db))
                    sqlite3_finalize(updateStmt)
                    
                    if stepResult == SQLITE_DONE {
                        let commitResult = sqlite3_exec(db, "COMMIT;", nil, nil, nil)
                        if commitResult == SQLITE_OK {
                            // 执行 WAL 刷盘
                            sqlite3_exec(db, "PRAGMA wal_checkpoint(PASSIVE);", nil, nil, nil)
                            return updatedRows
                        } else {
                            sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                        }
                    } else {
                        sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                    }
                } else {
                    sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                }
            }
            
            // 写锁未成功获取，休眠后重试
            usleep(retryDelayMicroseconds)
        }
        
        throw NSError(domain: "SQLite", code: 5, userInfo: [NSLocalizedDescriptionKey: "数据库被 Codex 占用中，获取写锁超时。请确保 Codex 没有在回复或自动保存，然后再试。"])
    }
    
    /// 原子性批量覆写 rollout JSONL 文件的会话元数据
    private func syncSessionFiles(provider: String, model: String) throws -> Int {
        guard FileManager.default.fileExists(atPath: sessionsDir.path) else {
            return 0
        }
        
        var jsonlFiles: [URL] = []
        if let enumerator = FileManager.default.enumerator(at: sessionsDir, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
            for case let fileURL as URL in enumerator {
                if fileURL.lastPathComponent.hasPrefix("rollout-") && fileURL.pathExtension == "jsonl" {
                    jsonlFiles.append(fileURL)
                }
            }
        }
        
        var updatedCount = 0
        
        for fileURL in jsonlFiles {
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            let lines = content.components(separatedBy: .newlines)
            var newLines: [String] = []
            var changed = false
            
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.contains("\"session_meta\"") {
                    if let data = trimmed.data(using: .utf8),
                       var json = try? JSONSerialization.jsonObject(with: data, options: [.mutableContainers]) as? [String: Any],
                       var payload = json["payload"] as? [String: Any] {
                        
                        let providerMatches = payload["model_provider"] as? String == provider
                        let modelMatches = payload["model"] as? String == model
                        
                        if !providerMatches || !modelMatches {
                            payload["model_provider"] = provider
                            payload["model"] = model
                            json["payload"] = payload
                            
                            let newData = try JSONSerialization.data(withJSONObject: json, options: [])
                            if let newJsonLine = String(data: newData, encoding: .utf8) {
                                newLines.append(newJsonLine)
                                changed = true
                                continue
                            }
                        }
                    }
                }
                newLines.append(line)
            }
            
            if changed {
                let newContent = newLines.joined(separator: "\n")
                // 采用原子写入选项，防止写入半成品导致文件损坏
                try newContent.write(to: fileURL, atomically: true, encoding: .utf8)
                updatedCount += 1
            }
        }
        
        return updatedCount
    }
    
    /// 重建侧边栏列表索引
    private func rebuildSessionIndex(provider: String) throws -> Int {
        var db: OpaquePointer?
        let dbPath = dbURL.path
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return 0
        }
        defer {
            sqlite3_close(db)
        }
        
        // 检查 threads 的字段信息
        var hasArchived = false
        var hasTitle = false
        var hasUpdatedAt = false
        
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "PRAGMA table_info(threads)", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let nameBytes = sqlite3_column_text(stmt, 1) {
                    let colName = String(cString: nameBytes)
                    if colName == "archived" { hasArchived = true }
                    if colName == "title" { hasTitle = true }
                    if colName == "updated_at" { hasUpdatedAt = true }
                }
            }
            sqlite3_finalize(stmt)
        }
        
        struct DbThread {
            let id: String
            let title: String
            let updatedAt: Double // Unix timestamp in seconds
        }
        
        var dbThreads: [DbThread] = []
        var selectParts = ["id"]
        if hasTitle { selectParts.append("title") }
        if hasUpdatedAt { selectParts.append("updated_at") }
        
        let whereSql = hasArchived ? "WHERE archived = 0" : ""
        let querySql = "SELECT \(selectParts.joined(separator: ", ")) FROM threads \(whereSql)"
        
        if sqlite3_prepare_v2(db, querySql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = String(cString: sqlite3_column_text(stmt, 0))
                var title = id
                if hasTitle, let titleBytes = sqlite3_column_text(stmt, 1) {
                    title = String(cString: titleBytes)
                }
                var updatedAt = Date().timeIntervalSince1970
                if hasUpdatedAt {
                    let idx = hasTitle ? 2 : 1
                    let val = sqlite3_column_int64(stmt, Int32(idx))
                    if val > 1_000_000_000_000 {
                        // 毫秒级时间戳，转为秒
                        updatedAt = Double(val) / 1000.0
                    } else if val > 0 {
                        updatedAt = Double(val)
                    }
                }
                dbThreads.append(DbThread(id: id, title: title, updatedAt: updatedAt))
            }
            sqlite3_finalize(stmt)
        }
        
        // 读取已存在的 session_index.jsonl，用于获取用户手动改过的自定义 thread_name
        struct IndexEntry: Codable {
            let id: String
            let thread_name: String
            let updated_at: String
        }
        
        var existingNames: [String: String] = [:]
        if FileManager.default.fileExists(atPath: sessionIndexURL.path) {
            if let indexContent = try? String(contentsOf: sessionIndexURL, encoding: .utf8) {
                let decoder = JSONDecoder()
                let indexLines = indexContent.components(separatedBy: .newlines)
                for line in indexLines {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.isEmpty { continue }
                    if let data = trimmed.data(using: .utf8),
                       let entry = try? decoder.decode(IndexEntry.self, from: data) {
                        existingNames[entry.id] = entry.thread_name
                    }
                }
            }
        }
        
        // 合并数据库信息和自定义别名
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        
        var mergedEntries: [[String: String]] = []
        for dbThread in dbThreads {
            let name = existingNames[dbThread.id] ?? dbThread.title
            let date = Date(timeIntervalSince1970: dbThread.updatedAt)
            let dateStr = isoFormatter.string(from: date)
            
            let entry: [String: String] = [
                "id": dbThread.id,
                "thread_name": name,
                "updated_at": dateStr
            ]
            mergedEntries.append(entry)
        }
        
        // 按时间升序排序（Codex 侧边栏索引由旧到新）
        mergedEntries.sort { (a, b) -> Bool in
            let dateA = a["updated_at"] ?? ""
            let dateB = b["updated_at"] ?? ""
            return dateA < dateB
        }
        
        // 写回 session_index.jsonl
        let lines = mergedEntries.compactMap { dict -> String? in
            guard let data = try? JSONSerialization.data(withJSONObject: dict, options: []),
                  let str = String(data: data, encoding: .utf8) else { return nil }
            return str
        }
        
        let indexContent = lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
        try indexContent.write(to: sessionIndexURL, atomically: true, encoding: .utf8)
        
        return mergedEntries.count
    }
    
    /// 清理数据库中不存在物理文件的残留幽灵会话记录
    func cleanGhostSessions(completion: @escaping (Bool) -> Void) {
        self.isCleaning = true
        self.cleanError = nil
        self.cleanSuccess = false
        self.progressMessage = "正在准备安全备份..."
        
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                // 1. 创建安全备份
                let backupURL = try self.makeSafetyBackup()
                print("安全备份已创建: \(backupURL.path)")
                
                // 2. 扫描物理会话文件获取所有合法的 UUID
                DispatchQueue.main.async {
                    self.progressMessage = "正在扫描物理会话文件..."
                }
                let activeUUIDs = try self.scanExistingSessionUUIDs()
                
                // 3. 执行数据库删除操作
                DispatchQueue.main.async {
                    self.progressMessage = "正在清理数据库残留记录..."
                }
                let deletedCount = try self.executeDeleteGhostSessionsInDatabase(existingUUIDs: activeUUIDs)
                
                DispatchQueue.main.async {
                    self.isCleaning = false
                    self.cleanSuccess = true
                    self.progressMessage = "清理成功！已从数据库清除 \(deletedCount) 个残留的幽灵会话记录。"
                    completion(true)
                }
            } catch {
                DispatchQueue.main.async {
                    self.isCleaning = false
                    self.cleanError = error.localizedDescription
                    completion(false)
                }
            }
        }
    }
    
    /// 遍历 sessions 和 archived_sessions 目录，提取所有物理会话的 UUID 集合
    private func scanExistingSessionUUIDs() throws -> Set<String> {
        var uuids = Set<String>()
        let fm = FileManager.default
        
        // 匹配标准 UUID 格式
        let uuidPattern = "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
        guard let regex = try? NSRegularExpression(pattern: uuidPattern, options: []) else {
            throw NSError(domain: "CodexSync", code: 500, userInfo: [NSLocalizedDescriptionKey: "无法初始化正则表达式"])
        }
        
        func scanDirectoryRecursive(_ dir: URL) {
            guard fm.fileExists(atPath: dir.path) else { return }
            if let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
                for case let fileURL as URL in enumerator {
                    guard fileURL.lastPathComponent.hasPrefix("rollout-") && fileURL.pathExtension == "jsonl" else { continue }
                    let filename = fileURL.lastPathComponent
                    let nsString = filename as NSString
                    let results = regex.matches(in: filename, options: [], range: NSRange(location: 0, length: nsString.length))
                    // UUID 通常在 rollout-yyyyMMdd-HHmmss-[UUID].jsonl 文件名的末尾
                    if let match = results.last {
                        let uuid = nsString.substring(with: match.range).lowercased()
                        uuids.insert(uuid)
                    }
                }
            }
        }
        
        scanDirectoryRecursive(sessionsDir)
        let archivedSessionsDir = codexHome.appendingPathComponent("archived_sessions")
        scanDirectoryRecursive(archivedSessionsDir)
        
        return uuids
    }
    
    /// 在 SQLite 事务中安全对比并删除幽灵记录，包含写锁安全重试
    private func executeDeleteGhostSessionsInDatabase(existingUUIDs: Set<String>) throws -> Int {
        var db: OpaquePointer?
        let dbPath = dbURL.path
        
        let openResult = sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE, nil)
        guard openResult == SQLITE_OK else {
            throw NSError(domain: "SQLite", code: Int(openResult), userInfo: [NSLocalizedDescriptionKey: "无法打开数据库"])
        }
        defer {
            sqlite3_close(db)
        }
        
        // 30 秒超时
        sqlite3_busy_timeout(db, 30000)
        
        // 1. 查询当前 threads 表中所有的 id
        var stmt: OpaquePointer?
        var dbIds: [String] = []
        
        if sqlite3_prepare_v2(db, "SELECT id FROM threads", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let idBytes = sqlite3_column_text(stmt, 0) {
                    dbIds.append(String(cString: idBytes).lowercased())
                }
            }
            sqlite3_finalize(stmt)
        }
        
        // 2. 筛选出数据库中有但物理文件已经不存在的残留 ID
        let ghostIds = dbIds.filter { !existingUUIDs.contains($0) }
        
        guard !ghostIds.isEmpty else {
            return 0
        }
        
        // 3. 循环等待写锁并启动 IMMEDIATE 写事务批量删除
        var attempts = 0
        let maxAttempts = 40
        let retryDelayMicroseconds: useconds_t = 250_000 // 0.25 秒
        
        while attempts < maxAttempts {
            attempts += 1
            
            let beginResult = sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil)
            if beginResult == SQLITE_OK {
                var deleteStmt: OpaquePointer?
                let deleteSql = "DELETE FROM threads WHERE id = ?"
                
                if sqlite3_prepare_v2(db, deleteSql, -1, &deleteStmt, nil) == SQLITE_OK {
                    var deletedSuccessfully = true
                    let SQLITE_TRANSIENT = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)
                    var actualDeletedRows = 0
                    
                    for ghostId in ghostIds {
                        sqlite3_bind_text(deleteStmt, 1, ghostId, -1, SQLITE_TRANSIENT)
                        let stepResult = sqlite3_step(deleteStmt)
                        actualDeletedRows += Int(sqlite3_changes(db))
                        sqlite3_reset(deleteStmt)
                        
                        if stepResult != SQLITE_DONE {
                            deletedSuccessfully = false
                            break
                        }
                    }
                    
                    sqlite3_finalize(deleteStmt)
                    
                    if deletedSuccessfully {
                        let commitResult = sqlite3_exec(db, "COMMIT;", nil, nil, nil)
                        if commitResult == SQLITE_OK {
                            // WAL checkpoint 物理刷盘
                            sqlite3_exec(db, "PRAGMA wal_checkpoint(PASSIVE);", nil, nil, nil)
                            return actualDeletedRows
                        } else {
                            sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                        }
                    } else {
                        sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                    }
                } else {
                    sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                }
            }
            
            usleep(retryDelayMicroseconds)
        }
        
        throw NSError(domain: "SQLite", code: 5, userInfo: [NSLocalizedDescriptionKey: "数据库被 Codex 占用中，获取写锁超时。请确保 Codex 没有在回复或自动保存，然后再试。"])
    }
}
