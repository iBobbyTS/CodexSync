import SwiftUI

struct ContentView: View {
    @EnvironmentObject var configManager: ConfigManager
    @EnvironmentObject var syncEngine: SyncEngine
    
    @Environment(\.controlActiveState) var controlActiveState
    
    @State private var selectedPresetId: String? = nil
    @State private var showingAddSheet = false
    
    // 自定义预设的新增/编辑临时状态
    @State private var newName = ""
    @State private var newIsOfficial = false
    @State private var newProviderId = "custom"
    @State private var newModel = "gpt-5.5"
    @State private var newBaseUrl = ""
    @State private var newApiKey = ""
    @State private var newAuthJson = ""
    
    // 隐藏/显示秘钥与auth.json的状态控制
    @State private var showAuthJson = false
    @State private var showApiKey = false
    @State private var showNewAuthJson = false
    @State private var showNewApiKey = false
    
    // 导入当前活动配置相关状态
    @State private var showingImportAlert = false
    @State private var importAlertMessage = ""
    
    var body: some View {
        NavigationSplitView {
            // 左侧边栏：预设列表
            VStack(alignment: .leading, spacing: 0) {
                Text("配置预设")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 8)
                
                List(selection: $selectedPresetId) {
                    ForEach(configManager.presets) { preset in
                        NavigationLink(value: preset.id) {
                            HStack {
                                Image(systemName: preset.isOfficial ? "person.crop.circle" : "network")
                                    .font(.title3)
                                    .foregroundColor(preset.isOfficial ? .blue : .purple)
                                
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(preset.name)
                                        .fontWeight(.medium)
                                    
                                    if preset.isOfficial {
                                        let quotaStr = configManager.accountQuotas[preset.id]
                                        // 提取所有百分比数值，分段着色
                                        let nums = (quotaStr ?? "").matches(of: /(\d+)%/).map { Int($0.output.1) ?? 100 }
                                        if nums.count >= 2 {
                                            let p = nums[0], s = nums[1]
                                            (Text("剩余：").foregroundColor(.secondary) +
                                             Text("5h: \(p)%").foregroundColor(p < 5 ? .red : .green) +
                                             Text(" | ").foregroundColor(.secondary) +
                                             Text("7d: \(s)%").foregroundColor(s < 5 ? .red : .green))
                                                .font(.caption)
                                        } else {
                                            Text(quotaStr ?? preset.model)
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                    } else {
                                        let balanceStr = configManager.accountQuotas[preset.id]
                                        if let bs = balanceStr, bs.hasPrefix("余额：") {
                                            // 提取数值用于颜色判断
                                            let amountPart = String(bs.dropFirst("余额：".count))
                                            let numVal = bs.matches(of: /[\d.]+/).first
                                                .flatMap { Double(bs[$0.range]) } ?? 0.0
                                            let amountColor: Color = numVal < 5 ? .red : .green
                                            (Text("余额：").foregroundColor(.secondary) +
                                             Text(amountPart).foregroundColor(amountColor))
                                                .font(.caption)
                                        } else {
                                            Text(balanceStr ?? preset.model)
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                }
                                
                                Spacer()
                                
                                // 激活与更新指示灯
                                if configManager.state.currentProvider == preset.providerId &&
                                   (!preset.isOfficial || configManager.state.isOfficial) {
                                    if preset.isOfficial && isPresetMatchingCurrentAccount(preset) && presetNeedsUpdate(preset) {
                                        HStack(spacing: 8) {
                                            Button(action: {
                                                configManager.updatePresetAuthJson(id: preset.id)
                                            }) {
                                                Text("更新预设")
                                                    .font(.caption)
                                                    .fontWeight(.semibold)
                                                    .foregroundColor(.white)
                                                    .padding(.horizontal, 8)
                                                    .padding(.vertical, 3)
                                                    .background(Color.orange)
                                                    .cornerRadius(4)
                                            }
                                            .buttonStyle(.plain)
                                            
                                            Circle()
                                                .fill(Color.orange)
                                                .frame(width: 8, height: 8)
                                                .shadow(color: .orange.opacity(0.5), radius: 3)
                                        }
                                    } else {
                                        Circle()
                                            .fill(Color.green)
                                            .frame(width: 8, height: 8)
                                            .shadow(color: .green.opacity(0.5), radius: 3)
                                    }
                                }
                            }
                        }
                        .tag(preset.id as String?)
                        .contextMenu {
                            Button(role: .destructive) {
                                if let idx = configManager.presets.firstIndex(where: { $0.id == preset.id }) {
                                    configManager.presets.remove(at: idx)
                                    configManager.savePresets()
                                    if selectedPresetId == preset.id {
                                        selectedPresetId = nil
                                    }
                                }
                            } label: {
                                Label("删除预设", systemImage: "trash")
                            }
                        }
                    }
                    .onDelete(perform: deletePresets)
                    
                    // 动态预设导入行 (当当前 ~/.codex 配置不在列表中时显示在最底行)
                    if configManager.state.isOfficial {
                        if !chatGptPresetExists {
                            HStack {
                                Image(systemName: "person.crop.circle.badge.plus")
                                    .font(.title3)
                                    .foregroundColor(.blue)
                                
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("导入当前~/.codex里的账号")
                                        .fontWeight(.medium)
                                    
                                    Text(configManager.state.currentModel)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                
                                Spacer()
                                
                                HStack(spacing: 8) {
                                    Button(action: {
                                        configManager.importCurrentConfigAsNewPreset()
                                    }) {
                                        Text("导入预设")
                                            .font(.caption)
                                            .fontWeight(.semibold)
                                            .foregroundColor(.white)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 3)
                                            .background(Color.blue)
                                            .cornerRadius(4)
                                    }
                                    .buttonStyle(.plain)
                                    
                                    Circle()
                                        .fill(Color.green)
                                        .frame(width: 8, height: 8)
                                        .shadow(color: .green.opacity(0.5), radius: 3)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    } else {
                        if !apiPresetExists {
                            HStack {
                                Image(systemName: "network.badge.shield.half.filled")
                                    .font(.title3)
                                    .foregroundColor(.purple)
                                
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("导入当前~/.codex里的API")
                                        .fontWeight(.medium)
                                    
                                    Text(configManager.state.currentCustomProviderName)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                
                                Spacer()
                                
                                HStack(spacing: 8) {
                                    Button(action: {
                                        configManager.importCurrentConfigAsNewPreset()
                                    }) {
                                        Text("导入预设")
                                            .font(.caption)
                                            .fontWeight(.semibold)
                                            .foregroundColor(.white)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 3)
                                            .background(Color.blue)
                                            .cornerRadius(4)
                                    }
                                    .buttonStyle(.plain)
                                    
                                    Circle()
                                        .fill(Color.green)
                                        .frame(width: 8, height: 8)
                                        .shadow(color: .green.opacity(0.5), radius: 3)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                .listStyle(.sidebar)
                .scrollBounceBehavior(.basedOnSize, axes: .vertical)
            }
            .safeAreaInset(edge: .bottom) {
                // 左下角操作栏
                HStack(spacing: 12) {
                    Button(action: {
                        resetAddSheetFields()
                        showingAddSheet = true
                    }) {
                        Label("添加预设", systemImage: "plus")
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.accentColor)
                    
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 300)
            
        } detail: {
            // 右侧主面板
            HSplitView {
                // 左半：状态指示与一键同步核心面板
                VStack(spacing: 20) {
                    // 1. 状态仪表盘
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text("Codex 本地状态")
                                .font(.title2)
                                .fontWeight(.bold)
                            Spacer()
                            Button(action: {
                                configManager.refreshState()
                            }) {
                                Image(systemName: "arrow.clockwise")
                            }
                            .buttonStyle(.borderless)
                            .help("刷新本地状态")
                        }
                        
                        Divider()
                        
                        VStack(spacing: 12) {
                            statusRow(title: "当前服务商 (Provider)", value: configManager.state.currentProvider, icon: "cpu", color: .blue)
                            statusRow(title: "当前模型 (Model)", value: configManager.state.currentModel, icon: "brain.head.profile", color: .purple)
                            statusRow(title: "登录模式", value: configManager.state.isOfficial ? "ChatGPT账号" : "API 密钥登录", icon: "key.fill", color: .orange)
                            statusRow(title: "历史会话文件数", value: "\(configManager.state.sessionFileCount) 个", icon: "doc.text.fill", color: .green)
                        }
                    }
                    .padding(20)
                    .background(Color(NSColor.windowBackgroundColor))
                    .cornerRadius(12)
                    .shadow(color: Color.black.opacity(0.04), radius: 6, x: 0, y: 3)
                    
                    // 2. 同步状态面板
                    VStack(spacing: 16) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("本地同步就绪状况")
                                    .font(.headline)
                                    .fontWeight(.bold)
                                
                                if configManager.state.pendingSyncCount > 0 {
                                    Text("检测到有 \(configManager.state.pendingSyncCount) 个历史会话属于旧模式，目前在 Codex 侧边栏已被隐藏。")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                } else {
                                    Text("完美！本地所有历史会话均已对齐当前配置模式，侧边栏显示完整。")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                }
                            }
                            Spacer()
                            
                            // 悬浮数字徽章
                            ZStack {
                                Circle()
                                    .fill(configManager.state.pendingSyncCount > 0 ? Color.orange.opacity(0.15) : Color.green.opacity(0.15))
                                    .frame(width: 44, height: 44)
                                
                                Text("\(configManager.state.pendingSyncCount)")
                                    .font(.system(.title3, design: .rounded))
                                    .fontWeight(.bold)
                                    .foregroundColor(configManager.state.pendingSyncCount > 0 ? .orange : .green)
                            }
                        }
                        
                        if syncEngine.isSyncing {
                            // 正在同步中的 Spinner
                            VStack(spacing: 8) {
                                ProgressView()
                                    .progressViewStyle(.circular)
                                Text(syncEngine.progressMessage)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 8)
                        } else {
                            // 一键同步按钮
                            Button(action: {
                                syncEngine.startSync(
                                    currentProvider: configManager.state.currentProvider,
                                    currentModel: configManager.state.currentModel
                                ) { success in
                                    if success {
                                        configManager.refreshState()
                                    }
                                }
                            }) {
                                HStack {
                                    Image(systemName: "arrow.triangle.2.circlepath")
                                    Text("一键对齐本地历史")
                                }
                                .font(.headline)
                                .foregroundColor(.white)
                                .padding(.vertical, 10)
                                .frame(maxWidth: .infinity)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(configManager.state.pendingSyncCount > 0 ? Color.blue : Color.gray.opacity(0.5))
                                )
                                .shadow(color: configManager.state.pendingSyncCount > 0 ? .blue.opacity(0.3) : .clear, radius: 4)
                            }
                            .buttonStyle(.plain)
                            .disabled(syncEngine.isSyncing)
                        }
                        
                        // 提示与错误信息
                        if let error = syncEngine.syncError {
                            Text(error)
                                .font(.caption)
                                .foregroundColor(.red)
                                .padding(8)
                                .background(Color.red.opacity(0.1))
                                .cornerRadius(6)
                        } else if syncEngine.syncSuccess {
                            Text("同步完成！请重启 Codex 客户端以刷新侧边栏。")
                                .font(.caption)
                                .foregroundColor(.green)
                                .padding(8)
                                .background(Color.green.opacity(0.1))
                                .cornerRadius(6)
                        }
                    }
                    .padding(20)
                    .background(Color(NSColor.windowBackgroundColor))
                    .cornerRadius(12)
                    .shadow(color: Color.black.opacity(0.04), radius: 6, x: 0, y: 3)
                    
                    Spacer()
                }
                .padding(20)
                .frame(minWidth: 260)
                
                // 右半：当前预设的配置修改与激活详情
                VStack {
                    if let selectedId = selectedPresetId,
                       let presetIndex = configManager.presets.firstIndex(where: { $0.id == selectedId }) {
                        
                        let preset = configManager.presets[presetIndex]
                        let isActive = configManager.state.currentProvider == preset.providerId &&
                                       (!preset.isOfficial || configManager.state.isOfficial)
                        let needsUpdate = preset.isOfficial && isPresetMatchingCurrentAccount(preset) && presetNeedsUpdate(preset)
                        let isAuthJsonInvalid = preset.isOfficial && jsonValidationError(preset.authJson ?? "") != nil
                        let isButtonDisabled = (isActive && !needsUpdate) || isAuthJsonInvalid
                        
                        VStack(alignment: .leading, spacing: 20) {
                            HStack(alignment: .center) {
                                Text("预设详情")
                                    .font(.title2)
                                    .fontWeight(.bold)
                                
                                Spacer()
                                
                                // 删除预设按钮
                                Button(action: {
                                    if let idx = configManager.presets.firstIndex(where: { $0.id == preset.id }) {
                                        configManager.presets.remove(at: idx)
                                        configManager.savePresets()
                                        selectedPresetId = nil
                                    }
                                }) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "trash.fill")
                                        Text("删除预设")
                                    }
                                    .font(.body)
                                    .fontWeight(.medium)
                                    .foregroundColor(.red)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Color.red.opacity(0.1))
                                    .cornerRadius(6)
                                }
                                .buttonStyle(.plain)
                                .padding(.trailing, 8)
                                
                                Button(action: {
                                    let success = configManager.switchPreset(preset)
                                    if success {
                                        NSSound.beep()
                                    }
                                }) {
                                    HStack(spacing: 6) {
                                        Image(systemName: "bolt.fill")
                                        Text("一键应用此配置")
                                    }
                                    .font(.body)
                                    .fontWeight(.semibold)
                                    .foregroundColor(isButtonDisabled ? .secondary : .white)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(isButtonDisabled ? Color.gray.opacity(0.2) : Color.accentColor)
                                    .cornerRadius(6)
                                    .shadow(color: isButtonDisabled ? .clear : .accentColor.opacity(0.15), radius: 4)
                                }
                                .buttonStyle(.plain)
                                .disabled(isButtonDisabled)
                            }
                            Divider()
                            
                            HStack {
                                Text("预设模式")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text(preset.isOfficial ? "ChatGPT账号" : "API模式")
                                    .font(.subheadline)
                                    .fontWeight(.bold)
                                    .foregroundColor(preset.isOfficial ? .blue : .purple)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(preset.isOfficial ? Color.blue.opacity(0.1) : Color.purple.opacity(0.1))
                                    .cornerRadius(6)
                            }
                            .padding(.bottom, 6)
                            
                            ScrollView {
                                VStack(alignment: .leading, spacing: 14) {
                                    Group {
                                        Text("预设名称")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        TextField("例如: DeepSeek API", text: Binding(
                                            get: { preset.name },
                                            set: { updatePresetField(index: presetIndex, name: $0) }
                                        ))
                                        .textFieldStyle(.roundedBorder)
                                    }
                                    
                                    if !preset.isOfficial {
                                        Group {
                                            Text("服务商标识 (Provider ID)")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                            TextField("例如: deepseek 或 openai", text: Binding(
                                                get: { preset.providerId },
                                                set: { updatePresetField(index: presetIndex, providerId: $0) }
                                            ))
                                            .textFieldStyle(.roundedBorder)
                                        }
                                    }
                                    
                                    Group {
                                        Text("模型名称 (Model)")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        TextField("例如: deepseek-chat", text: Binding(
                                            get: { preset.model },
                                            set: { updatePresetField(index: presetIndex, model: $0) }
                                        ))
                                        .textFieldStyle(.roundedBorder)
                                    }
                                    
                                    if preset.isOfficial {
                                        Group {
                                            HStack {
                                                Text("auth.json 内容 (JSON 字符串)")
                                                    .font(.caption)
                                                    .foregroundColor(.secondary)
                                                Spacer()
                                                Button(action: {
                                                    showAuthJson.toggle()
                                                }) {
                                                    Image(systemName: showAuthJson ? "eye.slash" : "eye")
                                                        .foregroundColor(.secondary)
                                                }
                                                .buttonStyle(.plain)
                                            }
                                            
                                            if showAuthJson {
                                                MacCodeEditor(text: Binding(
                                                    get: { preset.authJson ?? "" },
                                                    set: { updatePresetField(index: presetIndex, authJson: $0) }
                                                ))
                                                .frame(height: 170)
                                                .padding(4)
                                                .background(Color(NSColor.controlBackgroundColor))
                                                .cornerRadius(6)
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: 6)
                                                        .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                                                )
                                                
                                                if let errorMsg = jsonValidationError(preset.authJson ?? "") {
                                                    Text("⚠️ JSON 格式错误: \(errorMsg)")
                                                        .font(.caption)
                                                        .foregroundColor(.red)
                                                        .padding(.top, 2)
                                                }
                                            } else {
                                                HStack {
                                                    Spacer()
                                                    VStack(spacing: 8) {
                                                        Image(systemName: "lock.rectangle.on.rectangle")
                                                            .font(.title2)
                                                            .foregroundColor(.secondary)
                                                        Text("auth.json 内容已隐藏")
                                                            .font(.caption)
                                                            .foregroundColor(.secondary)
                                                    }
                                                    Spacer()
                                                }
                                                .frame(height: 170)
                                                .background(Color(NSColor.controlBackgroundColor))
                                                .cornerRadius(6)
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: 6)
                                                        .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                                                )
                                            }
                                        }
                                    } else {
                                        Group {
                                            Text("接口地址 (Base URL)")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                            TextField("例如: https://api.deepseek.com/v1", text: Binding(
                                                get: { preset.baseUrl ?? "" },
                                                set: { updatePresetField(index: presetIndex, baseUrl: $0) }
                                            ))
                                            .textFieldStyle(.roundedBorder)
                                        }
                                        
                                        Group {
                                            HStack {
                                                Text("API 密钥 (API Key)")
                                                    .font(.caption)
                                                    .foregroundColor(.secondary)
                                                Spacer()
                                                Button(action: {
                                                    showApiKey.toggle()
                                                }) {
                                                    Image(systemName: showApiKey ? "eye.slash" : "eye")
                                                        .foregroundColor(.secondary)
                                                }
                                                .buttonStyle(.plain)
                                            }
                                            
                                            if showApiKey {
                                                TextField("输入您的 API 密钥", text: Binding(
                                                    get: { preset.apiKey ?? "" },
                                                    set: { updatePresetField(index: presetIndex, apiKey: $0) }
                                                ))
                                                .textFieldStyle(.roundedBorder)
                                            } else {
                                                SecureField("输入您的 API 密钥", text: Binding(
                                                    get: { preset.apiKey ?? "" },
                                                    set: { updatePresetField(index: presetIndex, apiKey: $0) }
                                                ))
                                                .textFieldStyle(.roundedBorder)
                                            }
                                        }
                                    }
                                }
                                .padding(.horizontal, 4)
                            }
                            .padding(.horizontal, -4)
                            .scrollBounceBehavior(.basedOnSize, axes: .vertical)
                        }
                        .padding(20)
                        
                    } else {
                        // 未选择预设时的欢迎提示
                        VStack(spacing: 16) {
                            Image(systemName: "slider.horizontal.3")
                                .font(.system(size: 48))
                                .foregroundColor(.secondary.opacity(0.7))
                            
                            Text("请在左侧选择一个配置预设")
                                .font(.headline)
                                .foregroundColor(.secondary)
                            
                            Text("您可以为不同的 API Key 或 ChatGPT账号配置独立卡片，实现秒级无缝切换，并保持历史对话在侧边栏永不隐藏。")
                                .font(.caption)
                                .foregroundColor(.secondary.opacity(0.8))
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 40)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(minWidth: 220)
            }
            .toolbar(.hidden)
        }
        .sheet(isPresented: $showingAddSheet) {
            // 新增预设 Sheet 弹窗
            VStack(alignment: .leading, spacing: 16) {
                Text("新增预设卡片")
                    .font(.headline)
                    .fontWeight(.bold)
                
                Divider()
                
                VStack(spacing: 10) {
                    HStack {
                        Text("预设名称")
                            .frame(width: 100, alignment: .leading)
                        TextField(newIsOfficial ? "例如: 个人账号" : "例如: Pixel API", text: $newName)
                            .textFieldStyle(.roundedBorder)
                    }
                    
                    Picker("模式类型", selection: Binding(
                        get: { newIsOfficial },
                        set: { newValue in
                            newIsOfficial = newValue
                            if newValue {
                                newProviderId = "openai"
                            } else if newProviderId == "openai" {
                                newProviderId = "custom"
                            }
                        }
                    )) {
                        Text("API模式").tag(false)
                        Text("ChatGPT账号").tag(true)
                    }
                    .pickerStyle(.radioGroup)
                    .horizontalRadioGroupLayout()
                    
                    HStack {
                        Text("服务商 ID")
                            .frame(width: 100, alignment: .leading)
                        TextField("例如: deepseek", text: $newProviderId)
                            .textFieldStyle(.roundedBorder)
                            .disabled(newIsOfficial)
                    }
                    
                    HStack {
                        Text("推荐模型")
                            .frame(width: 100, alignment: .leading)
                        TextField("例如: deepseek-chat", text: $newModel)
                            .textFieldStyle(.roundedBorder)
                    }
                    
                    if newIsOfficial {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("auth.json 内容 (JSON 字符串)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Button(action: {
                                    showNewAuthJson.toggle()
                                }) {
                                    Image(systemName: showNewAuthJson ? "eye.slash" : "eye")
                                        .foregroundColor(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                            
                            if showNewAuthJson {
                                MacCodeEditor(text: $newAuthJson)
                                    .frame(height: 170)
                                    .padding(4)
                                    .background(Color(NSColor.controlBackgroundColor))
                                    .cornerRadius(6)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                                    )
                                
                                if let errorMsg = jsonValidationError(newAuthJson) {
                                    Text("⚠️ JSON 格式错误: \(errorMsg)")
                                        .font(.caption)
                                        .foregroundColor(.red)
                                        .padding(.top, 2)
                                } else if isNewAccountIdAlreadyExists {
                                    Text("⚠️ 该账号 (Account ID) 已存在于预设列表中，请勿重复添加")
                                        .font(.caption)
                                        .foregroundColor(.red)
                                        .padding(.top, 2)
                                }
                            } else {
                                HStack {
                                    Spacer()
                                    VStack(spacing: 8) {
                                        Image(systemName: "lock.rectangle.on.rectangle")
                                            .font(.title2)
                                            .foregroundColor(.secondary)
                                        Text("auth.json 内容已隐藏")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                }
                                .frame(height: 170)
                                .background(Color(NSColor.controlBackgroundColor))
                                .cornerRadius(6)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                                )
                            }
                        }
                    } else {
                        HStack {
                            Text("接口端点")
                                .frame(width: 100, alignment: .leading)
                            TextField("https://api.deepseek.com/v1", text: $newBaseUrl)
                                .textFieldStyle(.roundedBorder)
                        }
                        
                        HStack {
                            Text("API 密钥")
                                .frame(width: 100, alignment: .leading)
                            
                            if showNewApiKey {
                                TextField("API Key", text: $newApiKey)
                                    .textFieldStyle(.roundedBorder)
                            } else {
                                SecureField("API Key", text: $newApiKey)
                                    .textFieldStyle(.roundedBorder)
                            }
                            
                            Button(action: {
                                showNewApiKey.toggle()
                            }) {
                                Image(systemName: showNewApiKey ? "eye.slash" : "eye")
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                
                Divider()
                
                HStack {
                    Spacer()
                    Button("取消") {
                        showingAddSheet = false
                    }
                    .keyboardShortcut(.cancelAction)
                    
                    Button("创建并保存") {
                        let provider = newIsOfficial ? "openai" : newProviderId
                        let preset = ProviderPreset(
                            id: UUID().uuidString,
                            name: newName,
                            isOfficial: newIsOfficial,
                            providerId: provider,
                            model: newModel,
                            baseUrl: newIsOfficial ? nil : newBaseUrl,
                            apiKey: newIsOfficial ? nil : newApiKey,
                            authJson: newIsOfficial ? newAuthJson : nil,
                            detectedBalanceProvider: nil
                        )
                        configManager.presets.append(preset)
                        configManager.savePresets()
                        selectedPresetId = preset.id
                        showingAddSheet = false
                        
                        if !newIsOfficial {
                            configManager.detectAndSaveBalanceProvider(for: preset, debounce: false)
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        newName.trimmingCharacters(in: .whitespaces).isEmpty ||
                        (newIsOfficial && (jsonValidationError(newAuthJson) != nil || isNewAccountIdAlreadyExists))
                    )
                }
            }
            .padding(20)
            .frame(width: 440)
            .onDisappear {
                resetAddSheetFields()
            }
        }
        .alert("配置导入", isPresented: $showingImportAlert) {
            Button("好", role: .cancel) { }
        } message: {
            Text(importAlertMessage)
        }
        .onAppear {
            configManager.refreshState()
        }
        .onChange(of: controlActiveState) { oldValue, newValue in
            if newValue == .key {
                configManager.refreshState()
            }
        }
        .onChange(of: selectedPresetId) { oldValue, newValue in
            showAuthJson = false
            showApiKey = false
        }
    }
    
    // MARK: - 辅助组件
    
    private func statusRow(title: String, value: String, icon: String, color: Color) -> some View {
        HStack {
            Image(systemName: icon)
                .font(.body)
                .foregroundColor(color)
                .frame(width: 20)
            
            Text(title)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.semibold)
                .foregroundColor(.primary)
                .lineLimit(1)
        }
    }
    
    // MARK: - 辅助方法
    
    private func resetAddSheetFields() {
        newName = ""
        newIsOfficial = false
        newProviderId = "custom"
        newModel = "gpt-5.5"
        newBaseUrl = ""
        newApiKey = ""
        newAuthJson = ""
        showNewAuthJson = false
        showNewApiKey = false
    }
    
    private func updatePresetField(
        index: Int,
        name: String? = nil,
        isOfficial: Bool? = nil,
        providerId: String? = nil,
        model: String? = nil,
        baseUrl: String? = nil,
        apiKey: String? = nil,
        authJson: String? = nil
    ) {
        let old = configManager.presets[index]
        
        let urlChanged = baseUrl != nil && baseUrl != old.baseUrl
        let keyChanged = apiKey != nil && apiKey != old.apiKey
        
        let updated = ProviderPreset(
            id: old.id,
            name: name ?? old.name,
            isOfficial: isOfficial ?? old.isOfficial,
            providerId: providerId ?? old.providerId,
            model: model ?? old.model,
            baseUrl: baseUrl ?? old.baseUrl,
            apiKey: apiKey ?? old.apiKey,
            authJson: authJson ?? old.authJson,
            detectedBalanceProvider: (urlChanged || keyChanged) ? nil : old.detectedBalanceProvider
        )
        configManager.presets[index] = updated
        configManager.savePresets()
        
        if urlChanged || keyChanged {
            configManager.accountQuotas[old.id] = nil // 立即重置侧边栏额度显示
            configManager.detectAndSaveBalanceProvider(for: updated, debounce: true)
        }
    }
    
    private func deletePresets(offsets: IndexSet) {
        configManager.presets.remove(atOffsets: offsets)
        configManager.savePresets()
        selectedPresetId = nil
    }
    
    // MARK: - 预设更新与校验助手
    
    private func jsonValidationError(_ string: String) -> String? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        guard let data = trimmed.data(using: .utf8) else {
            return "编码非 UTF-8"
        }
        do {
            _ = try JSONSerialization.jsonObject(with: data, options: [])
            return nil
        } catch {
            return error.localizedDescription
        }
    }
    
    private func getAccountIdFromAuthJson(_ jsonStr: String?) -> String? {
        guard let data = jsonStr?.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
              let tokens = dict["tokens"] as? [String: Any],
              let accountId = tokens["account_id"] as? String else {
            return nil
        }
        return accountId
    }
    
    private func isPresetMatchingCurrentAccount(_ preset: ProviderPreset) -> Bool {
        guard preset.isOfficial else { return false }
        guard let accountId = getAccountIdFromAuthJson(preset.authJson),
              let currentAccountId = configManager.state.currentAccountId else {
            return false
        }
        return accountId == currentAccountId
    }
    
    private func presetNeedsUpdate(_ preset: ProviderPreset) -> Bool {
        guard preset.isOfficial else { return false }
        guard let authJsonData = preset.authJson?.data(using: .utf8),
              let presetDict = try? JSONSerialization.jsonObject(with: authJsonData, options: []) as? [String: Any] else {
            return true
        }
        
        let presetTokens = presetDict["tokens"] as? [String: Any] ?? [:]
        let presetIdToken = presetTokens["id_token"] as? String ?? ""
        let presetAccessToken = presetTokens["access_token"] as? String ?? ""
        let presetRefreshToken = presetTokens["refresh_token"] as? String ?? ""
        let presetLastRefresh = presetDict["last_refresh"] != nil ? "\(presetDict["last_refresh"]!)" : ""
        
        let currentIdToken = configManager.state.currentIdToken ?? ""
        let currentAccessToken = configManager.state.currentAccessToken ?? ""
        let currentRefreshToken = configManager.state.currentRefreshToken ?? ""
        let currentLastRefresh = configManager.state.currentLastRefresh ?? ""
        
        return presetIdToken != currentIdToken ||
               presetAccessToken != currentAccessToken ||
               presetRefreshToken != currentRefreshToken ||
               presetLastRefresh != currentLastRefresh
    }
    
    private var chatGptPresetExists: Bool {
        guard configManager.state.isOfficial,
              let currentAccountId = configManager.state.currentAccountId else {
            return true
        }
        return configManager.presets.contains { preset in
            guard preset.isOfficial else { return false }
            return getAccountIdFromAuthJson(preset.authJson) == currentAccountId
        }
    }
    
    private var apiPresetExists: Bool {
        guard !configManager.state.isOfficial,
              let currentApiKey = configManager.state.currentApiKey else {
            return true
        }
        return configManager.presets.contains { preset in
            !preset.isOfficial && preset.apiKey == currentApiKey
        }
    }
    
    private var isNewAccountIdAlreadyExists: Bool {
        guard newIsOfficial,
              let newAccountId = getAccountIdFromAuthJson(newAuthJson) else {
            return false
        }
        return configManager.presets.contains { preset in
            guard preset.isOfficial else { return false }
            return getAccountIdFromAuthJson(preset.authJson) == newAccountId
        }
    }
}

/// 专为 macOS 编写的 JSON / 代码编辑器，支持横向和纵向滚动，禁用自动换行，并关闭引号的自动替换。
struct MacCodeEditor: NSViewRepresentable {
    @Binding var text: String
    
    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        
        let contentSize = scrollView.contentSize
        
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: contentSize.width, height: contentSize.height))
        textView.minSize = NSSize(width: 0.0, height: contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width, .height]
        
        // 允许横向滚动且不换行
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        
        // 设置等宽字体
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.isRichText = false
        textView.importsGraphics = false
        
        // 关键：关闭系统级别的引号与破折号智能替换，避免输入双引号时报错
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.delegate = context.coordinator
        
        scrollView.documentView = textView
        return scrollView
    }
    
    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MacCodeEditor
        
        init(_ parent: MacCodeEditor) {
            self.parent = parent
        }
        
        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            self.parent.text = textView.string
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(ConfigManager())
        .environmentObject(SyncEngine())
}
