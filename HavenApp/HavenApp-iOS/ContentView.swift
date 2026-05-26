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

    init() {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithTransparentBackground()
        appearance.backgroundEffect = UIBlurEffect(style: .systemUltraThinMaterial)
        appearance.backgroundColor = UIColor.black.withAlphaComponent(0.12)
        appearance.titleTextAttributes = [.foregroundColor: UIColor.white]
        appearance.largeTitleTextAttributes = [.foregroundColor: UIColor.white]
        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
        UINavigationBar.appearance().compactAppearance = appearance
    }

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
        .onAppear {
            DMService.shared.startListening()

            // Request push notification permissions and register for APNs
            PushNotificationService.shared.requestPermissionAndRegister()
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
            .navigationTitle("Nostr Vault")
        } detail: {
            switch selectedTab {
            case 0:
                FeedView()
            case 1:
                NavigationStack {
                    SearchView()
                        .navigationTitle("Search")
                        .navigationBarTitleDisplayMode(.inline)
                        .navigationDestination(for: FeedNote.self) { note in
                            NoteDetailView(note: note)
                        }
                }
            case 2:
                NavigationStack {
                    ProfileView(pubkey: configService.activeAccountHexPubkey, embeddedInNavigation: false)
                        .id(configService.activeAccountHexPubkey)
                        .navigationTitle("Profile")
                        .navigationBarTitleDisplayMode(.inline)
                        .navigationDestination(for: FeedNote.self) { note in
                            NoteDetailView(note: note)
                        }
                }
            case 3:
                NavigationStack {
                    ViewerView()
                        .navigationTitle("Relay")
                        .navigationBarTitleDisplayMode(.inline)
                        .navigationDestination(for: FeedNote.self) { note in
                            NoteDetailView(note: note)
                        }
                }
            case 4:
                NavigationStack {
                    SettingsView()
                        .navigationTitle("Settings")
                        .navigationBarTitleDisplayMode(.inline)
                        .navigationDestination(for: FeedNote.self) { note in
                            NoteDetailView(note: note)
                        }
                }
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
        .overlay(alignment: .top) {
            VStack(spacing: 6) {
                ZapNotificationBanner()
                FollowNotificationBanner()
                MediaUploadNotificationBanner()
            }
            .padding(.top, 4)
            .allowsHitTesting(true)
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
                .toolbar(.hidden, for: .tabBar)
                .tag(0)

            // Search Tab
            NavigationStack {
                SearchView()
                    .navigationTitle("Search")
                    .navigationBarTitleDisplayMode(.inline)
                    .navigationDestination(for: FeedNote.self) { note in
                        NoteDetailView(note: note)
                    }
            }
            .toolbar(.hidden, for: .tabBar)
            .tag(1)

            // Profile Tab (own profile)
            NavigationStack {
                ProfileView(pubkey: configService.activeAccountHexPubkey, embeddedInNavigation: false)
                    .id(configService.activeAccountHexPubkey) // Force reload when account changes
                    .navigationTitle("Profile")
                    .navigationBarTitleDisplayMode(.inline)
                    .navigationDestination(for: FeedNote.self) { note in
                        NoteDetailView(note: note)
                    }
            }
            .toolbar(.hidden, for: .tabBar)
            .tag(2)

            // Relay Tab (Notes & Media stored in local relay)
            NavigationStack {
                ViewerView()
                    .navigationTitle("Relay")
                    .navigationBarTitleDisplayMode(.inline)
                    .navigationDestination(for: FeedNote.self) { note in
                        NoteDetailView(note: note)
                    }
            }
            .toolbar(.hidden, for: .tabBar)
            .tag(3)

            // Settings Tab
            NavigationStack {
                SettingsView()
                    .navigationTitle("Settings")
                    .navigationBarTitleDisplayMode(.inline)
                    .navigationDestination(for: FeedNote.self) { note in
                        NoteDetailView(note: note)
                    }
            }
            .toolbar(.hidden, for: .tabBar)
            .tag(4)

        }
        .tint(.havenPurple)
        .toolbar(.hidden, for: .tabBar) // Hide the native tab bar
        .safeAreaInset(edge: .bottom, spacing: 0) {
            customTabBar
        }
        .overlay(alignment: .top) {
            VStack(spacing: 6) {
                ZapNotificationBanner()
                FollowNotificationBanner()
                MediaUploadNotificationBanner()
            }
            .padding(.top, 4)
            .allowsHitTesting(true)
        }
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

    private var customTabBar: some View {
        HStack(spacing: 0) {
            tabButton(index: 0, title: "Feed", systemImage: "person.2.wave.2") {
                NotificationCenter.default.post(name: NSNotification.Name("ScrollToTop"), object: nil)
                FeedService.shared.refresh()
            }
            tabButton(index: 1, title: "Search", systemImage: "magnifyingglass")
            profileTabButton()
            tabButton(index: 3, title: "Relay", systemImage: "doc.text.image")
            tabButton(index: 4, title: "Settings", systemImage: "gearshape")
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 8)
        .applyGlassCapsule()
        .compositingGroup()
        .padding(.horizontal, 16)
        .padding(.bottom, safeAreaBottomPadding > 0 ? 2 : 8)
    }

    private func tabButton(index: Int, title: String, systemImage: String, onReselect: (() -> Void)? = nil) -> some View {
        Button(action: {
            if selectedTab == index {
                onReselect?()
            } else {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    selectedTab = index
                }
            }
        }) {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 20, weight: selectedTab == index ? .semibold : .regular))
                    .scaleEffect(selectedTab == index ? 1.15 : 1.0)
                    .frame(height: 24)
                
                Text(title)
                    .font(.system(size: 10, weight: selectedTab == index ? .semibold : .regular))
            }
            .foregroundColor(selectedTab == index ? .havenPurple : .secondary.opacity(0.8))
            .frame(maxWidth: .infinity)
        }
    }

    private func profileTabButton() -> some View {
        let index = 2
        let activeHex = configService.activeAccountHexPubkey
        let avatarURL = nostrService.profiles[activeHex]?.pictureURL

        return Button(action: {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                selectedTab = index
            }
        }) {
            VStack(spacing: 4) {
                AvatarView(
                    url: avatarURL,
                    pubkey: activeHex,
                    size: 24
                )
                .scaleEffect(selectedTab == index ? 1.15 : 1.0)
                .frame(height: 24)

                Text("Profile")
                    .font(.system(size: 10, weight: selectedTab == index ? .semibold : .regular))
            }
            .foregroundColor(selectedTab == index ? .havenPurple : .secondary.opacity(0.8))
            .frame(maxWidth: .infinity)
        }
        .contextMenu {
            if configService.allAccountNpubs.count > 1 {
                ForEach(configService.allAccountNpubs, id: \.self) { npub in
                    let isOwner = npub == configService.config.ownerNpub
                    let activeAccountNpub = configService.config.activeAccountNpub.trimmingCharacters(in: .whitespacesAndNewlines)
                    let isActive = activeAccountNpub.isEmpty ? isOwner : npub == activeAccountNpub
                    let hex = Bech32.decode(npub)?.hexString ?? ""
                    let name = nostrService.profiles[hex]?.bestName ?? (isOwner ? "Owner" : String(npub.prefix(8)))

                    Button {
                        configService.switchActiveAccount(to: npub)
                        feedService.switchMode(feedService.feedMode)
                    } label: {
                        if isActive {
                            Label(name, systemImage: "checkmark")
                        } else {
                            Text(name)
                        }
                    }
                }
            } else {
                Text("No other accounts")
            }
        }
    }


    private var safeAreaBottomPadding: CGFloat {
        #if os(iOS)
        let keyWindow = UIApplication.shared.connectedScenes
            .filter({$0.activationState == .foregroundActive})
            .compactMap({$0 as? UIWindowScene})
            .first?.windows
            .filter({$0.isKeyWindow}).first
        return keyWindow?.safeAreaInsets.bottom ?? 0
        #else
        return 0
        #endif
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
