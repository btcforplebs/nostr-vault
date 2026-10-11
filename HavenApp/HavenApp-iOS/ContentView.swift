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
    @State private var showingDMInbox = false
    @State private var dmInboxConversation: String?
    @State private var pendingMentionNoteId: IdentifiableString?
    @State private var pendingProfilePubkey: IdentifiableString?

    init() {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithTransparentBackground()
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
                    // iPad: the sidebar in both orientations. Portrait used to
                    // fall back to the phone's floating tab bar, stretched
                    // across the whole width; the sidebar now stays pinned
                    // there too (iPadSidebarView keeps every column visible).
                    // One branch per size class, so rotating or raising the
                    // keyboard never swaps the layout and drops a sheet.
                    iPadSidebarView(selectedTab: $selectedTab)
                } else {
                    iPhoneTabView(selectedTab: $selectedTab)
                }
            }
        }
        // Every scroll view in the app, not just the Feed's: under a top bar
        // whose items draw their own glass, iOS 26 otherwise picks the hard
        // edge, a solid black band with a cut line.
        .softTopScrollEdge()
        .onAppear {
            DMService.shared.startListening()
            // Auto-connect NIP-46 remote signer if configured
            if configService.config.hasCompletedSetup && configService.config.activeSigningMode() == "nip46" {
                NIP46Service.shared.connectFromConfig()
            }
            // A notification tapped on a cold start routes before this view
            // exists, so its tab switch went nowhere; the target is still parked.
            if RelayFocus.pending != nil {
                selectedTab = 4 // Vault tab, relay half
                VaultSection.shared.showsMedia = false
            }
            clearCoversForNotificationNote()
            // Replay any queued notification action from a cold start
            if let action = AppDelegate.pendingAction {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    AppDelegate.dispatchAction(action)
                }
            }
        }
        .onChange(of: relayManager.isRunning) { _, running in
            if running, let action = AppDelegate.pendingAction {
                AppDelegate.dispatchAction(action)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .havenOpenSettings)) { _ in
            // Only the iPad sidebar has a Settings tab; the phone opens its sheet.
            if horizontalSizeClass == .regular { selectedTab = 5 }
        }
        .onReceive(NotificationCenter.default.publisher(for: .havenOpenViewer)) { _ in
            selectedTab = 4 // Vault tab, relay half
            VaultSection.shared.showsMedia = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .havenOpenFeed)) { _ in
            selectedTab = 0 // Feed tab
            clearCoversForNotificationNote()
        }
        .onReceive(NotificationCenter.default.publisher(for: .havenOpenSearch)) { _ in
            selectedTab = 1 // Search tab
        }
        .onReceive(NotificationCenter.default.publisher(for: .havenOpenMedia)) { _ in
            selectedTab = 4 // Vault tab, Media half
            VaultSection.shared.showsMedia = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .havenOpenDMInbox)) { note in
            selectedTab = 4 // Vault tab, whose Messages button opens the inbox
            dmInboxConversation = note.object as? String
            showingDMInbox = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .havenOpenMentions)) { notification in
            selectedTab = 0 // Feed tab
            if let eventId = notification.object as? String {
                pendingMentionNoteId = IdentifiableString(id: eventId)
            }
        }
        // A `nostr:` link from another app opens over the current tab.
        .onReceive(NotificationCenter.default.publisher(for: .havenOpenNote)) { notification in
            if let id = notification.object as? String {
                pendingMentionNoteId = IdentifiableString(id: id)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .havenOpenProfile)) { notification in
            if let pubkey = notification.object as? String {
                pendingProfilePubkey = IdentifiableString(id: pubkey)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .havenOpenWallet)) { _ in
            selectedTab = 2 // Profile tab
            // The tab opens the wallet when it shows; it may not be built yet.
            ProfileTabRequests.shared.openWallet = true
        }
        // Your own profile, opened from a note or a list: the tab, where editing is.
        .onReceive(NotificationCenter.default.publisher(for: .havenShowMyProfileTab)) { _ in
            selectedTab = 2
            pendingProfilePubkey = nil
        }
        .modifier(OpensRelayTab(selectedTab: $selectedTab))
        .modifier(IPadCommandKeys(selectedTab: $selectedTab))
        .sheet(isPresented: $showingDMInbox) {
            NavigationStack {
                DMInboxView(openConversation: dmInboxConversation)
                    .environmentObject(NostrService.shared)
                    .environmentObject(ConfigService.shared)
            }
            .dmInboxSheetSizing()
        }
        .sheet(item: $pendingMentionNoteId) { noteId in
            NoteDetailViewWrapper(noteId: noteId.id, onDismiss: { pendingMentionNoteId = nil })
                .environmentObject(NostrService.shared)
                .environmentObject(ConfigService.shared)
        }
        .sheet(item: $pendingProfilePubkey) { pubkey in
            ProfileView(pubkey: pubkey.id, onDismiss: { pendingProfilePubkey = nil })
                .environmentObject(NostrService.shared)
                .environmentObject(ConfigService.shared)
        }
    }
}

extension ContentView {
    /// A notification's post is about to open in the Feed tab: switch there
    /// and drop anything that would cover it.
    fileprivate func clearCoversForNotificationNote() {
        guard NotificationOpen.pending != nil else { return }
        selectedTab = 0
        showingDMInbox = false
        pendingMentionNoteId = nil
        pendingProfilePubkey = nil
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

/// ⌘R and ⌘F from an iPad's hardware keyboard, in both iPad layouts. ⌘R
/// refreshes whatever the showing tab lists (each tab's view answers for
/// itself, keyed by its index); ⌘F goes to Search with the field focused.
/// The Mac binds ⌘R per screen in its toolbars; iOS has no toolbar button
/// to hang it on, so one binding here asks the showing tab instead.
private struct IPadCommandKeys: ViewModifier {
    @Binding var selectedTab: Int
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    func body(content: Content) -> some View {
        content.background {
            if horizontalSizeClass == .regular {
                Group {
                    Button("Refresh") {
                        NotificationCenter.default.post(name: .havenRefreshTab, object: selectedTab)
                    }
                    .keyboardShortcut("r", modifiers: .command)
                    Button("Search") {
                        // Search already showing hears the notification. A
                        // Search tab not on screen (another tab, or a note
                        // pushed over it) reads the request when it appears:
                        // the switch shows it, and each layout pops its
                        // Search stack on this notification.
                        SearchFocusRequest.request()
                        selectedTab = 1
                        NotificationCenter.default.post(name: .havenFocusSearch, object: nil)
                    }
                    .keyboardShortcut("f", modifiers: .command)
                }
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
            }
        }
    }
}

/// Every notification that lands in the Vault tab's relay half switches to it. One modifier
/// rather than a receiver each keeps ContentView's chain inside the type
/// checker's budget.
private struct OpensRelayTab: ViewModifier {
    @Binding var selectedTab: Int
    @ObservedObject private var tutorialCenter = TutorialCenter.shared

    func body(content: Content) -> some View {
        content
            // Your Vault starts the first time the Vault tab is picked, on
            // either half. Not from VaultView: the tab view builds it while
            // another tab shows, and it would take the slot Feeds needs.
            // Re-checked when a status is saved, like Feeds.
            .task(id: "\(selectedTab).\(tutorialCenter.revision)") {
                if selectedTab == 4 {
                    tutorialCenter.startIfEligible(.vault, account: NostrService.shared.activeHexPubkey)
                }
            }
            // A last card's Next goes to the next tutorial's page: WoT is
            // the WoT tab, Your Vault the Relay tab, Wallet Connect the
            // wallet on Profile, Pocket Relay the relay dashboard on the
            // Relay tab. Replay from Settings lands here too, after its
            // jump to the feed.
            .onChange(of: tutorialCenter.active) { _, active in
                if active == .wot { selectedTab = 3 }
                // Your Vault's cards and Pocket Relay's dashboard are on
                // either half, so stay on the one showing.
                if active == .vault || active == .pocketRelay { selectedTab = 4 }
                // Opened once the wallet sheet it came from has closed and
                // the Relay tab is showing. Already open when the dashboard
                // started it, and opening it again does nothing.
                if active == .pocketRelay {
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(0.6))
                        NotificationCenter.default.post(name: .openRelayDashboard, object: nil)
                    }
                }
                if active == .walletConnect { selectedTab = 2 }
            }
            .onReceive(NotificationCenter.default.publisher(for: .havenOpenRelayLikes)) { _ in showVault(media: false) }
            .onReceive(NotificationCenter.default.publisher(for: .havenOpenRelayNotes)) { _ in showVault(media: false) }
            .onReceive(NotificationCenter.default.publisher(for: .havenOpenRelayZaps)) { _ in showVault(media: false) }
            .onReceive(NotificationCenter.default.publisher(for: .havenOpenRelayFollowers)) { _ in showVault(media: false) }
    }

    /// The Vault tab, on its relay half or its Media half.
    private func showVault(media: Bool) {
        selectedTab = 4
        VaultSection.shared.showsMedia = media
    }
}
