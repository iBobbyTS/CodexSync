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
                .frame(minWidth: 1000, idealWidth: 900, minHeight: 520, idealHeight: 600)
        }
        .windowStyle(.hiddenTitleBar)
    }
}
