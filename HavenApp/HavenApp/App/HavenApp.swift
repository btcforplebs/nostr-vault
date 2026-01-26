import SwiftUI

@main
struct HavenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    // Use shared instances directly, but observe them if needed for top-level updates.
    // However, ObservableObjects in environment usually suffice.
    @StateObject private var configService = ConfigService.shared
    @StateObject private var relayManager = RelayProcessManager.shared
    @StateObject private var nostrService = NostrService.shared
    @StateObject private var statsService = StatsService()
    
    var body: some Scene {
        MenuBarExtra("Haven", systemImage: "server.rack") {
            MenuBarContent(configService: configService, relayManager: relayManager)
                .environmentObject(configService)
                .environmentObject(relayManager)
                .environmentObject(nostrService)
                .environmentObject(statsService)
                .alert("Startup Error", isPresented: $relayManager.showProcessKillAlert) {
                    Button("Copy Command") {
                        let pasteboard = NSPasteboard.general
                        let success = pasteboard.setString("pkill -9 haven", forType: .string)
                        print("DEBUG: Copy Command result: \(success)")
                        
                        // Async dismissal to avoid state conflict during button action
                        DispatchQueue.main.async {
                            relayManager.showProcessKillAlert = false
                        }
                    }
                    Button("OK", role: .cancel) { }
                } message: {
                    Text("HAVEN's last shutdown was done incorrectly, please open the terminal and run 'pkill -9 haven' to clear errors and start the relay")
                }
        }
        .menuBarExtraStyle(.window)
        
        // Window for Help > Welcome Window
        // This is separate from the auto-launch window managed by AppDelegate
        Window("Welcome to Haven", id: "welcome") {
            WelcomeWindowView()
                .environmentObject(configService)
                .environmentObject(relayManager)
                .environmentObject(nostrService)
                .environmentObject(statsService)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        
        Settings {
            SettingsView()
                .environmentObject(configService)
                .environmentObject(relayManager)
                .environmentObject(nostrService)
                .environmentObject(statsService)
        }
        
        Window("Haven", id: "viewer-window") {
            MenuBarView(configService: configService, relayManager: relayManager, isPoppedOut: true)
                .environmentObject(configService)
                .environmentObject(relayManager)
                .environmentObject(nostrService)
                .environmentObject(statsService)
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
                    .onAppear {
                        // Auto-start relay if setup is done and we are idle
                        if configService.config.hasCompletedSetup && relayManager.state == .idle {
                            print("Auto-starting relay on launch...")
                            relayManager.startRelay(config: configService.config)
                        }
                    }
            }
        }
        .frame(width: 480, height: 640)
    }
}
