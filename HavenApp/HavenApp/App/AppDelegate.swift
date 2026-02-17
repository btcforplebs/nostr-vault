import SwiftUI

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    // Shared services are accessed directly from their static shared properties
    // We don't need to store them here as properties if we use singletons consistently
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Kill any orphaned haven process left over from a previous app session
        RelayProcessManager.shared.killOrphanedProcess()

        // Check if setup is complete
        // We use the shared ConfigService which loads from disk on init
        if !ConfigService.shared.config.hasCompletedSetup {
            openWelcomeWindow()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Ensure child processes are killed cleanly
        print("Application terminating, stopping relay...")
        RelayProcessManager.shared.stopRelay()
        // Give it time to SIGTERM -> wait -> SIGKILL if needed
        Thread.sleep(forTimeInterval: 1.0)
    }
    
    // Keep a reference to the window prevent it from being deallocated immediately
    private var welcomeWindow: NSWindow?
    
    func openWelcomeWindow() {
        // Create the window
        // Use a larger size for the SetupWizard
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 650),
            styleMask: [.titled, .closable, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false
        )
        
        window.center()
        window.setFrameAutosaveName("Haven Setup Window")
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = .windowBackgroundColor
        
        // Prepare the content view with shared environment objects
        let contentView = SetupWizardView { [weak window] in
            // On complete:
            print("Setup complete, starting relay from AppDelegate...")
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
}
