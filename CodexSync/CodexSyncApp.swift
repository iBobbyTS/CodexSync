import SwiftUI

@main
struct CodexSyncApp: App {
    @StateObject private var configManager = ConfigManager()
    @StateObject private var syncEngine = SyncEngine()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(configManager)
                .environmentObject(syncEngine)
                .frame(minWidth: 500, minHeight: 400)
        }
        .windowStyle(.hiddenTitleBar)
    }
}
