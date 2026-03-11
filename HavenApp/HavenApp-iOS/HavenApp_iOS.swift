import SwiftUI

// NOTE: @main is declared in AppDelegate.swift (UIKit lifecycle).
// This struct provides the SwiftUI scene body but AppDelegate + SceneDelegate
// control the actual app lifecycle and window setup.
struct HavenApp_iOSApp: App {
    @StateObject private var configService = ConfigService.shared
    @StateObject private var relayManager = RelayProcessManager.shared
    @StateObject private var nostrService = NostrService.shared
    @StateObject private var statsService = StatsService.shared
    @StateObject private var appState = AppState.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(configService)
                .environmentObject(relayManager)
                .environmentObject(nostrService)
                .environmentObject(statsService)
                .environmentObject(appState)
                .preferredColorScheme(.dark)
        }
    }
}
