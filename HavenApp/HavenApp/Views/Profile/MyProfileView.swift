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

    /// Not observed: any profile arriving anywhere would redraw this page,
    /// and with it the whole profile (`ProfileContent` takes closures, so it
    /// is never skipped). `ProfileContent` watches this profile's own entry.
    private var nostrService: NostrService { .shared }
    @EnvironmentObject var configService: ConfigService
    /// Held, not observed, for the same reason; `ProfileContent` observes them.
    @StateObject private var loaders: ProfileLoaders
    private var loader: ProfileFeedLoader { loaders.loader }
    private var shop: SellerListingsLoader { loaders.shop }
    private var extras: ProfileExtrasLoader { loaders.extras }
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
    @State private var showingShare = false
    @State private var showingSell = false
    @State private var scrollToTopToken = 0
    /// Bumped by every save. A refusal only undoes the save it belongs to:
    /// one that arrives after a newer save would put back an older profile.
    @State private var saveGeneration = 0

    init(pubkey: String) {
        self.pubkey = pubkey
        _loaders = StateObject(wrappedValue: ProfileLoaders(pubkey: pubkey, usesOwnLedger: true))
    }

    /// The NWC wallet belongs to the owner account only; a whitelisted
    /// account's own profile has no wallet button.
    private var isOwner: Bool {
        Bech32.decode(configService.config.ownerNpub)?.hexString == pubkey
    }

    private var profile: FeedProfile? { nostrService.profiles[pubkey] }

    /// A read-only sign-in can't sign a post or a kind 0, so it gets no Post
    /// and no Edit Profile, as on the web.
    private var canSign: Bool { configService.activeAccountCanSign }

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
            foldsTabBar: true,
            badge: { ProfileActions.badge("YOU", tint: .havenPurple) },
            actions: { _ in actionButtons },
            shopHeader: { sellButton }
        )
        .trustWebPresentation(isPresented: $showingTrustWeb, author: pubkey)
        .sheet(isPresented: $showingShare) { ShareProfileSheet(pubkey: pubkey) }
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
        #if os(macOS)
        .sheet(isPresented: $showingDMInbox) { dmInboxSheet }
        #endif
        #if os(iOS)
        .sheet(isPresented: $showingSettings) { settingsSheet }
        .overlay(alignment: .bottomTrailing) { if canSign { postButton } }
        .onReceive(NotificationCenter.default.publisher(for: .composeFromTabBar)) { note in
            guard (note.object as? Int) == 2, canSign else { return }
            showingCompose = true
        }
        // ⌘R on an iPad keyboard. The Mac binds it to its refresh button.
        .modifier(RefreshesOnTabCommand(tab: 2) {
            Task { await loader.refresh(shop: shop, extras: extras) }
        })
        // Tapping the Profile tab while on it: back to the top, and fetched
        // fresh, the iPhone's way to refresh your own profile.
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
            if canSign {
                #if os(macOS)
                ProfileActions.pill("Post", icon: "pencil", filled: true) { showingCompose = true }
                #endif
                ProfileActions.pill("Edit Profile", icon: "person.crop.circle") { showingEditProfile = true }
            }
            ProfileActions.trustWeb(hint: "Shows your web of trust") { showingTrustWeb = true }
            ProfileActions.icon("qrcode") { showingShare = true }
                .accessibilityLabel("Share profile")
                .help("Share profile")
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

    #if os(macOS)
    private var dmInboxSheet: some View {
        DMInboxView()
            .environmentObject(nostrService)
            .environmentObject(configService)
            .frame(minWidth: 480, minHeight: 500)
    }
    #endif

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
        let generation = saveGeneration + 1
        ProfileEditView(onDismiss: { showingEditProfile = false }, existing: existing, draft: unsavedDraft,
                        onSave: { saveGeneration = generation; applyProfileUpdate($0) },
                        onRefused: { shownBefore, edited in
                            profileRefused(generation: generation, shownBefore: shownBefore, edited: edited)
                        })
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
    private func profileRefused(generation: Int, shownBefore: FeedProfile?, edited: [String: String]) {
        guard generation == saveGeneration else { return }
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
        saveGeneration += 1
        let generation = saveGeneration
        unsavedDraft = nil
        applyProfileUpdate(ProfileEditView.preview(existing, initial: initial, edited: edited))
        Task {
            let result = await ProfileEditView.publish(
                nostrService: nostrService, existing: existing, initial: initial, edited: edited,
                onRefused: { profileRefused(generation: generation, shownBefore: shownBefore, edited: edited) })
            switch result {
            case .success(let updated):
                applyProfileUpdate(updated)
            case .failure:
                guard generation == saveGeneration else { return }
                nostrService.profiles[pubkey] = shownBefore
                unsavedDraft = edited
                ErrorNotificationManager.shared.show("Profile not saved. Tap Edit Profile to try again.")
            }
        }
    }
}

/// Wallet (owner only) on the left; settings on the right (messages live in
/// the Vault tab's right pill). The Mac has no settings button here (it has
/// its own Settings) and gets messages and a refresh button, since nothing
/// there pulls to refresh.
private struct MyProfileToolbar: ViewModifier {
    let isOwner: Bool
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
                // Messages moved to the Vault tab's right pill.
                Button(action: onSettings) {
                    Image(systemName: "gearshape.fill")
                        .font(.appSystem(size: 16, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Settings")
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
                        .overlay(alignment: .topTrailing) { UnreadDMDot() }
                }
                .help("Messages")
            }
        }
        #endif
    }
}

#if os(macOS)
/// The Messages button's unread dot. Its own view, so DM traffic redraws the
/// dot and not the profile under it.
private struct UnreadDMDot: View {
    @ObservedObject private var dmService = DMService.shared

    var body: some View {
        if dmService.totalUnreadCount > 0 {
            Circle()
                .fill(.red)
                .frame(width: 7, height: 7)
                .offset(x: 2, y: -2)
        }
    }
}
#endif
