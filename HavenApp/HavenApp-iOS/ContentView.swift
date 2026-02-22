import SwiftUI
import UIKit

// MARK: - iOS ContentView

struct ContentView: View {
    @EnvironmentObject var configService: ConfigService
    @EnvironmentObject var relayManager: RelayProcessManager
    @StateObject private var nostrService = NostrService.shared
    @StateObject private var statsService = StatsService.shared
    @StateObject private var feedService = FeedService.shared

    @State private var selectedTab = 0

    var body: some View {
        Group {
            if !configService.config.hasCompletedSetup {
                SetupWizardView {
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
                    .tabItem { Label("Dashboard", systemImage: "gauge") }
                    .tag(0)

                    // Following Feed Tab
                    FeedView()
                        .tabItem {
                            Label("Feed", systemImage: "person.2.wave.2")
                        }
                        .tag(1)

                    // Viewer Tab (Notes & Media stored in local relay)
                    NavigationView {
                        ViewerView()
                            .navigationTitle("Viewer")
                            .navigationBarTitleDisplayMode(.inline)
                    }
                    .tabItem { Label("Viewer", systemImage: "doc.text.image") }
                    .tag(2)

                    // Settings Tab
                    NavigationView {
                        SettingsView()
                            .navigationTitle("Settings")
                            .navigationBarTitleDisplayMode(.inline)
                    }
                    .tabItem { Label("Settings", systemImage: "gearshape") }
                    .tag(3)
                }
                .tint(.havenPurple)
                .onAppear {
                    if configService.config.hasCompletedSetup && relayManager.state == .idle {
                        relayManager.startRelay(config: configService.config)
                    }
                }
                .onChange(of: selectedTab) { tab in
                    if tab == 1 { feedService.markViewed() }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .havenOpenViewer)) { _ in
            selectedTab = 2 // Viewer tab (shifted by Feed tab)
        }
        .onReceive(NotificationCenter.default.publisher(for: .havenOpenFeed)) { _ in
            selectedTab = 1 // Feed tab
        }
    }
}

// MARK: - AppState for iOS

@MainActor
class AppState: ObservableObject {
    static let shared = AppState()
    @Published var isOnboarded = false
    @Published var selectedTab = 0
    private init() {}
}
