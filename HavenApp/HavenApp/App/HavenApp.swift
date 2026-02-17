import SwiftUI

@main
struct HavenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    // Use shared instances directly, but observe them if needed for top-level updates.
    // However, ObservableObjects in environment usually suffice.
    @StateObject private var configService = ConfigService.shared
    @StateObject private var relayManager = RelayProcessManager.shared
    @StateObject private var nostrService = NostrService.shared
    @StateObject private var statsService = StatsService.shared
    
    var body: some Scene {
        MenuBarExtra("Haven", systemImage: "server.rack") {
            MenuBarContent(configService: configService, relayManager: relayManager)
                .environmentObject(configService)
                .environmentObject(relayManager)
                .environmentObject(nostrService)
                .environmentObject(statsService)
                .environmentObject(nostrService)
                .environmentObject(statsService)
        }
        .menuBarExtraStyle(.window)
        
        // Window for Setup / Welcome
        Window("Haven Setup", id: "setup") {
            SetupWizardView {
                // On complete, we can dismiss this window.
                // However, we can't easily dismiss from here without a binding or environment.
                // We'll handle dismissal within SetupWizardView or a wrapper.
                // For now, let's just ensure the config is updated which updates the menu bar.
                Task { @MainActor in
                    relayManager.startRelay(config: configService.config)
                    // The view inside will handle closing itself
                }
            }
            .environmentObject(configService)
            .environmentObject(relayManager)
            .environmentObject(nostrService)
            .environmentObject(statsService)
            .frame(minWidth: 500, minHeight: 650)
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
    @Environment(\.openWindow) var openWindow
    
    var body: some View {
        ZStack {
            // Main Content layer
            Group {
                if !configService.config.hasCompletedSetup {
                    VStack(spacing: 20) {
                        Image(systemName: "server.rack")
                            .font(.system(size: 48))
                            .foregroundColor(.havenPurple)
                        
                        Text("Welcome to Haven")
                            .font(.title3.bold())
                        
                        Text("Please complete the setup to start your relay.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                        
                        Button("Start Setup") {
                            openWindow(id: "setup")
                            NSApp.activate(ignoringOtherApps: true)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.havenPurple)
                        .controlSize(.large)
                        
                        Button("Quit") {
                            NSApp.terminate(nil)
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.secondary)
                        .font(.caption)
                    }
                    .padding(30)
                    .padding(30)
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
            .disabled(relayManager.showProcessKillAlert) // Disable main content when error is shown
            .blur(radius: relayManager.showProcessKillAlert ? 2 : 0)
            
            // Custom Error Overlay
            if relayManager.showProcessKillAlert {
                Color.black.opacity(0.6)
                    .ignoresSafeArea()
                    .onTapGesture { }

                VStack(spacing: 20) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 48))
                        .foregroundColor(.orange)

                    VStack(spacing: 6) {
                        Text("Startup Error")
                            .font(.title2.bold())
                            .foregroundColor(.white)

                        Text("Haven didn't shut down correctly. Tap below to fix it automatically.")
                            .multilineTextAlignment(.center)
                            .foregroundColor(.white.opacity(0.9))
                    }

                    HStack(spacing: 12) {
                        Button(action: {
                            relayManager.forceCleanAndRestart()
                        }) {
                            Text("Fix & Restart")
                                .font(.headline)
                                .foregroundColor(.white)
                                .frame(width: 140, height: 36)
                                .background(Color.orange)
                                .cornerRadius(8)
                        }
                        .buttonStyle(.plain)

                        Button(action: {
                            relayManager.showProcessKillAlert = false
                        }) {
                            Text("Close")
                                .font(.headline)
                                .foregroundColor(.white)
                                .frame(width: 80, height: 36)
                                .background(Color.white.opacity(0.2))
                                .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(30)
                .frame(width: 400)
                .background(Color(NSColor.windowBackgroundColor).opacity(0.98))
                .cornerRadius(16)
                .shadow(radius: 20)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(width: 480, height: 640)
    }
}

