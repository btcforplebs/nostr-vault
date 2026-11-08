import SwiftUI
import UIKit

// MARK: - iPhone Tab View

struct iPhoneTabView: View {
    @Binding var selectedTab: Int
    @EnvironmentObject var configService: ConfigService
    @EnvironmentObject var relayManager: RelayProcessManager
    @StateObject private var nostrService = NostrService.shared
    @StateObject private var feedService = FeedService.shared
    @StateObject private var dmService = DMService.shared

    @State private var searchPath = NavigationPath()
    @State private var profilePath = NavigationPath()
    @State private var mediaPath = NavigationPath()
    @State private var relayPath = NavigationPath()
    @State private var tabBarHeight: CGFloat = 0
    /// The tab bar alone, without the mini player above it.
    @State private var tabBarOnlyHeight: CGFloat = 0
    @ObservedObject private var buttonRow = FloatingButtonRow.shared
    /// The software keyboard is on screen: the dock goes (DockInset.shown).
    @State private var keyboardUp = false

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var activeHex: String { configService.activeAccountHexPubkey }

    private func syncButtonRow() {
        buttonRow.update(tabBarOnlyHeight: tabBarOnlyHeight)
    }

    /// The whole window (safe area included) and the safe area on its left.
    /// Measured on the whole window, so the keyboard coming up doesn't change it.
    @State private var windowSize: CGSize = .zero
    @State private var leadingInset: CGFloat = 0

    /// iPad (regular width): every tab's list sits in a `NoteSplitPane`, in
    /// both orientations. An opened note covers the list, with ‹ Back, as on
    /// the web's desktop layout; landscape gives the right side to "Your
    /// space" (`SpaceColumn`) instead. The iPhone Duo open on its side puts
    /// "Your space" on the left half and the app on the right
    /// (`ShellLayout.fold`); closed, it is the phone with the dock as a rail
    /// on the right; open upright, the phone as is. Always the same view
    /// tree, so rotating, folding or unfolding keeps the tab, its
    /// scroll position and any sheet open in it (the composer, with its text
    /// and photos). `horizontalSizeClass` is read before `body` sets every
    /// screen to compact, so it is the real one.
    private var layout: ShellLayout {
        ShellLayout.pick(
            isPhone: UIDevice.current.userInterfaceIdiom == .phone,
            regularWidth: horizontalSizeClass == .regular,
            window: windowSize
        )
    }

    private var usesNoteSplit: Bool { layout.usesNoteSplit }

    /// The tab's list in a `NoteSplitPane` when `usesNoteSplit`, otherwise as is.
    @ViewBuilder
    private func noteSplit<Content: View>(
        _ emptyMessage: String,
        @ViewBuilder _ content: @escaping () -> Content
    ) -> some View {
        if usesNoteSplit {
            NoteSplitPane(
                emptyTitle: "No Note Selected",
                emptyMessage: emptyMessage,
                allowsTwoColumns: false,
                content: content
            )
        } else {
            content()
        }
    }

    /// iPad in landscape: a slim rail left of the app (in place of the
    /// dock) and "Your space" right of it. iPhone Duo open on its side:
    /// "Your space" left of the fold, the app right of it, the rail on the
    /// far right. iPhone Duo closed: the app, the rail on the right.
    private var showsSpace: Bool { layout.hasSideRail }

    private var dockPlacement: DockInset.Placement {
        DockInset.placement(dockShown: DockInset.shown(keyboardUp: keyboardUp, sideRail: showsSpace), keyboardUp: keyboardUp)
    }

    private var rootDockInset: CGFloat {
        DockInset.rootBottom(placement: dockPlacement, dockHeight: tabBarHeight)
    }

    /// The music mini player rides above the tab bar on every tab. Measured
    /// together, so screens inset for both.
    @ViewBuilder
    private var dock: some View {
        VStack(spacing: 6) {
            // Leaves room on the right for the screen's floating button
            // (Post, Blossom, Relay), which drops level with it.
            // Folds away with the floating button as the bar shrinks;
            // the folded bar carries a small now-playing button instead.
            // Faded rather than removed, so the inset never relayouts.
            ChromeFold(anchor: .bottomLeading) {
                MiniPlayerBar()
            }
            .padding(.leading, 12)
            .padding(.trailing, max(12, buttonRow.reservedWidth))
            BottomTabBar(
                selectedTab: $selectedTab,
                searchPath: $searchPath,
                profilePath: $profilePath,
                mediaPath: $mediaPath,
                relayPath: $relayPath,
                configService: configService,
                relayManager: relayManager,
                nostrService: nostrService,
                dmService: dmService,
                feedService: feedService
            )
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { tabBarOnlyHeight = geo.size.height }
                        .onChange(of: geo.size.height) { _, height in tabBarOnlyHeight = height }
                }
            )
        }
        .onChange(of: tabBarOnlyHeight) { _, _ in syncButtonRow() }
        .onAppear { syncButtonRow() }
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { tabBarHeight = geo.size.height; buttonRow.update(chromeHeight: geo.size.height) }
                    // The dock moves between the root band and the keyboard
                    // inset (two copies); the old copy leaves after the new
                    // one has measured. Only zero when no dock is shown, or
                    // the height sticks at 0 (buttons behind the bar, no
                    // PiP band, a second mini player on Feed).
                    .onDisappear {
                        if dockPlacement == .none { tabBarHeight = 0; buttonRow.update(chromeHeight: 0) }
                    }
                    .onChange(of: geo.size.height) { _, height in
                        tabBarHeight = height
                        buttonRow.update(chromeHeight: height)
                    }
            }
        )
    }

    var body: some View {
        HStack(spacing: 0) {
            if layout == .padLandscape { sideRail(onRight: false) }
            if layout == .fold {
                SpaceColumn(fillsFoldHalf: true)
                    .frame(width: ShellLayout.foldLeftWidth(windowWidth: windowSize.width, leadingInset: leadingInset))
                // Nothing on the crease.
                Color.black
                    .frame(width: ShellLayout.foldGutter)
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
            }
            tabs
            if layout == .padLandscape {
                SpaceColumn()
                    .transition(.move(edge: .trailing))
            }
            if layout.railOnRight { sideRail(onRight: true) }
        }
        .background {
            GeometryReader { geo in
                Color.clear
                    .onAppear { leadingInset = geo.safeAreaInsets.leading }
                    .onChange(of: geo.safeAreaInsets.leading) { _, inset in leadingInset = inset }
            }
        }
        .background {
            GeometryReader { geo in
                Color.clear
                    .onAppear { windowSize = geo.size }
                    .onChange(of: geo.size) { _, size in windowSize = size }
            }
            .ignoresSafeArea()
        }
        // The iPad is laid out like the iPhone: same headers, same buttons,
        // no system toolbar row. Screens branch on the width class for that,
        // so every one below sees compact.
        .environment(\.horizontalSizeClass, .compact)
    }

    /// The dock's items down a side of the window; the dock itself goes.
    private func sideRail(onRight: Bool) -> some View {
        BottomTabBar(
            selectedTab: $selectedTab,
            searchPath: $searchPath,
            profilePath: $profilePath,
            mediaPath: $mediaPath,
            relayPath: $relayPath,
            configService: configService,
            relayManager: relayManager,
            nostrService: nostrService,
            dmService: dmService,
            feedService: feedService,
            vertical: true,
            railOnRight: onRight
        )
    }

    private var tabs: some View {
        TabView(selection: $selectedTab) {
            Group {
                // In the split, Feed and Relay do not build their own stack
                // (NoteSplitPane owns the detail column), so the list column
                // gets one for their toolbars.
                if usesNoteSplit {
                    noteSplit("Pick a note from the feed to read it here.") {
                        NavigationStack { FeedView() }
                    }
                } else {
                    FeedView()
                }
            }
            .toolbar(.hidden, for: .tabBar)
            .tag(0)

            noteSplit("Pick a note from the results to read it here.") {
                NavigationStack(path: $searchPath) {
                    SearchView()
                        .navigationTitle("")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbarBackground(.hidden, for: .navigationBar)
                        .navigationDestination(for: FeedNote.self) { note in
                            NoteDetailView(note: note)
                        }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .havenFocusSearch)) { _ in
                // ⌘F with a note pushed: pop so SearchView appears and takes the request.
                if !searchPath.isEmpty { searchPath = NavigationPath() }
            }
            .toolbar(.hidden, for: .tabBar)
            .tag(1)

            noteSplit("Pick a note from your profile to read it here.") {
                NavigationStack(path: $profilePath) {
                    MyProfileView(pubkey: activeHex)
                        .navigationTitle("Profile")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbarBackground(.hidden, for: .navigationBar)
                        .navigationDestination(for: FeedNote.self) { note in
                            NoteDetailView(note: note)
                        }
                }
            }
            .id(activeHex)
            // A note pushed on the tab would cover the profile.
            .onReceive(NotificationCenter.default.publisher(for: .havenShowMyProfileTab)) { _ in
                profilePath = NavigationPath()
            }
            .toolbar(.hidden, for: .tabBar)
            .tag(2)

            // Tags keep their old meaning for routing: 4 is the relay (now
            // the Vault tab, with Media inside); 3, Media's old slot, is WOT.
            WOTTabView()
                .toolbar(.hidden, for: .tabBar)
                .tag(3)

            VaultTabView {
                if usesNoteSplit {
                    noteSplit("Pick a note from the relay to read it here.") {
                        NavigationStack { VaultView() }
                    }
                } else {
                    VaultView()
                }
            }
            .toolbar(.hidden, for: .tabBar)
            .tag(4)
        }
        .tint(.havenPurple)
        .toolbar(.hidden, for: .tabBar)
        .environment(\.floatingTabBarHeight, tabBarHeight)
        // The dock's band is safe area on the window's root view controller,
        // so picture-in-picture keeps clear of it (DockSafeAreaInset); the dock
        // is drawn in that band. While typing it rides above the keyboard as a
        // SwiftUI inset, as before. Hidden while typing on any tab (Logen
        // 2026-11-05: a DM thread is a Vault page now, and the dock covered
        // its message box), and on the iPad landscape rail.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if dockPlacement == .swiftUIInset { dock }
        }
        .overlay(alignment: .bottom) {
            if dockPlacement == .rootBand {
                dock.offset(y: rootDockInset)
            }
        }
        .background(DockSafeAreaInset(bottom: rootDockInset))
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            keyboardUp = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardUp = false
        }
        .onAppear {
            if configService.config.hasCompletedSetup && relayManager.state == .idle {
                relayManager.startRelay(config: configService.config)
            }
        }
        .overlay {
            // The Feed, Vault and account hold menus.
            DockHoldMenuOverlay()
        }
        // App settings / Mesh settings picked from the account menus.
        .profileMenuSheets()
        .onChange(of: selectedTab) { _, tab in
            if tab == 0 { feedService.markViewed() }
        }
        .onChange(of: selectedTab, initial: true) { _, tab in
            VaultSection.shared.isOnScreen = tab == 4
        }
        .onDisappear { buttonRow.update(chromeHeight: 0) }
    }
}
