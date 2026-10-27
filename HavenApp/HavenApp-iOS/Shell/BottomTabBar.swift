import SwiftUI
import UIKit

// MARK: - Dedicated Bottom Tab Bar

struct BottomTabBar: View {
    @Binding var selectedTab: Int
    @Binding var searchPath: NavigationPath
    @Binding var profilePath: NavigationPath
    @Binding var mediaPath: NavigationPath
    @Binding var relayPath: NavigationPath

    @ObservedObject var configService: ConfigService
    @ObservedObject var relayManager: RelayProcessManager
    @ObservedObject var nostrService: NostrService
    @ObservedObject var dmService: DMService
    @ObservedObject var feedService: FeedService
    // Rebuilds the account menu once each account's picture is cached.
    @ObservedObject private var accountAvatars = AccountMenuAvatars.shared

    /// Scroll-linked fold, 0 = full tab bar, 1 = avatar + compose capsule.
    private var chrome: ChromeCollapse { .shared }
    @State private var availableWidth: CGFloat = 0
    @State private var collapsedSize: CGSize = .zero
    @State private var expandedHeight: CGFloat = 0

    private var activeHex: String { configService.activeAccountHexPubkey }

    private var relayStatusColor: Color {
        if relayManager.isBooting {
            return .yellow
        } else if relayManager.isRunning && relayManager.isWotSyncing {
            return .orange
        } else if relayManager.isRunning {
            return .green
        } else {
            return .red
        }
    }

    var body: some View {
        // Both layouts are always present and cross-fade with the scroll, so
        // the bar can sit anywhere between them while the finger is down.
        // The capsule's width and height are interpolated between the two
        // measured sizes; the outer frame keeps the expanded height so the
        // safe-area inset (and every tab's content under it) never relayouts
        // per frame.
        let p = chrome.progress
        let fullWidth = max(availableWidth - 32, collapsedSize.width)
        let width = availableWidth > 0 ? lerp(fullWidth, collapsedSize.width, p) : nil
        let height = expandedHeight > 0 ? lerp(expandedHeight, collapsedSize.height, p) : nil

        ZStack {
            HStack(spacing: 0) { expandedContent }
                .padding(.vertical, 10)
                .padding(.horizontal, 8)
                .frame(width: availableWidth > 0 ? fullWidth : nil)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { expandedHeight = $0 }
                // Shrinks with the capsule rather than being clipped by it,
                // so every tab stays whole while it fades. Gone by 60%, and
                // the folded layout only starts at 40%, so the two never
                // read as overlapping.
                .scaleEffect(width.map { $0 / fullWidth } ?? 1)
                .opacity(ChromeCollapse.fadeOut(p))
                .allowsHitTesting(p < 0.5)
                .accessibilityHidden(p >= 0.5)

            collapsedContent
                .padding(6)
                .fixedSize()
                .onGeometryChange(for: CGSize.self) { $0.size } action: { collapsedSize = $0 }
                .opacity(ChromeCollapse.fadeIn(p))
                .scaleEffect(lerp(0.85, 1, p))
                .allowsHitTesting(p >= 0.5)
                .accessibilityHidden(p < 0.5)
        }
        .frame(width: width, height: height)
        .clipShape(Capsule())
        .applyGlassCapsule()
        .frame(maxWidth: .infinity, minHeight: expandedHeight > 0 ? expandedHeight : nil, alignment: .bottom)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
        .onChange(of: selectedTab) { _, _ in
            // A new tab starts with the bar fully open.
            chrome.reset()
        }
    }

    private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat {
        a + (b - a) * t
    }

    // MARK: - Expanded Content

    @ViewBuilder
    private var expandedContent: some View {
        FeedTabHoldItem(selected: selectedTab == 0, feedService: feedService) {
            if selectedTab == 0 {
                NotificationCenter.default.post(name: NSNotification.Name("FeedTabReselected"), object: nil)
            } else {
                selectedTab = 0
            }
        }

        tabItem(index: 1, title: "Search", icon: "magnifyingglass") {
            if !searchPath.isEmpty {
                searchPath = NavigationPath()
            } else {
                NotificationCenter.default.post(name: NSNotification.Name("SearchScrollToTop"), object: nil)
            }
        }

        expandedProfileTabItem

        tabItem(index: 3, title: "WoT", assetIcon: "WoTTab") {
            NotificationCenter.default.post(name: .wotTabReselected, object: nil)
        }

        tabItem(index: 4, title: "Vault", icon: VaultDashboard.symbol, hasRedBadge: vaultHasNews) {
            if VaultSection.shared.showsMedia {
                if !mediaPath.isEmpty {
                    mediaPath = NavigationPath()
                } else {
                    NotificationCenter.default.post(name: NSNotification.Name("MediaScrollToTop"), object: nil)
                }
            } else if !relayPath.isEmpty {
                relayPath = NavigationPath()
            } else {
                NotificationCenter.default.post(name: NSNotification.Name("RelayScrollToTop"), object: nil)
            }
        } onSelect: {
            // The dot goes to where the news is, not to the list you left.
            if relayManager.hasNewRelayActivity { VaultSection.shared.opensNewActivity = true }
        }
        // What the return pill's arrow points at.
        .vaultAnchor(.bottom)
    }

    /// The Vault tab's dot: something came in, a new message included.
    private var vaultHasNews: Bool {
        relayManager.hasNewRelayActivity || dmService.totalUnreadCount > 0
    }

    // MARK: - Collapsed Content

    /// Feed, Search and Profile compose; the Vault tab opens its dashboard
    /// and the WoT tab its My Web panel.
    private var opensVaultDashboard: Bool { selectedTab == 4 }
    private var opensMyWeb: Bool { selectedTab == 3 }

    private var collapsedFABIcon: String {
        opensVaultDashboard ? VaultDashboard.symbol : opensMyWeb ? TrustMap.Layer.everyone.symbolName : "square.and.pencil"
    }

    private var showsCollapsedFAB: Bool {
        opensVaultDashboard || opensMyWeb || configService.activeAccountCanSign
    }

    private var collapsedFABColor: Color {
        opensVaultDashboard ? relayStatusColor : Color.havenPurple
    }

    private var collapsedFABLabel: String {
        opensVaultDashboard ? VaultDashboard.title : opensMyWeb ? "My Web" : "Compose new post"
    }

    @ViewBuilder
    private var collapsedContent: some View {
        HStack(spacing: 16) {
            // Music or a minimized live stream: play/pause, left of the avatar.
            CollapsedNowPlayingButton()

            // Profile avatar — tap to expand tab bar, hold to switch account
            accountSwitchButton {
                chrome.reset()
            } label: {
                AvatarView(url: nostrService.profiles[activeHex]?.pictureURL, pubkey: activeHex, size: 36)
                    .overlay(
                        Circle()
                            .stroke(Color.havenPurple.opacity(0.6), lineWidth: 2)
                    )
                    .zapFlightOrigin()
                    .overlay(alignment: .topTrailing) {
                        NewsDot(isShown: vaultHasNews, size: 11)
                            .offset(x: 3, y: -3)
                    }
            }
            .accessibilityValue(vaultHasNews ? "New activity" : "")

            // Contextual FAB icon — triggers compose or relay dashboard.
            // A read-only sign-in can't sign a post: no compose button.
            if showsCollapsedFAB {
                Button {
                    if opensVaultDashboard {
                        NotificationCenter.default.post(name: .openRelayDashboard, object: selectedTab)
                    } else {
                        NotificationCenter.default.post(name: .composeFromTabBar, object: selectedTab)
                    }
                } label: {
                    ZStack {
                        Circle()
                            .fill(collapsedFABColor.opacity(0.15))
                            .frame(width: 36, height: 36)
                        Image(systemName: collapsedFABIcon)
                            .font(.appSystem(size: 15, weight: .bold))
                            .foregroundStyle(collapsedFABColor)
                            .symbolRenderingMode(.monochrome)
                    }
                }
                .buttonStyle(.plain)
                .tint(collapsedFABColor)
                .accessibilityLabel(collapsedFABLabel)
            }
        }
    }

    // MARK: - Tab Item

    /// `icon` is an SF Symbol; `assetIcon`, when set, is a template image from
    /// the asset catalog sized to match the symbols instead.
    private func tabItem(index: Int, title: String, icon: String = "", assetIcon: String? = nil, hasRedBadge: Bool = false, onReselect: @escaping () -> Void, onSelect: @escaping () -> Void = {}) -> some View {
        let selected = selectedTab == index
        return Button {
            if selectedTab == index {
                onReselect()
            } else {
                onSelect()
                selectedTab = index
            }
        } label: {
            VStack(spacing: 4) {
                Group {
                    if let assetIcon {
                        // 26pt draws the globe's 20pt circle at about 21.5pt, as tall
                        // as the Vault symbol; a circle reads smaller than a box of
                        // the same size. It scales with Text Size like the symbols.
                        let side = 26 * CGFloat(configService.config.textSizeScale)
                        Image(assetIcon)
                            .resizable()
                            .frame(width: side, height: side)
                    } else {
                        Image(systemName: icon)
                            .font(.appSystem(size: 20, weight: selected ? .semibold : .regular))
                    }
                }
                .foregroundStyle(selected ? Color.havenPurple : .white)
                .frame(height: 24)
                .overlay(alignment: .topTrailing) {
                    NewsDot(isShown: hasRedBadge)
                        .offset(x: 6, y: -4)
                }
                Text(title)
                    .font(.appSystem(size: 10, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.havenPurple : .white)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(hasRedBadge ? "New activity" : "")
    }

    // MARK: - Expanded Profile Tab Item

    private var expandedProfileTabItem: some View {
        let selected = selectedTab == 2
        return accountSwitchButton {
            if selectedTab == 2 {
                if !profilePath.isEmpty {
                    profilePath = NavigationPath()
                } else {
                    NotificationCenter.default.post(name: .havenProfileScrollToTop, object: nil)
                }
            } else {
                selectedTab = 2
            }
        } label: {
            VStack(spacing: 4) {
                AvatarView(url: nostrService.profiles[activeHex]?.pictureURL, pubkey: activeHex, size: 24)
                    .overlay(
                        Circle()
                            .stroke(selected ? Color.havenPurple : .white.opacity(0.5), lineWidth: selected ? 2 : 1)
                    )
                    .zapFlightOrigin()
                    .frame(height: 24)
                Text("Profile")
                    .font(.appSystem(size: 10, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.havenPurple : .white)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
    }

    // MARK: - Account Switch Menu

    /// The avatar in the bar: a tap runs `primary`, a hold opens the account
    /// list.
    ///
    /// This is a `Menu` with a primary action rather than a Button with a
    /// `.contextMenu`. A context menu lifts a snapshot of the button, blurs the
    /// screen, and animates that snapshot back down on dismissal — the same
    /// moment the switch rebuilds every account-scoped view, and the expanded
    /// tab also re-created itself (and the menu hosted on it) through
    /// `.id(activeHex)`. A menu opens in place from the bar with no snapshot
    /// to animate, and AvatarView already reloads on a pubkey change, so the
    /// `.id` is gone. With one account there is nothing to switch to, so the
    /// hold does nothing rather than open a menu that says so.
    @ViewBuilder
    private func accountSwitchButton<Content: View>(
        primary: @escaping () -> Void,
        @ViewBuilder label: () -> Content
    ) -> some View {
        let accounts = configService.allAccountNpubs
        if accounts.count > 1 {
            Menu {
                Section("Switch Account") {
                    ForEach(accounts, id: \.self) { npub in
                        accountMenuRow(npub: npub)
                    }
                }
            } label: {
                label()
            } primaryAction: {
                primary()
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            // Buzz as the hold opens the menu, as the context menu this
            // replaced did. A Menu has no open callback, and its content is
            // built once and cached, so an onAppear in it fires on the first
            // open only. A tap never completes this gesture, so it stays silent.
            .simultaneousGesture(LongPressGesture(minimumDuration: 0.4).onEnded { _ in
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            })
            // Keep the list in the settings order. The default ordering flips
            // it for a menu opening upward from the bottom bar, so the owner
            // would jump between top and bottom depending on where it opened.
            .menuOrder(.fixed)
            .task(id: AccountMenuAvatars.pictureURLs(npubs: configService.allAccountNpubs, profiles: nostrService.profiles)) {
                accountAvatars.prefetch(AccountMenuAvatars.pictureURLs(npubs: configService.allAccountNpubs, profiles: nostrService.profiles))
            }
        } else {
            Button(action: primary, label: label)
                .buttonStyle(.plain)
        }
    }

    private func accountMenuRow(npub: String) -> some View {
        let isOwner = npub == configService.config.ownerNpub
        let currentNpub = configService.config.activeAccountNpub.trimmingCharacters(in: .whitespacesAndNewlines)
        let isCurrent = currentNpub.isEmpty ? isOwner : npub == currentNpub
        let hex = Bech32.decode(npub)?.hexString ?? ""
        let profile = nostrService.profiles[hex]

        return AccountMenuItem(
            npub: npub,
            name: profile?.bestName ?? (isOwner ? "Owner" : AccountSwitcherIdentity.shortNpub(npub)),
            pictureURL: profile?.pictureURL,
            isActive: isCurrent
        ) {
            configService.switchActiveAccount(to: npub)
        }
    }
}
