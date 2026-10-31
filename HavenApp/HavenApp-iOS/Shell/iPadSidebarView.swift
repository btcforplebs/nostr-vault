import SwiftUI
import UIKit

// MARK: - iPad Sidebar View

struct iPadSidebarView: View {
    @Binding var selectedTab: Int
    @EnvironmentObject var configService: ConfigService
    @EnvironmentObject var relayManager: RelayProcessManager
    /// The WoT globe's frame. The sidebar draws its row symbols large (the
    /// Profile circle measures 21.5pt), so 26pt puts the globe's circle at
    /// the same size; it grows with Dynamic Type as they do.
    @ScaledMetric(relativeTo: .body) private var wotIconSide: CGFloat = 26
    @StateObject private var nostrService = NostrService.shared
    @StateObject private var feedService = FeedService.shared
    @StateObject private var dmService = DMService.shared
    @ObservedObject private var unreadStore = AccountUnreadStore.shared
    /// The avatar's purple dot: an account you are not on has news.
    private var otherAccountHasNews: Bool {
        unreadStore.othersHaveUnread(npubs: configService.allAccountNpubs, activeHex: activeHex)
    }
    /// The Vault row's dot: something came in, a new message included.
    private var vaultHasNews: Bool {
        relayManager.hasNewRelayActivity || dmService.totalUnreadCount > 0
    }
    @State private var showingAccountSwitcher = false
    @State private var searchPath = NavigationPath()
    @State private var profilePath = NavigationPath()
    /// Every column, in portrait too: the default there slides the sidebar
    /// away and leaves no visible navigation. The reader can still fold it
    /// with the toolbar button or ⌃⌘S.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    /// ⌘N or New Post on a tab with no composer of its own (WoT, Vault,
    /// Settings). Feed, Search and Profile answer `.composeFromTabBar` themselves.
    @State private var showingCompose = false

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

    private var relayStatusText: String {
        if relayManager.isBooting {
            return "Starting"
        } else if relayManager.isRunning && relayManager.isWotSyncing {
            return "Syncing"
        } else if relayManager.isRunning {
            return "Running"
        } else {
            return "Stopped"
        }
    }

    /// A read-only sign-in can't sign a post, so ⌘N does nothing for it.
    private func composeNewPost() {
        guard configService.activeAccountCanSign else { return }
        NotificationCenter.default.post(name: .composeFromTabBar, object: selectedTab)
    }

    private func toggleSidebar() {
        withAnimation {
            columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
        }
    }

    private var isOwner: Bool {
        configService.config.activeAccountNpub.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasMultipleAccounts: Bool {
        configService.allAccountNpubs.count > 1
    }

    /// A sidebar row: one of the tabs. Feeds are switched from the feed's
    /// own picker, so the sidebar has a single Feed row.
    private enum SidebarItem: Hashable {
        case tab(Int)
    }

    private var sidebarSelection: Binding<SidebarItem?> {
        Binding(
            get: { .tab(selectedTab) },
            set: { item in
                switch item {
                case .tab(let tab):
                    if tab == 3 && selectedTab == 3 {
                        NotificationCenter.default.post(name: .wotTabReselected, object: nil)
                    }
                    if tab == 4 && selectedTab != 4 && relayManager.hasNewRelayActivity {
                        VaultSection.shared.opensNewActivity = true
                    }
                    selectedTab = tab
                case nil:
                    break
                }
            }
        )
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: sidebarSelection) {
                // Account switcher section
                Section {
                    Button {
                        if hasMultipleAccounts {
                            showingAccountSwitcher.toggle()
                        }
                    } label: {
                        HStack(spacing: 12) {
                            AvatarView(
                                url: nostrService.profiles[activeHex]?.pictureURL,
                                pubkey: activeHex,
                                size: 32
                            )
                            .id(activeHex)
                            .zapFlightOrigin()
                            .overlay(
                                Circle()
                                    .stroke(
                                        isOwner ? Color.havenPurple.opacity(0.4) : Color.orange.opacity(0.8),
                                        lineWidth: isOwner ? 1.5 : 2
                                    )
                            )
                            .overlay(alignment: .bottomTrailing) {
                                NewsDot(isShown: otherAccountHasNews, size: 9, color: NewsDot.otherAccount)
                                    .offset(x: 2, y: 2)
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text(nostrService.profiles[activeHex]?.bestName ?? (isOwner ? "Owner" : "User"))
                                    .font(.appSystem(size: 13, weight: .semibold))
                                    .lineLimit(1)
                                Text(isOwner ? "Owner Key" : "Whitelisted")
                                    .font(.appSystem(size: 10))
                                    .foregroundColor(.secondary)
                            }

                            Spacer()

                            if hasMultipleAccounts {
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.appSystem(size: 10))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(otherAccountHasNews ? "Another account has news" : "")

                    // The phone's floating Post button, which this layout has
                    // no bar for. Same path as ⌘N. None for a read-only sign-in.
                    if configService.activeAccountCanSign {
                        Button(action: composeNewPost) {
                            Label("New Post", systemImage: "square.and.pencil")
                                .font(.appSystem(size: 15, weight: .semibold))
                                .foregroundStyle(Color.havenPurple)
                        }
                        .accessibilityHint("Write a new post")
                    }

                    // On the phone the inbox opens from the Vault tab's
                    // Messages button; here it also gets its own row, with
                    // the unread count.
                    Button {
                        NotificationCenter.default.post(name: .havenOpenDMInbox, object: nil)
                    } label: {
                        HStack {
                            Label("Messages", systemImage: "envelope")
                                .foregroundStyle(Color.primary)
                            Spacer()
                            if dmService.totalUnreadCount > 0 {
                                Text("\(dmService.totalUnreadCount)")
                                    .font(.appSystem(size: 12, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(.red))
                                    .accessibilityLabel("\(dmService.totalUnreadCount) unread")
                            }
                        }
                    }
                }

                Section("Vault") {
                    NavigationLink(value: SidebarItem.tab(0)) {
                        Label("Feed", systemImage: "list.bullet.rectangle.portrait")
                    }
                    NavigationLink(value: SidebarItem.tab(1)) {
                        Label("Search", systemImage: "magnifyingglass")
                    }
                    NavigationLink(value: SidebarItem.tab(2)) {
                        Label("Profile", systemImage: "person.crop.circle")
                    }
                    NavigationLink(value: SidebarItem.tab(3)) {
                        Label {
                            Text("WoT")
                        } icon: {
                            // A template image doesn't follow the font like an SF Symbol does.
                            Image("WoTTab")
                                .resizable()
                                .frame(width: wotIconSide, height: wotIconSide)
                        }
                    }
                    // Your relay and your Blossom files, one row; "My Media" is
                    // a mode inside it. Tag 4 is the old Relay row's, so
                    // notification routing still lands here.
                    NavigationLink(value: SidebarItem.tab(4)) {
                        HStack {
                            Label("Vault", systemImage: VaultDashboard.symbol)
                            Spacer()
                            NewsDot(isShown: vaultHasNews, ring: 0)
                        }
                        // What the return pill's arrow points at.
                        .vaultAnchor(.leading)
                    }
                    .accessibilityValue(vaultHasNews ? "New activity" : "")
                    NavigationLink(value: SidebarItem.tab(5)) {
                        Label("Settings", systemImage: "gearshape")
                    }
                }

                // The Mac sidebar's footer: is your relay up, and a restart
                // without a trip to the Vault dashboard.
                Section("Relay") {
                    HStack(spacing: 10) {
                        Circle()
                            .fill(relayStatusColor)
                            .frame(width: 8, height: 8)
                        Text(relayStatusText)
                            .font(.appSystem(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Relay \(relayStatusText)")

                    Button {
                        if relayManager.isRunning {
                            relayManager.stopRelay {
                                relayManager.startRelay(config: configService.config)
                            }
                        } else {
                            relayManager.startRelay(config: configService.config)
                        }
                    } label: {
                        Label(
                            relayManager.isRunning ? "Restart Vault" : "Start Vault",
                            systemImage: relayManager.isRunning ? "arrow.clockwise.circle" : "play.circle"
                        )
                        .foregroundStyle(relayManager.isRunning ? Color.orange : Color.green)
                    }
                    .disabled(relayManager.isBooting)
                }
            }
            .navigationTitle("Nostr Vault")
        } detail: {
            switch selectedTab {
            case 0:
                NoteSplitPane(
                    emptyTitle: "No Note Selected",
                    emptyMessage: "Pick a note from the feed to read it here."
                ) {
                    FeedView()
                }
            case 1:
                NavigationStack(path: $searchPath) {
                    NoteSplitPane(
                        emptyTitle: "No Note Selected",
                        emptyMessage: "Pick a note from the results to read it here."
                    ) {
                        SearchView()
                            .navigationTitle("Search")
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbarBackground(.hidden, for: .navigationBar)
                    }
                    .navigationDestination(for: FeedNote.self) { note in
                        NoteDetailView(note: note)
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .havenFocusSearch)) { _ in
                    // ⌘F with a note pushed: pop so SearchView appears and takes the request.
                    if !searchPath.isEmpty { searchPath = NavigationPath() }
                }
                .modifier(MiniPlayerInset())
            case 2:
                NavigationStack(path: $profilePath) {
                    NoteSplitPane(
                        emptyTitle: "No Note Selected",
                        emptyMessage: "Pick a note from your profile to read it here."
                    ) {
                        MyProfileView(pubkey: activeHex)
                            .navigationTitle("Profile")
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbarBackground(.hidden, for: .navigationBar)
                    }
                    .navigationDestination(for: FeedNote.self) { note in
                        NoteDetailView(note: note)
                    }
                }
                .id(activeHex)
                // A note pushed on the tab would cover the profile.
                .onReceive(NotificationCenter.default.publisher(for: .havenShowMyProfileTab)) { _ in
                    profilePath = NavigationPath()
                }
                .modifier(MiniPlayerInset())
            case 3:
                WOTTabView()
                    .modifier(MiniPlayerInset())
            case 4:
                VaultTabView {
                    NoteSplitPane(
                        emptyTitle: "No Note Selected",
                        emptyMessage: "Pick a note from the relay to read it here."
                    ) {
                        VaultView()
                    }
                }
                .modifier(MiniPlayerInset())
            case 5:
                NavigationStack {
                    SettingsView(isEmbedded: true)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbarBackground(.hidden, for: .navigationBar)
                }
                .modifier(MiniPlayerInset())
            default:
                NoteSplitPane(
                    emptyTitle: "No Note Selected",
                    emptyMessage: "Pick a note from the feed to read it here."
                ) {
                    FeedView()
                }
            }
        }
        // The same tint the compact layout applies to its TabView. Without it
        // the split view's sidebar falls back to the system accent -- and there
        // is nothing app-wide to fall back to, since AccentColor.colorset is not
        // named in Info.plist -- so every sidebar row drew in iOS blue while the
        // rest of the app was Sunset Orange.
        .tint(.havenPurple)
        // Side by side in portrait as well; the automatic style there lays
        // the sidebar over the content.
        .navigationSplitViewStyle(.balanced)
        .onAppear {
            if configService.config.hasCompletedSetup && relayManager.state == .idle {
                relayManager.startRelay(config: configService.config)
            }
        }
        .onChange(of: selectedTab) { _, tab in
            if tab == 0 { feedService.markViewed() }
        }
        .onChange(of: selectedTab, initial: true) { _, tab in
            VaultSection.shared.isOnScreen = tab == 4
        }
        .sheet(isPresented: $showingAccountSwitcher) {
            AccountSwitcherView(configService: configService)
        }
        .onReceive(NotificationCenter.default.publisher(for: .composeFromTabBar)) { note in
            // 0-2 are Feed, Search and Profile, which open their own composer.
            guard let tab = note.object as? Int, tab >= 3, configService.activeAccountCanSign else { return }
            showingCompose = true
        }
        .sheet(isPresented: $showingCompose) {
            ComposeView(onDismiss: { showingCompose = false })
                .environmentObject(nostrService)
                .environmentObject(configService)
        }
        // MARK: - Keyboard Shortcuts
        // Mirrors the Mac app's bindings (MenuBarView.swift) so a Magic Keyboard
        // drives the iPad the same way it drives the desktop. Tab indices here
        // are the sidebar's, which differ from the Mac's tab enum ordering.
        // Titled, so holding ⌘ lists them by name.
        .background {
            Group {
                Button("Feed") { selectedTab = 0 }
                    .keyboardShortcut("1", modifiers: .command)
                Button("Search") { selectedTab = 1 }
                    .keyboardShortcut("2", modifiers: .command)
                Button("Profile") { selectedTab = 2 }
                    .keyboardShortcut("3", modifiers: .command)
                // ⌘4 Vault, ⌘5 WOT: the sidebar's order, not the tags'.
                Button("Vault") { selectedTab = 4 }
                    .keyboardShortcut("4", modifiers: .command)
                Button("WoT") { selectedTab = 3 }
                    .keyboardShortcut("5", modifiers: .command)
                Button("Settings") { selectedTab = 5 }
                    .keyboardShortcut("6", modifiers: .command)
                Button("Settings") { selectedTab = 5 }
                    .keyboardShortcut(",", modifiers: .command)
                Button("New Post", action: composeNewPost)
                    .keyboardShortcut("n", modifiers: .command)
                Button("Toggle Sidebar", action: toggleSidebar)
                    .keyboardShortcut("s", modifiers: [.command, .control])
            }
            .frame(width: 0, height: 0)
            .opacity(0)
        }
    }
}
