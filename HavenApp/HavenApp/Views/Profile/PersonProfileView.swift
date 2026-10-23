import SwiftUI

/// Someone's profile, opened from a note, a list, search or a link: follow,
/// message, zap, block. Your own profile opened this way shows you as others
/// see you, with a way to your Profile tab, where editing lives
/// (`MyProfileView`).
///
/// Equatable, and drawn `.equatable()` by `ProfileView`: it opens as a sheet,
/// and its host (the Feed, a note, search) redraws many times a second while
/// it is up, re-running the sheet's content each time. `onDismiss` is a
/// closure SwiftUI cannot compare, so without this every host redraw rebuilt
/// the whole profile under your finger. Its own state, `configService` and
/// the loaders still redraw it.
struct PersonProfileView: View, Equatable {
    let pubkey: String
    var embeddedInNavigation: Bool = false
    var onDismiss: (() -> Void)? = nil

    /// Not observed. `profiles` changes each time any profile arrives, and
    /// the notes being scrolled fetch their authors', so observing it here
    /// rebuilt this page's toolbar, sheets and action rows mid-scroll.
    /// Everything that reads a profile is drawn inside `ProfileContent`,
    /// which observes it.
    private var nostrService: NostrService { .shared }
    @EnvironmentObject var configService: ConfigService
    @Environment(\.dismiss) private var dismiss
    /// Owns the loaders without observing them: they publish while the page
    /// pages and counts followers, and only `ProfileContent` draws from them.
    @StateObject private var models: ProfileLoaders
    private var loader: ProfileFeedLoader { models.loader }
    private var shop: SellerListingsLoader { models.shop }
    private var extras: ProfileExtrasLoader { models.extras }
    /// Not observed; see `ProfileContent.feedService`. The follow button
    /// reads `followedPubkeys`, which `ProfileContent`'s feed watch redraws for.
    private var feedService: FeedService { .shared }

    @State private var showingMessageComposer = false
    @State private var zapSheetContext: ZapSheetContext?
    @State private var zapBurst = false
    @State private var showingTrustWeb = false
    @State private var showingShare = false

    init(pubkey: String, embeddedInNavigation: Bool = false, onDismiss: (() -> Void)? = nil) {
        self.pubkey = pubkey
        self.embeddedInNavigation = embeddedInNavigation
        self.onDismiss = onDismiss
        _models = StateObject(wrappedValue: ProfileLoaders(pubkey: pubkey, usesOwnLedger: false))
    }

    /// `onDismiss` is left out: every caller passes one that clears the same
    /// sheet, so the first one is as good as a later one.
    static func == (lhs: PersonProfileView, rhs: PersonProfileView) -> Bool {
        lhs.pubkey == rhs.pubkey && lhs.embeddedInNavigation == rhs.embeddedInNavigation
    }

    /// Your own key, opened from somewhere other than the Profile tab.
    private var isYou: Bool { configService.activeAccountHexPubkey == pubkey }

    private var isFollowing: Bool { feedService.followedPubkeys.contains(pubkey) }

    private var profile: FeedProfile? { nostrService.profiles[pubkey] }

    private var displayName: String { profile?.bestName ?? ProfileFormat.shortPubkey(pubkey) }

    var body: some View {
        ProfileContent(
            pubkey: pubkey,
            loader: loader,
            shop: shop,
            extras: extras,
            dismissAction: embeddedInNavigation ? nil : performDismiss,
            badge: { badge },
            actions: { compact in actionButtons(compact: compact) },
            shopHeader: { EmptyView() }
        )
        .trustWebPresentation(isPresented: $showingTrustWeb, author: pubkey)
        .sheet(isPresented: $showingShare) { ShareProfileSheet(pubkey: pubkey) }
        // "Open in WoT" from a globe over this profile: a profile in a sheet
        // closes with it, so the WOT tab shows.
        .onReceive(NotificationCenter.default.publisher(for: .havenOpenWOT)) { _ in
            if !embeddedInNavigation { performDismiss() }
        }
        // Blocking shuts their shop as you block, and unblocking fetches it
        // again, rather than waiting for the next visit. ProfileContent
        // reveals the shop section as its listings change.
        .onChange(of: isBlocked) { _, _ in shop.load(pubkey: pubkey, force: true) }
        #if os(iOS)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if !isYou {
                    Button(action: { showingMessageComposer = true }) {
                        Image(systemName: "message.fill")
                            .font(.appSystem(size: 16, weight: .semibold))
                            .foregroundColor(.havenPurple)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Message")
                }
            }
        }
        .sheet(isPresented: $showingMessageComposer) {
            MessageComposerView(recipientPubkey: pubkey)
                .environmentObject(nostrService)
                .environmentObject(configService)
        }
        #else
        .sheet(isPresented: $showingMessageComposer) {
            DMThreadView(counterpartyPubkey: pubkey)
                .environmentObject(nostrService)
                .environmentObject(configService)
                .frame(minWidth: 440, minHeight: 400)
        }
        #endif
        .sheet(item: $zapSheetContext) { context in
            CustomZapSheet(defaultAmount: context.defaultAmount) { amount in
                zap(amount: amount)
            }
            #if os(iOS)
            .presentationDetents([.height(380), .medium])
            .smallSheetSizing()
            .presentationDragIndicator(.visible)
            .presentationBackground(Color.platformWindowBackground)
            #endif
        }
    }

    private func performDismiss() {
        if let onDismiss {
            onDismiss()
        } else {
            dismiss()
        }
    }

    // MARK: - Badge

    @ViewBuilder
    private var badge: some View {
        if isYou {
            ProfileActions.badge("YOU", tint: .havenPurple)
        } else if isFollowing && loader.followsMe {
            HStack(spacing: 3) {
                Text("∞")
                    .font(.appSystem(size: 13, weight: .black))
                Text("MUTUAL")
                    .font(.appSystem(size: 9, weight: .heavy))
                    .tracking(0.8)
            }
            .foregroundColor(Color.havenVerified)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.havenVerified.opacity(0.13))
            .cornerRadius(4)
        } else {
            HStack(spacing: 4) {
                if isFollowing {
                    ProfileActions.badge("FOLLOWING", tint: .green)
                }
                if loader.followsMe {
                    ProfileActions.badge("FOLLOWS YOU", tint: .secondary)
                }
            }
        }
    }

    // MARK: - Actions

    /// One line, never scrolled: the labelled actions share the width and the
    /// icon-only ones keep a fixed square. When space runs out (small phones,
    /// large text) Message drops its word first, then Zap.
    @ViewBuilder
    private func actionButtons(compact: Int) -> some View {
        HStack(spacing: 8) {
            if isYou {
                // Nothing to follow, message or zap. Editing is on the tab.
                // Not from inside a pushed list (Following / Followers): that
                // page is a cover this one cannot close, so the tab would
                // switch out of sight underneath it.
                if !embeddedInNavigation {
                    ProfileActions.pill("Open My Profile", icon: "person.crop.circle") { openMyProfile() }
                }
                ProfileActions.trustWeb(hint: "Shows your web of trust") { showingTrustWeb = true }
                ProfileActions.icon("qrcode") { showingShare = true }
                    .accessibilityLabel("Share profile")
            } else {
                ProfileActions.pill(isFollowing ? "Unfollow" : "Follow",
                                    icon: isFollowing ? "person.badge.minus" : "person.badge.plus",
                                    filled: isFollowing, action: toggleFollow)
                if compact > 0 {
                    ProfileActions.icon("message.fill") { showingMessageComposer = true }
                        .accessibilityLabel("Message")
                } else {
                    ProfileActions.pill("Message", icon: "message.fill") { showingMessageComposer = true }
                }
                if !configService.config.nwcURI.isEmpty, lightningAddress != nil {
                    zapPill(showsWord: compact < 2)
                }
                ProfileActions.trustWeb(hint: "Shows how you're connected to them") { showingTrustWeb = true }
                moreMenu
            }
        }
    }

    /// Closes this profile and switches to the Profile tab.
    private func openMyProfile() {
        performDismiss()
        NotificationCenter.default.post(name: .havenShowMyProfileTab, object: nil)
    }

    private var defaultZapSats: Int {
        max(1, configService.config.defaultZapAmount / 1000)
    }

    private var lightningAddress: String? {
        guard let profile else { return nil }
        if let lud06 = profile.lud06, !lud06.isEmpty { return "lnurl:" + lud06 }
        if let lud16 = profile.lud16, !lud16.isEmpty { return lud16 }
        // NIP-05 resolves to /.well-known/nostr.json — a completely different endpoint
        // from the LUD-16 /.well-known/lnurlp/ path. Do NOT use NIP-05 as a lightning address.
        return nil
    }

    /// Tap zaps the default amount; long-press picks one.
    private func zapPill(showsWord: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "bolt.fill")
                .font(.appSystem(size: 12, weight: .semibold))
            Text(showsWord ? "Zap \(defaultZapSats)" : "\(defaultZapSats)")
                .font(.appSystem(size: 13, weight: .semibold))
                .lineLimit(1)
        }
        .fixedSize()
        .foregroundColor(.orange)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: ProfileActions.height)
        .background(Color.orange.opacity(0.15))
        .cornerRadius(6)
        .overlay { ZapBurstView(isAnimating: $zapBurst) }
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .onLongPressGesture {
            #if os(iOS)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            #endif
            zapSheetContext = ZapSheetContext(defaultAmount: defaultZapSats)
        }
        .onTapGesture { zap() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Zap \(defaultZapSats) sats")
        .accessibilityHint("Long-press to choose an amount")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { zap() }
    }

    /// A zap to the person, not to a note: no `e` tag. Passing the pubkey as
    /// the note id tagged every profile zap as a zap of an event that does not
    /// exist. A failed zap is reported by the zap toast (`ZapService`).
    private func zap(amount: Int? = nil) {
        guard let lud16 = lightningAddress else { return }
        Task {
            do {
                try await ZapService.shared.zapNote(noteId: "", notePubkey: pubkey, lud16: lud16, amountSats: amount)
                await MainActor.run { zapBurst = true }
            } catch {
                #if DEBUG
                print("PersonProfileView: Zap failed: \(error)")
                #endif
            }
        }
    }

    /// The rarer actions, with Block last and apart so it is never a mis-tap
    /// away from Message.
    private var moreMenu: some View {
        Menu {
            Button { showingShare = true } label: {
                Label("Share profile", systemImage: "qrcode")
            }
            Button {
                if let npub = ProfileFormat.npub(pubkey) { ProfileFormat.copy(npub) }
            } label: {
                Label("Copy npub", systemImage: "doc.on.doc")
            }
            if let link = NostrWebLink.profile(pubkey: pubkey) {
                OpenInWebButton(link: link)
            }
            Divider()
            Button(role: isBlocked ? nil : .destructive, action: toggleBlock) {
                Label(isBlocked ? "Unblock" : "Block",
                      systemImage: isBlocked ? "hand.raised.slash" : "hand.raised")
            }
        } label: {
            ProfileActions.iconLabel("ellipsis")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("More")
    }

    private var isBlocked: Bool {
        guard let npub = ProfileFormat.npub(pubkey) else { return false }
        let active = configService.config.activeAccountNpub.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetNpub = active.isEmpty ? configService.config.ownerNpub : active
        let blockedList = configService.config.blockedNpubsPerAccount[targetNpub] ?? []
        return blockedList.contains(npub)
    }

    private func toggleFollow() {
        FollowActions.toggle(pubkey, name: displayName, isFollowing: isFollowing)
    }

    private func toggleBlock() {
        guard let npub = ProfileFormat.npub(pubkey) else { return }
        if isBlocked {
            configService.unblockProfile(npub)
        } else {
            configService.blockProfile(npub)
        }
    }
}
