import SwiftUI

@main
struct HavenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    // Use shared instances directly, but observe them if needed for top-level updates.
    // However, ObservableObjects in environment usually suffice.
    @StateObject private var configService = ConfigService.shared
    @StateObject private var relayManager = RelayProcessManager.shared
    @StateObject private var nostrService = NostrService.shared
    
    var body: some Scene {
        MenuBarExtra("Haven", systemImage: "server.rack") {
            MenuBarContent(configService: configService, relayManager: relayManager)
                .environmentObject(configService)
                .environmentObject(relayManager)
                .environmentObject(nostrService)
        }
        .menuBarExtraStyle(.window)
        
        // Window for Help > Welcome Window
        // This is separate from the auto-launch window managed by AppDelegate
        Window("Welcome to Haven", id: "welcome") {
            WelcomeWindowView()
                .environmentObject(configService)
                .environmentObject(relayManager)
                .environmentObject(nostrService)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        
        Settings {
            SettingsView()
                .environmentObject(configService)
                .environmentObject(relayManager)
                .environmentObject(nostrService)
        }
        
        Window("Haven", id: "viewer-window") {
            MenuBarView(configService: configService, relayManager: relayManager, isPoppedOut: true)
                .environmentObject(configService)
                .environmentObject(relayManager)
                .environmentObject(nostrService)
                .frame(minWidth: 600, minHeight: 500)
        }
        .defaultSize(width: 900, height: 700)
    }
}

// Helper view to handle menu bar content
struct MenuBarContent: View {
    @ObservedObject var configService: ConfigService
    @ObservedObject var relayManager: RelayProcessManager
    
    var body: some View {
        Group {
            if !configService.config.hasCompletedSetup {
                SetupWizardView {
                    Task { @MainActor in
                        relayManager.startRelay(config: configService.config)
                    }
                }
            } else {
                MenuBarView(configService: configService, relayManager: relayManager)
            }
        }
        .frame(width: 480, height: 640)
    }
}
