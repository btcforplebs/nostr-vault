import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    // Shared services are accessed directly from their static shared properties
    // We don't need to store them here as properties if we use singletons consistently
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Check if setup is complete
        // We use the shared ConfigService which loads from disk on init
        if !ConfigService.shared.config.hasCompletedSetup {
            openWelcomeWindow()
        }
    }
    
    // Keep a reference to the window prevent it from being deallocated immediately
    private var welcomeWindow: NSWindow?
    
    func openWelcomeWindow() {
        // Create the window
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 480),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        
        window.center()
        window.setFrameAutosaveName("Welcome Window")
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = .windowBackgroundColor
        
        // Prepare the content view with shared environment objects
        // We need to inject the services so the view can access them
        let contentView = WelcomeWindowView(onDismiss: { [weak window] in
            window?.close()
        })
        .environmentObject(ConfigService.shared)
        .environmentObject(RelayProcessManager.shared)
        .environmentObject(NostrService.shared)
        
        window.contentView = NSHostingView(rootView: contentView)
        
        // Show the window
        window.makeKeyAndOrderFront(nil)
        window.level = .floating // Keep on top
        NSApp.activate(ignoringOtherApps: true)
        
        self.welcomeWindow = window
    }
}
