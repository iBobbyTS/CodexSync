import Testing
import Foundation
@testable import CodexSync

struct CodexSyncTests {

    @Test func testTomlEditorCleaning() async throws {
        let inputToml = """
        model_provider = "openai"
        model = "gpt-5.5"
        
        [model_providers.openai]
        name = "OpenAI"
        base_url = "https://api.openai.com/v1"
        
        [model_providers.deepseek]
        name = "DeepSeek"
        base_url = "https://api.deepseek.com/v1"
        experimental_bearer_token = "sk-deepseek"
        
        [model_providers.anthropic]
        name = "Anthropic"
        base_url = "https://api.anthropic.com/v1"
        
        [unrelated_section]
        key = "value"
        """
        
        // 1. 测试只保留 deepseek 的情况
        var editor1 = TomlEditor(text: inputToml)
        editor1.removeAllModelProvidersExcept(activeProviderId: "deepseek")
        let output1 = editor1.toString()
        
        #expect(!output1.contains("[model_providers.openai]"))
        #expect(output1.contains("[model_providers.deepseek]"))
        #expect(!output1.contains("[model_providers.anthropic]"))
        #expect(output1.contains("[unrelated_section]"))
        #expect(output1.contains("model_provider = \"openai\""))
        
        // 2. 测试全部清除的情况（官方网页模式）
        var editor2 = TomlEditor(text: inputToml)
        editor2.removeAllModelProvidersExcept(activeProviderId: nil)
        let output2 = editor2.toString()
        
        #expect(!output2.contains("[model_providers.openai]"))
        #expect(!output2.contains("[model_providers.deepseek]"))
        #expect(!output2.contains("[model_providers.anthropic]"))
        #expect(output2.contains("[unrelated_section]"))
        #expect(output2.contains("model_provider = \"openai\""))
    }

    @Test func testConfigManagerPresetSwitchingIsolation() async throws {
        // 1. 创建临时沙盒环境
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }
        
        let codexHome = tempDir.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        
        let configURL = codexHome.appendingPathComponent("config.toml")
        let authURL = codexHome.appendingPathComponent("auth.json")
        let presetsURL = tempDir.appendingPathComponent("presets.json")
        
        // 写入初始的 config.toml 和 auth.json
        let initialToml = """
        model_provider = "openai"
        model = "gpt-5.5"
        
        [model_providers.openai]
        name = "OpenAI"
        base_url = "https://api.openai.com/v1"
        """
        try initialToml.write(to: configURL, atomically: true, encoding: .utf8)
        
        let initialAuth = "{\"auth_mode\": \"chatgpt\", \"tokens\": {\"access_token\": \"fake-token\", \"account_id\": \"fake-acc\"}}"
        try initialAuth.write(to: authURL, atomically: true, encoding: .utf8)
        
        // 2. 初始化 ConfigManager
        let manager = ConfigManager(codexHome: codexHome, presetsURL: presetsURL)
        
        // 3. 构造并切换至一个第三方 API 预设
        let deepseekPreset = ProviderPreset(
            id: "test-deepseek-id",
            name: "DeepSeek API",
            isOfficial: false,
            providerId: "deepseek",
            model: "deepseek-chat",
            baseUrl: "https://api.deepseek.com/v1",
            apiKey: "sk-deepseek-key",
            authJson: nil
        )
        
        let switchResult1 = manager.switchPreset(deepseekPreset)
        #expect(switchResult1)
        
        // 4. 检验切换至 API 预设后的文件是否干净无残留
        let tomlText1 = try String(contentsOf: configURL, encoding: .utf8)
        // 应当包含 deepseek 的配置
        #expect(tomlText1.contains("[model_providers.deepseek]"))
        #expect(tomlText1.contains("experimental_bearer_token = \"sk-deepseek-key\""))
        // 绝对不能有 model_providers.openai 这一多余段
        #expect(!tomlText1.contains("[model_providers.openai]"))
        
        let authText1 = try String(contentsOf: authURL, encoding: .utf8)
        // 绝对不能含有 chatgpt 网页登录态 tokens 残留
        #expect(!authText1.contains("chatgpt"))
        #expect(!authText1.contains("fake-token"))
        // 必须被重写并包含 bearer_only
        #expect(authText1.contains("bearer_only"))
        
        // 5. 构造并切换回官方网页模式预设
        let officialPreset = ProviderPreset(
            id: "test-official-id",
            name: "ChatGPT官方账号",
            isOfficial: true,
            providerId: "openai",
            model: "gpt-5.5",
            baseUrl: nil,
            apiKey: nil,
            authJson: "{\"auth_mode\": \"chatgpt\", \"tokens\": {\"access_token\": \"new-official-token\"}}"
        )
        
        let switchResult2 = manager.switchPreset(officialPreset)
        #expect(switchResult2)
        
        // 6. 检验切换回官方预设后，第三方配置是否被彻底、干净地清理
        let tomlText2 = try String(contentsOf: configURL, encoding: .utf8)
        // 绝对不应再有 model_providers.deepseek 等残留段
        #expect(!tomlText2.contains("[model_providers.deepseek]"))
        #expect(!tomlText2.contains("sk-deepseek-key"))
        
        let authText2 = try String(contentsOf: authURL, encoding: .utf8)
        // 官方 auth 应当被正确覆写，且不应再有 bearer_only 的残留
        #expect(authText2.contains("chatgpt"))
        #expect(authText2.contains("new-official-token"))
        #expect(!authText2.contains("bearer_only"))
    }

}
