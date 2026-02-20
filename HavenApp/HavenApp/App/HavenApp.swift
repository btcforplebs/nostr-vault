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
        .defaultSize(width: 600, height: 700)
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
    
    @State private var isVisible = false
    
    var body: some View {
        ZStack {
            // Main Content layer
            Group {
                if !configService.config.hasCompletedSetup {
                    VStack(spacing: 24) {
                        Image(systemName: "server.rack")
                            .font(.system(size: 56, weight: .light))
                            .foregroundColor(.havenPurple)
                            .offset(y: isVisible ? 0 : 20)
                            .opacity(isVisible ? 1 : 0)
                            .animation(.spring(response: 0.6, dampingFraction: 0.7).delay(0.1), value: isVisible)
                        
                        VStack(spacing: 8) {
                            Text("Welcome to Haven")
                                .font(.system(.title2, design: .rounded).bold())
                                .offset(y: isVisible ? 0 : 15)
                                .opacity(isVisible ? 1 : 0)
                                .animation(.spring(response: 0.6, dampingFraction: 0.7).delay(0.2), value: isVisible)
                            
                            Text("Please complete the setup to start your relay.")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal)
                                .offset(y: isVisible ? 0 : 10)
                                .opacity(isVisible ? 1 : 0)
                                .animation(.spring(response: 0.6, dampingFraction: 0.7).delay(0.3), value: isVisible)
                        }
                        
                        Button("Start Setup") {
                            openWindow(id: "setup")
                            NSApp.activate(ignoringOtherApps: true)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.havenPurple)
                        .controlSize(.large)
                        .scaleEffect(isVisible ? 1 : 0.9)
                        .opacity(isVisible ? 1 : 0)
                        .animation(.spring(response: 0.5, dampingFraction: 0.6).delay(0.4), value: isVisible)
                        .padding(.top, 8)
                        
                        Button("Quit") {
                            NSApp.terminate(nil)
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.secondary)
                        .font(.caption)
                        .opacity(isVisible ? 1 : 0)
                        .animation(.easeIn(duration: 0.3).delay(0.6), value: isVisible)
                    }
                    .padding(40)
                    .onAppear {
                        isVisible = true
                    }
                } else {
                    MenuBarView(configService: configService, relayManager: relayManager)
                        .onAppear {
                            // Auto-start relay if setup is done and we are idle
                            if configService.config.hasCompletedSetup && relayManager.state == .idle {
                                #if DEBUG
                                print("Auto-starting relay on launch...")
                                #endif
                                relayManager.startRelay(config: configService.config)
                            }
                        }
                }
            }
            .disabled(relayManager.showProcessKillAlert)

            // Custom Error Overlay
            if relayManager.showProcessKillAlert {
                Color.black
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

                        Text("A previous Haven process is still running. Run the following command in Terminal to stop it, then relaunch the app.")
                            .multilineTextAlignment(.center)
                            .foregroundColor(.white.opacity(0.9))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: 8) {
                        Text("pkill -9 haven")
                            .font(.system(size: 14, weight: .medium, design: .monospaced))
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity)
                            .background(Color.white.opacity(0.1))
                            .cornerRadius(6)

                        Button(action: {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("pkill -9 haven", forType: .string)
                        }) {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 14))
                                .foregroundColor(.white)
                                .frame(width: 36, height: 36)
                                .background(Color.orange)
                                .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                        .help("Copy to clipboard")
                    }


                }
                .padding(30)
                .frame(width: 400)
                .background(Color.black)
                .cornerRadius(16)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(width: 480, height: 640)
    }
}

