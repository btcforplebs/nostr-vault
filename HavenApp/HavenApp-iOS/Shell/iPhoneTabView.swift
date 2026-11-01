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
    /// The software keyboard is on screen. The bottom inset follows it up,
    /// so on Search the tab bar would sit over the results while typing.
    @State private var keyboardUp = false
    private var hidesChromeForKeyboard: Bool { keyboardUp && selectedTab == 1 }

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var activeHex: String { configService.activeAccountHexPubkey }

    private func syncButtonRow() {
        buttonRow.update(tabBarOnlyHeight: tabBarOnlyHeight)
    }

    /// The window is wider than tall. Measured on the whole window, so the
    /// keyboard coming up doesn't change it.
    @State private var isLandscape = false

    /// iPad in landscape: an opened note shows beside the list, in a
    /// `NoteSplitPane`. Everywhere else, portrait iPad included, the tabs are
    /// the phone's and a note pushes over the list. `horizontalSizeClass` is
    /// read before `body` sets every screen to compact, so it is the real one.
    private var usesNoteSplit: Bool { horizontalSizeClass == .regular && isLandscape }

    /// The tab's list in a `NoteSplitPane` when `usesNoteSplit`, otherwise as is.
    @ViewBuilder
    private func noteSplit<Content: View>(
        _ emptyMessage: String,
        @ViewBuilder _ content: @escaping () -> Content
    ) -> some View {
        if usesNoteSplit {
            NoteSplitPane(emptyTitle: "No Note Selected", emptyMessage: emptyMessage, content: content)
        } else {
            content()
        }
    }

    var body: some View {
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
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // The music mini player rides above the tab bar on every tab.
            // Measured together, so screens inset for both.
            // Hidden while typing on Search, so results get the space.
            if !hidesChromeForKeyboard {
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
                        .onDisappear { tabBarHeight = 0; buttonRow.update(chromeHeight: 0) }
                        .onChange(of: geo.size.height) { _, height in
                            tabBarHeight = height
                            buttonRow.update(chromeHeight: height)
                        }
                }
            )
            }
        }
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
            // The Feed and Vault tabs' hold menus.
            DockHoldMenuOverlay()
        }
        .onChange(of: selectedTab) { _, tab in
            if tab == 0 { feedService.markViewed() }
        }
        .onChange(of: selectedTab, initial: true) { _, tab in
            VaultSection.shared.isOnScreen = tab == 4
        }
        .onDisappear { buttonRow.update(chromeHeight: 0) }
        .background {
            GeometryReader { geo in
                Color.clear
                    .onAppear { isLandscape = geo.size.width > geo.size.height }
                    .onChange(of: geo.size) { _, size in isLandscape = size.width > size.height }
            }
            .ignoresSafeArea()
        }
        // The iPad is laid out like the iPhone: same headers, same buttons,
        // no system toolbar row. Screens branch on the width class for that,
        // so every one below sees compact.
        .environment(\.horizontalSizeClass, .compact)
    }
}
