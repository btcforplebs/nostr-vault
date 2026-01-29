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
        ZStack {
            // Main Content layer
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
            .disabled(relayManager.showProcessKillAlert) // Disable main content when error is shown
            .blur(radius: relayManager.showProcessKillAlert ? 2 : 0)
            
            // Custom Error Overlay
            if relayManager.showProcessKillAlert {
                Color.black.opacity(0.6)
                    .ignoresSafeArea()
                    .onTapGesture {
                        // Optional: allow dismissal by clicking background? No, force user action.
                    }
                
                VStack(spacing: 20) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 48))
                        .foregroundColor(.orange)
                    
                    VStack(spacing: 6) {
                        Text("Startup Error")
                            .font(.title2.bold())
                            .foregroundColor(.white)
                        
                        Text("Haven didn't shut down correctly and needs a quick fix.")
                            .multilineTextAlignment(.center)
                            .foregroundColor(.white.opacity(0.9))
                    }
                    
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top, spacing: 10) {
                            Text("1.")
                                .bold()
                                .foregroundColor(.white)
                            Text("Press **Command + Space** to open Spotlight.")
                                .foregroundColor(.white.opacity(0.9))
                        }
                        
                        HStack(alignment: .top, spacing: 10) {
                            Text("2.")
                                .bold()
                                .foregroundColor(.white)
                            Text("Type \"Terminal\" and press Enter.")
                                .foregroundColor(.white.opacity(0.9))
                        }
                        
                        HStack(alignment: .top, spacing: 10) {
                            Text("3.")
                                .bold()
                                .foregroundColor(.white)
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Click **Copy Command** below, paste it into the Terminal window, and press Enter.")
                                    .foregroundColor(.white.opacity(0.9))
                                    .fixedSize(horizontal: false, vertical: true)
                                
                                Text("pkill -9 haven")
                                    .font(.system(.body, design: .monospaced))
                                    .padding(8)
                                    .background(Color.black.opacity(0.3))
                                    .cornerRadius(4)
                                    .foregroundColor(.green)
                            }
                        }
                    }
                    .font(.system(size: 13))
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.1))
                    .cornerRadius(8)
                    
                    HStack(spacing: 12) {
                        CopyCommandButton()
                        
                        Button(action: {
                            relayManager.showProcessKillAlert = false
                        }) {
                            Text("Close")
                                .font(.headline)
                                .foregroundColor(.white)
                                .frame(width: 80, height: 32)
                                .background(Color.white.opacity(0.2))
                                .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(30)
                .frame(width: 440)
                .background(Color(NSColor.windowBackgroundColor).opacity(0.98))
                .cornerRadius(16)
                .shadow(radius: 20)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(width: 480, height: 640)
    }
}

struct CopyCommandButton: View {
    @State private var isCopied = false
    
    var body: some View {
        Button(action: {
            PasteboardHelper.copyToClipboard("pkill -9 haven")
            withAnimation {
                isCopied = true
            }
            
            // Revert back to "Copy" after 2 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                withAnimation {
                    isCopied = false
                }
            }
        }) {
            HStack(spacing: 6) {
                Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                Text(isCopied ? "Copied!" : "Copy Command")
            }
            .font(.headline)
            .foregroundColor(.white)
            .frame(width: 160, height: 32)
            .background(isCopied ? Color.green : Color.havenPurple)
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }
}

// Helper subclass for Pasteboard operations ensuring main thread execution and persistence
class PasteboardHelper {
    static func copyToClipboard(_ text: String) {
        // Ensure we are on main thread for UI/Pasteboard operations
        if Thread.isMainThread {
            copy(text)
        } else {
            DispatchQueue.main.async {
                copy(text)
            }
        }
    }
    
    private static func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let success = pasteboard.setString(text, forType: .string)
        if !success {
            print("ERROR: PasteboardHelper failed to set string: \(text)")
        } else {
            print("DEBUG: PasteboardHelper wrote to clipboard: \(text)")
        }
    }
}
