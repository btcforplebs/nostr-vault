import SwiftUI
import UIKit

// MARK: - iOS ContentView
// This is the main entry point for the iOS app
// It provides tab-based navigation instead of menu bar

struct ContentView: View {
    @EnvironmentObject var configService: ConfigService
    @EnvironmentObject var relayManager: RelayProcessManager
    @StateObject private var nostrService = NostrService.shared
    @StateObject private var statsService = StatsService.shared
    
    @State private var selectedTab = 0
    
    var body: some View {
        Group {
            if !configService.config.hasCompletedSetup {
                SetupWizardView {
                    // Start relay on complete
                    relayManager.startRelay(config: configService.config)
                }
            } else {
                TabView(selection: $selectedTab) {
                    // Dashboard Tab
                    NavigationView {
                        DashboardView()
                            .navigationTitle("Dashboard")
                            .navigationBarTitleDisplayMode(.inline)
                    }
                    .tabItem {
                        Label("Dashboard", systemImage: "gauge")
                    }
                    .tag(0)

                    // Viewer Tab (Notes & Media)
                    NavigationView {
                        ViewerView()
                            .navigationTitle("Viewer")
                            .navigationBarTitleDisplayMode(.inline)
                    }
                    .tabItem {
                        Label("Viewer", systemImage: "doc.text.image")
                    }
                    .tag(1)

                    // Settings Tab
                    NavigationView {
                        SettingsView()
                            .navigationTitle("Settings")
                            .navigationBarTitleDisplayMode(.inline)
                    }
                    .tabItem {
                        Label("Settings", systemImage: "gearshape")
                    }
                    .tag(2)
                }
                .tint(.havenPurple)
                .onAppear {
                    // Auto-start relay if setup is complete
                    if configService.config.hasCompletedSetup && relayManager.state == .idle {
                        relayManager.startRelay(config: configService.config)
                    }
                }
            }
        }
    }
}

// MARK: - AppState for iOS
// Provides shared state across the app

@MainActor
class AppState: ObservableObject {
    static let shared = AppState()
    
    @Published var isOnboarded = false
    @Published var selectedTab = 0
    
    private init() {}
}

