import SwiftUI

/// Requests for the Profile tab that can arrive before it is on screen (a
/// widget tap switches tabs and asks for the wallet in the same moment, and
/// the tab may never have been opened). The tab picks them up when it shows.
@MainActor
final class ProfileTabRequests: ObservableObject {
    static let shared = ProfileTabRequests()
    /// Open the Lightning wallet sheet.
    @Published var openWallet = false
}

/// Your own profile: the Profile tab, and nothing else. Edit, post, your
/// wallet, messages and settings live here; anyone else's profile (and your
/// own seen from elsewhere) is `PersonProfileView`.
struct MyProfileView: View {
    let pubkey: String

    @EnvironmentObject var nostrService: NostrService
    @EnvironmentObject var configService: ConfigService
    @StateObject private var loader: ProfileFeedLoader
    @StateObject private var shop = SellerListingsLoader()
    @StateObject private var extras = ProfileExtrasLoader()
    @StateObject private var dmService = DMService.shared
    @ObservedObject private var tutorialCenter = TutorialCenter.shared
    @ObservedObject private var requests = ProfileTabRequests.shared
    #if os(iOS)
    /// iPad (regular width) has one Settings: the sidebar's. The gear selects
    /// it instead of opening a second copy in a sheet.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    @State private var showingEditProfile = false
    /// Fields from an autosave that did not reach the relays; the next edit
    /// opens with them.
    @State private var unsavedDraft: [String: String]?
    @State private var showingCompose = false
    @State private var showingSettings = false
    @State private var showingDMInbox = false
    @State private var showingLightning = false
    @State private var showingTrustWeb = false
    @State private var showingSell = false
    @State private var scrollToTopToken = 0

    init(pubkey: String) {
        self.pubkey = pubkey
        _loader = StateObject(wrappedValue: ProfileFeedLoader(pubkey: pubkey, usesOwnLedger: true))
    }

    /// The NWC wallet belongs to the owner account only; a whitelisted
    /// account's own profile has no wallet button.
    private var isOwner: Bool {
        Bech32.decode(configService.config.ownerNpub)?.hexString == pubkey
    }

    private var profile: FeedProfile? { nostrService.profiles[pubkey] }

    var body: some View {
        ProfileContent(
            pubkey: pubkey,
            loader: loader,
            shop: shop,
            extras: extras,
            shopAlwaysVisible: true,
            shopEmptyText: "You haven't listed anything yet",
            canDeleteMedia: true,
            scrollToTopToken: scrollToTopToken,
            scrollDecoration: MyProfileScrollDecoration { showingEditProfile = true },
            badge: { ProfileActions.badge("YOU", tint: .havenPurple) },
            actions: { _ in actionButtons },
            shopHeader: { sellButton }
        )
        .trustWebPresentation(isPresented: $showingTrustWeb, author: pubkey)
        .modifier(toolbar)
        .sheet(isPresented: $showingEditProfile) { editSheet }
        .sheet(isPresented: $showingSell, onDismiss: { shop.load(pubkey: pubkey, force: true) }) {
            MarketplaceSellView(onDismiss: { showingSell = false })
                .environmentObject(nostrService)
                .environmentObject(configService)
        }
        .sheet(isPresented: $showingLightning) { lightningSheet }
        .sheet(isPresented: $showingCompose) {
            ComposeView(onDismiss: { showingCompose = false })
                .environmentObject(nostrService)
                .environmentObject(configService)
        }
        .sheet(isPresented: $showingDMInbox) { dmInboxSheet }
        #if os(iOS)
        .sheet(isPresented: $showingSettings) { settingsSheet }
        .overlay(alignment: .bottomTrailing) { postButton }
        .onReceive(NotificationCenter.default.publisher(for: .composeFromTabBar)) { note in
            guard (note.object as? Int) == 2 else { return }
            showingCompose = true
        }
        // ⌘R on an iPad keyboard. The Mac binds it to its refresh button; on
        // iOS pulling down opens the editor, so the key is the refresh.
        .modifier(RefreshesOnTabCommand(tab: 2) {
            Task { await loader.refresh(shop: shop, extras: extras) }
        })
        // Tapping the Profile tab while on it: back to the top, and fetched
        // fresh, the iPhone's only way to refresh your own profile (the pull
        // opens the editor).
        .onReceive(NotificationCenter.default.publisher(for: .havenProfileScrollToTop)) { _ in
            scrollToTopToken += 1
            Task { await loader.refresh(shop: shop, extras: extras) }
        }
        #endif
        // Vault in Your Pocket's last card hands over to Wallet Connect, whose
        // cards are on the wallet. On appear too: the Profile tab may only now be
        // showing.
        .onChange(of: tutorialCenter.active) { _, active in
            if active == .walletConnect && isOwner { showingLightning = true }
            // A replay of Vault in Your Pocket: its cards are on the Vault tab.
            if active == .pocketRelay { showingLightning = false }
        }
        .onAppear {
            if tutorialCenter.active == .walletConnect && isOwner { showingLightning = true }
            takeWalletRequest()
        }
        .onChange(of: requests.openWallet) { _, _ in takeWalletRequest() }
    }

    /// The wallet widget asked for the wallet. Only the owner has one.
    private func takeWalletRequest() {
        guard requests.openWallet else { return }
        requests.openWallet = false
        if isOwner { showingLightning = true }
    }

    // MARK: - Actions

    private var actionButtons: some View {
        HStack(spacing: 8) {
            #if os(macOS)
            ProfileActions.pill("Post", icon: "pencil", filled: true) { showingCompose = true }
            #endif
            // Pulling the page down opens this too; the button stays for
            // VoiceOver and anyone who has not found the pull.
            ProfileActions.pill("Edit Profile", icon: "person.crop.circle") { showingEditProfile = true }
            ProfileActions.trustWeb(hint: "Shows your web of trust") { showingTrustWeb = true }
        }
    }

    private var sellButton: some View {
        Button { showingSell = true } label: {
            Label("Sell something", systemImage: "tag")
                .font(.appSystem(size: 14, weight: .bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(Color.havenPurple)
                .foregroundColor(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    #if os(iOS)
    private var postButton: some View {
        ChromeFold(anchor: .bottomTrailing) {
            Button(action: { showingCompose = true }) {
                HStack(spacing: 6) {
                    Image(systemName: "square.and.pencil")
                        .font(.appSystem(size: 15, weight: .bold))
                    Text("Post")
                        .font(.appSystem(size: 14, weight: .bold, design: .rounded))
                }
                .foregroundColor(.white)
                .frame(height: 48)
                .padding(.horizontal, 18)
                .background(
                    Capsule()
                        .fill(
                            LinearGradient(
                                gradient: Gradient(colors: [Color.havenPurple, Color.havenPurpleLight]),
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .shadow(color: Color.havenPurple.opacity(0.35), radius: 8, x: 0, y: 4)
                )
            }
            .buttonStyle(PressScaleButtonStyle())
            // Shares the row above the tab bar with the music mini player.
            .modifier(FloatingButtonSlot())
            .hoverEffect(.lift)
        }
    }
    #endif

    // MARK: - Toolbar

    private var toolbar: MyProfileToolbar {
        MyProfileToolbar(
            isOwner: isOwner,
            hasUnreadDMs: dmService.totalUnreadCount > 0,
            onWallet: { showingLightning = true },
            onMessages: { showingDMInbox = true },
            onSettings: {
                #if os(iOS)
                if horizontalSizeClass == .regular {
                    NotificationCenter.default.post(name: .havenOpenSettings, object: nil)
                } else {
                    showingSettings = true
                }
                #endif
            },
            onRefresh: { Task { await loader.refresh(shop: shop, extras: extras) } }
        )
    }

    // MARK: - Sheets

    private var lightningSheet: some View {
        NavigationStack {
            WalletLightningTab()
                .environmentObject(nostrService)
                .environmentObject(configService)
                .navigationTitle("Lightning")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { showingLightning = false }
                            .foregroundColor(.havenPurple)
                    }
                }
        }
        #if os(macOS)
        .frame(minWidth: 500, minHeight: 550)
        #endif
    }

    @ViewBuilder
    private var dmInboxSheet: some View {
        #if os(iOS)
        NavigationStack {
            DMInboxView()
                .environmentObject(nostrService)
                .environmentObject(configService)
        }
        .dmInboxSheetSizing()
        #else
        DMInboxView()
            .environmentObject(nostrService)
            .environmentObject(configService)
            .frame(minWidth: 480, minHeight: 500)
        #endif
    }

    #if os(iOS)
    private var settingsSheet: some View {
        NavigationStack {
            SettingsView()
                .environmentObject(RelayProcessManager.shared)
                .environmentObject(ConfigService.shared)
                .environmentObject(NostrService.shared)
                .environmentObject(StatsService.shared)
                .navigationTitle("Settings")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { showingSettings = false }
                            .foregroundColor(.havenPurple)
                    }
                }
        }
    }
    #endif

    @ViewBuilder
    private var editSheet: some View {
        let existing = profile ?? FeedProfile(pubkey: pubkey)
        #if os(iOS)
        ProfileEditView(onDismiss: { showingEditProfile = false }, existing: existing, draft: unsavedDraft,
                        onSave: applyProfileUpdate,
                        onAutosave: { initial, edited in autosaveProfile(existing, initial: initial, edited: edited) },
                        onDiscard: { unsavedDraft = nil })
        .environmentObject(nostrService)
        .environmentObject(configService)
        .presentationDragIndicator(.visible)
        #else
        ProfileEditView(onDismiss: { showingEditProfile = false }, existing: existing, onSave: applyProfileUpdate,
                        onRefused: { shownBefore, edited in profileRefused(shownBefore: shownBefore, edited: edited) })
        .environmentObject(nostrService)
        .environmentObject(configService)
        #endif
    }

    // MARK: - Profile editing

    private func applyProfileUpdate(_ updated: FeedProfile) {
        nostrService.profiles[pubkey] = updated
        nostrService.saveProfilesThrottled()
    }

    /// No relay took the new profile: the page goes back to what it showed
    /// and the next edit opens with what was typed.
    private func profileRefused(shownBefore: FeedProfile?, edited: [String: String]) {
        nostrService.profiles[pubkey] = shownBefore
        unsavedDraft = edited
        ErrorNotificationManager.shared.show("Profile not saved: no relay accepted it. Edit Profile still has your changes.")
    }

    /// The edit sheet was swiped away with changes. They show at once and are
    /// published behind; if that fails, or no relay accepts the new profile,
    /// the page goes back to what it showed and keeps the changes for the
    /// next edit.
    private func autosaveProfile(_ existing: FeedProfile, initial: [String: String], edited: [String: String]) {
        let shownBefore = nostrService.profiles[pubkey]
        unsavedDraft = nil
        applyProfileUpdate(ProfileEditView.preview(existing, initial: initial, edited: edited))
        Task {
            let result = await ProfileEditView.publish(
                nostrService: nostrService, existing: existing, initial: initial, edited: edited,
                onRefused: { profileRefused(shownBefore: shownBefore, edited: edited) })
            switch result {
            case .success(let updated):
                applyProfileUpdate(updated)
            case .failure:
                nostrService.profiles[pubkey] = shownBefore
                unsavedDraft = edited
                ErrorNotificationManager.shared.show("Profile not saved. Pull down to try again.")
            }
        }
    }
}

/// Pulling your own profile down opens the editor (Logen). Nothing on the
/// Mac, which has a refresh button instead.
private struct MyProfileScrollDecoration: ViewModifier {
    let onPull: () -> Void

    func body(content: Content) -> some View {
        #if os(iOS)
        content.pullToEdit(isEnabled: true, onTrigger: onPull)
        #else
        content
        #endif
    }
}

/// Wallet (owner only) on the left; messages and settings on the right. The
/// Mac has no settings button here (it has its own Settings) and gets a
/// refresh button, since nothing there pulls to refresh.
private struct MyProfileToolbar: ViewModifier {
    let isOwner: Bool
    let hasUnreadDMs: Bool
    let onWallet: () -> Void
    let onMessages: () -> Void
    let onSettings: () -> Void
    let onRefresh: () -> Void

    func body(content: Content) -> some View {
        #if os(iOS)
        content.toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                if isOwner {
                    Button(action: onWallet) {
                        Image(systemName: "bolt.fill")
                            .font(.appSystem(size: 16, weight: .semibold))
                            .foregroundColor(.havenPurple)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Lightning")
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 16) {
                    Button(action: onMessages) {
                        Image(systemName: "bubble.right.fill")
                            .font(.appSystem(size: 16, weight: .semibold))
                            .foregroundColor(.havenPurple)
                            .overlay(alignment: .topTrailing) {
                                if hasUnreadDMs {
                                    Circle()
                                        .fill(.red)
                                        .frame(width: 8, height: 8)
                                        .offset(x: 3, y: -3)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Messages")

                    Button(action: onSettings) {
                        Image(systemName: "gearshape.fill")
                            .font(.appSystem(size: 16, weight: .semibold))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Settings")
                }
            }
        }
        #else
        content.toolbar {
            ToolbarItem(placement: .automatic) {
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                        .foregroundColor(.havenPurple)
                }
                .help("Refresh Profile")
                .keyboardShortcut("r", modifiers: .command)
            }
            ToolbarItem(placement: .automatic) {
                if isOwner {
                    Button(action: onWallet) {
                        Image(systemName: "bolt.fill")
                            .foregroundColor(.havenPurple)
                    }
                    .help("Lightning")
                }
            }
            ToolbarItem(placement: .automatic) {
                Button(action: onMessages) {
                    Image(systemName: "bubble.right.fill")
                        .foregroundColor(.havenPurple)
                        .overlay(alignment: .topTrailing) {
                            if hasUnreadDMs {
                                Circle()
                                    .fill(.red)
                                    .frame(width: 7, height: 7)
                                    .offset(x: 2, y: -2)
                            }
                        }
                }
                .help("Messages")
            }
        }
        #endif
    }
}
