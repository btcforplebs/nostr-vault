import SwiftUI
import UIKit

// MARK: - iOS ContentView

struct ContentView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
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
                if horizontalSizeClass == .regular {
                    iPadSidebarView(selectedTab: $selectedTab)
                } else {
                    iPhoneTabView(selectedTab: $selectedTab)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .havenOpenViewer)) { _ in
            selectedTab = 3 // Relay tab
        }
        .onReceive(NotificationCenter.default.publisher(for: .havenOpenFeed)) { _ in
            selectedTab = 0 // Feed tab
        }
    }
}

// MARK: - iPad Sidebar View

struct iPadSidebarView: View {
    @Binding var selectedTab: Int
    @EnvironmentObject var configService: ConfigService
    @EnvironmentObject var relayManager: RelayProcessManager
    @StateObject private var nostrService = NostrService.shared
    @StateObject private var feedService = FeedService.shared

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(
                get: { selectedTab },
                set: { if let val = $0 { selectedTab = val } }
            )) {
                NavigationLink(value: 0) {
                    Label("Feed", systemImage: "person.2.wave.2")
                }
                NavigationLink(value: 1) {
                    Label("Search", systemImage: "magnifyingglass")
                }
                NavigationLink(value: 2) {
                    Label("Profile", systemImage: "person.crop.circle")
                }
                NavigationLink(value: 3) {
                    Label("Relay", systemImage: "doc.text.image")
                }
                NavigationLink(value: 4) {
                    Label("Settings", systemImage: "gearshape")
                }
            }
            .navigationTitle("Haven")
        } detail: {
            switch selectedTab {
            case 0:
                FeedView()
            case 1:
                NavigationView {
                    SearchView()
                        .navigationTitle("Search")
                        .navigationBarTitleDisplayMode(.inline)
                }
                .navigationViewStyle(.stack)
            case 2:
                NavigationView {
                    ProfileView(pubkey: nostrService.ownerHexPubkey, embeddedInNavigation: true)
                        .navigationTitle("Profile")
                        .navigationBarTitleDisplayMode(.inline)
                }
                .navigationViewStyle(.stack)
            case 3:
                NavigationView {
                    ViewerView()
                        .navigationTitle("Relay")
                        .navigationBarTitleDisplayMode(.inline)
                }
                .navigationViewStyle(.stack)
            case 4:
                NavigationView {
                    SettingsView()
                        .navigationTitle("Settings")
                        .navigationBarTitleDisplayMode(.inline)
                }
                .navigationViewStyle(.stack)
            default:
                FeedView()
            }
        }
        .onAppear {
            if configService.config.hasCompletedSetup && relayManager.state == .idle {
                relayManager.startRelay(config: configService.config)
            }
        }
        .onChange(of: relayManager.state) { _, newState in
            if newState == .running {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    MacRelaySyncService.shared.syncIfConfigured()
                }
            }
        }
        .onChange(of: selectedTab) { _, tab in
            if tab == 0 { feedService.markViewed() }
        }
    }
}

// MARK: - iPhone Tab View

struct iPhoneTabView: View {
    @Binding var selectedTab: Int
    @EnvironmentObject var configService: ConfigService
    @EnvironmentObject var relayManager: RelayProcessManager
    @StateObject private var nostrService = NostrService.shared
    @StateObject private var feedService = FeedService.shared

    var body: some View {
        TabView(selection: $selectedTab) {
            // Feed Tab
            FeedView()
                .tabItem {
                    Label("Feed", systemImage: "person.2.wave.2")
                }
                .tag(0)

            // Search Tab
            NavigationView {
                SearchView()
                    .navigationTitle("Search")
                    .navigationBarTitleDisplayMode(.inline)
            }
            .navigationViewStyle(.stack)
            .tabItem { Label("Search", systemImage: "magnifyingglass") }
            .tag(1)

            // Profile Tab (own profile)
            NavigationView {
                ProfileView(pubkey: nostrService.ownerHexPubkey, embeddedInNavigation: true)
                    .navigationTitle("Profile")
                    .navigationBarTitleDisplayMode(.inline)
            }
            .navigationViewStyle(.stack)
            .tabItem { Label("Profile", systemImage: "person.crop.circle") }
            .tag(2)

            // Relay Tab (Notes & Media stored in local relay)
            NavigationView {
                ViewerView()
                    .navigationTitle("Relay")
                    .navigationBarTitleDisplayMode(.inline)
            }
            .navigationViewStyle(.stack)
            .tabItem { Label("Relay", systemImage: "doc.text.image") }
            .tag(3)

            // Settings Tab
            NavigationView {
                SettingsView()
                    .navigationTitle("Settings")
                    .navigationBarTitleDisplayMode(.inline)
            }
            .navigationViewStyle(.stack)
            .tabItem { Label("Settings", systemImage: "gearshape") }
            .tag(4)
        }
        .tint(.havenPurple)
        .onAppear {
            if configService.config.hasCompletedSetup && relayManager.state == .idle {
                relayManager.startRelay(config: configService.config)
            }
        }
        .onChange(of: relayManager.state) { _, newState in
            // Once the relay finishes booting, sync missed notes from Mac relay
            if newState == .running {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    MacRelaySyncService.shared.syncIfConfigured()
                }
            }
        }
        .onChange(of: selectedTab) { _, tab in
            if tab == 0 { feedService.markViewed() }
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
