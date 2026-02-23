import SwiftUI
#if os(macOS)
import AppKit
#endif

@MainActor
class AppDelegate: NSObject, ObservableObject {
    #if os(macOS)
    // Keep a reference to the window prevent it from being deallocated immediately
    private var welcomeWindow: NSWindow?
    #endif

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        #if os(macOS)
        // Check if setup is complete
        if !ConfigService.shared.config.hasCompletedSetup {
            openWelcomeWindow()
        }
        #endif
    }

    #if os(macOS)
    @MainActor
    func applicationWillTerminate(_ notification: Notification) {
        // Ensure child processes are killed cleanly
        #if DEBUG
        print("Application terminating, stopping relay...")
        #endif
        RelayProcessManager.shared.stopRelay()
        // Give it time to SIGTERM -> wait -> SIGKILL if needed
        Thread.sleep(forTimeInterval: 1.0)
    }
    
    func openWelcomeWindow() {
        // Create the window
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 700),
            styleMask: [.titled, .closable, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false
        )
        
        window.center()
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = .windowBackgroundColor
        
        // Prepare the content view with shared environment objects
        let contentView = SetupWizardView { [weak window] in
            // On complete:
            #if DEBUG
            print("Setup complete, starting relay from AppDelegate...")
            #endif
            Task { @MainActor in
                RelayProcessManager.shared.startRelay(config: ConfigService.shared.config)
            }
            window?.close()
        }
        .environmentObject(ConfigService.shared)
        .environmentObject(RelayProcessManager.shared)
        .environmentObject(NostrService.shared)
        .environmentObject(StatsService.shared)
        .frame(minWidth: 500, minHeight: 650)
        
        window.contentView = NSHostingView(rootView: contentView)
        
        // Show the window
        window.makeKeyAndOrderFront(nil)
        window.level = .normal // Standard window level
        NSApp.activate(ignoringOtherApps: true)
        
        self.welcomeWindow = window
    }
    #endif
}

#if os(macOS)
extension AppDelegate: NSApplicationDelegate {}
#endif
