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
    @State private var isLandscapeLayout = UIScreen.main.bounds.width >= UIScreen.main.bounds.height

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
                    // iPad: persistent sidebar in landscape, bottom tab bar in
                    // portrait (where the sidebar collapses and would otherwise
                    // leave no visible navigation).
                    //
                    // The orientation is measured by a keyboard-immune background
                    // reader, NOT by wrapping the content in a GeometryReader:
                    // the on-screen keyboard shrinks a keyboard-avoiding reader's
                    // height, which in full-screen portrait flips width >= height
                    // to true and swaps the entire layout branch — destroying the
                    // @State of whichever view is presenting the compose sheet,
                    // so the sheet dismisses itself the moment its editor focuses.
                    ZStack {
                        if isLandscapeLayout {
                            iPadSidebarView(selectedTab: $selectedTab)
                        } else {
                            iPhoneTabView(selectedTab: $selectedTab)
                        }
                    }
                    .background(
                        GeometryReader { geo in
                            Color.clear
                                .onAppear {
                                    isLandscapeLayout = geo.size.width >= geo.size.height
                                }
                                .onChange(of: geo.size) { _, size in
                                    isLandscapeLayout = size.width >= size.height
                                }
                        }
                        .ignoresSafeArea(.keyboard)
                    )
                } else {
                    iPhoneTabView(selectedTab: $selectedTab)
                }
            }
        }
        .onAppear {
            DMService.shared.startListening()
            // Auto-connect NIP-46 remote signer if configured
            if configService.config.hasCompletedSetup && configService.config.activeSigningMode() == "nip46" {
                NIP46Service.shared.connectFromConfig()
            }
            // A notification tapped on a cold start routes before this view
            // exists, so its tab switch went nowhere; the target is still parked.
            if RelayFocus.pending != nil {
                selectedTab = 4 // Relay tab
            }
            if NotificationNoteOpen.pending != nil {
                selectedTab = 0 // Feed tab pushes the post
            }
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
        .onReceive(NotificationCenter.default.publisher(for: .havenOpenViewer)) { _ in
            selectedTab = 4 // Relay tab
        }
        .onReceive(NotificationCenter.default.publisher(for: .havenOpenFeed)) { _ in
            selectedTab = 0 // Feed tab
        }
        .onReceive(NotificationCenter.default.publisher(for: .havenOpenSearch)) { _ in
            selectedTab = 1 // Search tab
        }
        .onReceive(NotificationCenter.default.publisher(for: .havenOpenMedia)) { _ in
            selectedTab = 3 // Media tab
        }
        .onReceive(NotificationCenter.default.publisher(for: .havenOpenDMInbox)) { note in
            selectedTab = 2 // Profile tab
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
        }
        .onReceive(NotificationCenter.default.publisher(for: .havenOpenRelayLikes)) { _ in
            selectedTab = 4 // Relay tab
        }
        .onReceive(NotificationCenter.default.publisher(for: .havenOpenRelayNotes)) { _ in
            selectedTab = 4 // Relay tab
        }
        .onReceive(NotificationCenter.default.publisher(for: .havenOpenRelayZaps)) { _ in
            selectedTab = 4 // Relay tab
        }
        .sheet(isPresented: $showingDMInbox) {
            NavigationStack {
                DMInboxView(openConversation: dmInboxConversation)
                    .environmentObject(NostrService.shared)
                    .environmentObject(ConfigService.shared)
            }
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

// MARK: - iPad Sidebar View

struct iPadSidebarView: View {
    @Binding var selectedTab: Int
    @EnvironmentObject var configService: ConfigService
    @EnvironmentObject var relayManager: RelayProcessManager
    @StateObject private var nostrService = NostrService.shared
    @StateObject private var feedService = FeedService.shared
    @StateObject private var dmService = DMService.shared
    @State private var showingAccountSwitcher = false
    @State private var searchPath = NavigationPath()
    @State private var profilePath = NavigationPath()

    private var activeHex: String { configService.activeAccountHexPubkey }

    private var isOwner: Bool {
        configService.config.activeAccountNpub.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasMultipleAccounts: Bool {
        configService.allAccountNpubs.count > 1
    }

    @AppStorage(FeedMode.menuOrderKey) private var feedMenuOrder = ""
    @AppStorage(FeedMode.menuHiddenKey) private var feedMenuHidden = ""
    private var menuModes: [FeedMode] { FeedMode.menuModes(order: feedMenuOrder, hidden: feedMenuHidden) }

    /// A sidebar row: one of the feeds (all of which show in the Feed tab),
    /// or one of the other tabs.
    private enum SidebarItem: Hashable {
        case feed(FeedMode)
        case tab(Int)
    }

    private var sidebarSelection: Binding<SidebarItem?> {
        Binding(
            get: { selectedTab == 0 ? .feed(feedService.feedMode) : .tab(selectedTab) },
            set: { item in
                switch item {
                case .feed(let mode):
                    selectedTab = 0
                    feedService.switchMode(mode)
                case .tab(let tab):
                    selectedTab = tab
                case nil:
                    break
                }
            }
        )
    }

    var body: some View {
        NavigationSplitView {
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
                }

                // Each feed is its own row, in the reader's feed-menu order,
                // so the current feed shows here and switching is one tap.
                Section("Feeds") {
                    ForEach(menuModes, id: \.self) { mode in
                        NavigationLink(value: SidebarItem.feed(mode)) {
                            Label(mode.displayName, systemImage: mode.symbolName)
                        }
                    }
                }

                // Navigation tabs, headed so they read apart from the feeds.
                Section("Vault") {
                    NavigationLink(value: SidebarItem.tab(1)) {
                        Label("Search", systemImage: "magnifyingglass")
                    }
                    NavigationLink(value: SidebarItem.tab(2)) {
                        HStack {
                            Label("Profile", systemImage: "person.crop.circle")
                            Spacer()
                            if dmService.totalUnreadCount > 0 {
                                Circle()
                                    .fill(.red)
                                    .frame(width: 8, height: 8)
                            }
                        }
                    }
                    // "My Media" with its own icon: the Media feed above is a
                    // different thing (other people's posts, not your files).
                    NavigationLink(value: SidebarItem.tab(3)) {
                        Label("My Media", systemImage: "photo.stack")
                    }
                    NavigationLink(value: SidebarItem.tab(4)) {
                        HStack {
                            Label("Relay", systemImage: "doc.text.image")
                            Spacer()
                            if relayManager.hasNewRelayActivity {
                                Circle()
                                    .fill(.red)
                                    .frame(width: 8, height: 8)
                            }
                        }
                    }
                    NavigationLink(value: SidebarItem.tab(5)) {
                        Label("Settings", systemImage: "gearshape")
                    }
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
            case 2:
                NavigationStack(path: $profilePath) {
                    NoteSplitPane(
                        emptyTitle: "No Note Selected",
                        emptyMessage: "Pick a note from your profile to read it here."
                    ) {
                        ProfileView(pubkey: activeHex, embeddedInNavigation: false)
                            .navigationTitle("Profile")
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbarBackground(.hidden, for: .navigationBar)
                    }
                    .navigationDestination(for: FeedNote.self) { note in
                        NoteDetailView(note: note)
                    }
                }
                .id(activeHex)
            case 3:
                MediaTabView()
            case 4:
                NoteSplitPane(
                    emptyTitle: "No Note Selected",
                    emptyMessage: "Pick a note from the relay to read it here."
                ) {
                    VaultView()
                }
            case 5:
                NavigationStack {
                    SettingsView(isEmbedded: true)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbarBackground(.hidden, for: .navigationBar)
                }
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
        .onAppear {
            if configService.config.hasCompletedSetup && relayManager.state == .idle {
                relayManager.startRelay(config: configService.config)
            }
        }
        .onChange(of: selectedTab) { _, tab in
            if tab == 0 { feedService.markViewed() }
            if tab == 4 { relayManager.markRelayViewed() }
        }
        .sheet(isPresented: $showingAccountSwitcher) {
            AccountSwitcherView(configService: configService)
        }
        // MARK: - Keyboard Shortcuts
        // Mirrors the Mac app's bindings (MenuBarView.swift) so a Magic Keyboard
        // drives the iPad the same way it drives the desktop. Tab indices here
        // are the sidebar's, which differ from the Mac's tab enum ordering.
        .background {
            Group {
                Button("") { selectedTab = 0 }
                    .keyboardShortcut("1", modifiers: .command)
                Button("") { selectedTab = 1 }
                    .keyboardShortcut("2", modifiers: .command)
                Button("") { selectedTab = 2 }
                    .keyboardShortcut("3", modifiers: .command)
                Button("") { selectedTab = 3 }
                    .keyboardShortcut("4", modifiers: .command)
                Button("") { selectedTab = 4 }
                    .keyboardShortcut("5", modifiers: .command)
                Button("") { selectedTab = 5 }
                    .keyboardShortcut("6", modifiers: .command)
                Button("") { selectedTab = 5 }
                    .keyboardShortcut(",", modifiers: .command)
                Button("") {
                    NotificationCenter.default.post(name: .composeFromTabBar, object: selectedTab)
                }
                    .keyboardShortcut("n", modifiers: .command)
            }
            .frame(width: 0, height: 0)
            .opacity(0)
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
    @StateObject private var dmService = DMService.shared

    @State private var searchPath = NavigationPath()
    @State private var profilePath = NavigationPath()
    @State private var mediaPath = NavigationPath()
    @State private var relayPath = NavigationPath()
    @State private var tabBarHeight: CGFloat = 0
    /// The tab bar alone, without the mini player above it.
    @State private var tabBarOnlyHeight: CGFloat = 0
    @ObservedObject private var buttonRow = FloatingButtonRow.shared

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var activeHex: String { configService.activeAccountHexPubkey }

    private func syncButtonRow() {
        buttonRow.update(tabBarOnlyHeight: tabBarOnlyHeight)
    }

    /// iPad in portrait keeps this tab layout (the sidebar would collapse and
    /// leave no visible navigation), but every iPad is wide enough for the list
    /// and the note side by side, so notes open beside the list there instead
    /// of covering it. iPhone and compact multitasking widths are unchanged.
    private var usesNoteSplit: Bool { horizontalSizeClass == .regular }

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
                // (NoteSplitPane owns the detail column), so the pane needs one
                // for their toolbars.
                if usesNoteSplit {
                    NavigationStack {
                        noteSplit("Pick a note from the feed to read it here.") { FeedView() }
                    }
                } else {
                    FeedView()
                }
            }
            .toolbar(.hidden, for: .tabBar)
            .tag(0)

            NavigationStack(path: $searchPath) {
                noteSplit("Pick a note from the results to read it here.") {
                    SearchView()
                        .navigationTitle("")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbarBackground(.hidden, for: .navigationBar)
                }
                .navigationDestination(for: FeedNote.self) { note in
                    NoteDetailView(note: note)
                }
            }
            .toolbar(.hidden, for: .tabBar)
            .tag(1)

            NavigationStack(path: $profilePath) {
                noteSplit("Pick a note from your profile to read it here.") {
                    ProfileView(pubkey: activeHex, embeddedInNavigation: false)
                        .navigationTitle("Profile")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbarBackground(.hidden, for: .navigationBar)
                }
                .navigationDestination(for: FeedNote.self) { note in
                    NoteDetailView(note: note)
                }
            }
            .id(activeHex)
            .toolbar(.hidden, for: .tabBar)
            .tag(2)

            MediaTabView()
                .toolbar(.hidden, for: .tabBar)
                .tag(3)

            Group {
                if usesNoteSplit {
                    NavigationStack {
                        noteSplit("Pick a note from the relay to read it here.") { VaultView() }
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
                        .onAppear { tabBarHeight = geo.size.height }
                        .onChange(of: geo.size.height) { _, height in tabBarHeight = height }
                }
            )
        }
        .onAppear {
            if configService.config.hasCompletedSetup && relayManager.state == .idle {
                relayManager.startRelay(config: configService.config)
            }
        }
        .overlay {
            FeedHoldPickerOverlay(feedService: feedService) { mode in
                feedService.switchMode(mode)
                selectedTab = 0
            }
        }
        .onChange(of: selectedTab) { _, tab in
            if tab == 0 { feedService.markViewed() }
            if tab == 4 { relayManager.markRelayViewed() }
        }
    }
}

// MARK: - Feed Tab Hold Picker

/// Hold the Feed tab, slide up onto a feed, let go: that feed opens. Let go
/// without moving and the list stays up for a tap; let go anywhere else after
/// sliding and it closes. A plain tap is still the Feed tab.
///
/// The finger never leaves the tab's own drag gesture, so the list does not
/// need to take touches while dragging: the tab hit-tests the finger against
/// the rows' global frames itself.
@MainActor
final class FeedHoldPicker: ObservableObject {
    static let shared = FeedHoldPicker()

    @Published var isOpen = false
    @Published var hovered: FeedMode?
    /// The Feed tab's frame, global coordinates; the list rises from it.
    @Published var anchor: CGRect = .zero
    /// Each row's frame, global coordinates.
    var rowFrames: [FeedMode: CGRect] = [:]

    /// Closest to the finger first: the list grows upward from the tab, so
    /// Following (the usual feed) sits right above it.
    /// In the reader's feed order (Edit Feeds), hidden feeds left out.
    static var order: [FeedMode] { FeedMode.menuModes.reversed() }

    func mode(at point: CGPoint) -> FeedMode? {
        rowFrames.first { $0.value.insetBy(dx: -12, dy: 0).contains(point) }?.key
    }

    func open(from anchor: CGRect) {
        self.anchor = anchor
        hovered = nil
        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) { isOpen = true }
    }

    func close() {
        withAnimation(.easeOut(duration: 0.16)) { isOpen = false }
        hovered = nil
    }
}

private struct FeedTabHoldItem: View {
    let selected: Bool
    @ObservedObject var feedService: FeedService
    let onTap: () -> Void

    @ObservedObject private var picker = FeedHoldPicker.shared
    @State private var frame: CGRect = .zero
    @State private var pressing = false
    @State private var moved = false
    @State private var holdTask: Task<Void, Never>?
    @State private var startedOpen = false

    private static let holdDelay: UInt64 = 300_000_000
    private static let slop: CGFloat = 10

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "person.2.wave.2")
                .font(.appSystem(size: 20, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.havenPurple : .white)
                .frame(height: 24)
            Text("Feed")
                .font(.appSystem(size: 10, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.havenPurple : .white)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .scaleEffect(picker.isOpen ? 1.08 : (pressing ? 0.94 : 1))
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: pressing)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: picker.isOpen)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged(changed)
                .onEnded(ended)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Feed")
        .accessibilityValue(feedService.feedMode.displayName)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint("Hold to pick a feed")
        .accessibilityAction { onTap() }
        .accessibilityActions {
            ForEach(FeedMode.menuModes, id: \.self) { mode in
                Button(mode.displayName) {
                    feedService.switchMode(mode)
                    if !selected { onTap() }
                }
            }
        }
    }

    private func changed(_ value: DragGesture.Value) {
        if !pressing {
            pressing = true
            moved = false
            // A touch that starts while the list is already up (tap mode)
            // picks or dismisses; it does not re-open it.
            startedOpen = picker.isOpen
            holdTask?.cancel()
            holdTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: Self.holdDelay)
                guard !Task.isCancelled, pressing, !moved, !picker.isOpen else { return }
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                picker.open(from: frame)
            }
        }
        let distance = hypot(value.translation.width, value.translation.height)
        if distance > Self.slop { moved = true }
        guard picker.isOpen else {
            // Moved before the hold landed: just a tap that slid off.
            if moved { holdTask?.cancel() }
            return
        }
        let mode = picker.mode(at: value.location)
        if mode != picker.hovered {
            picker.hovered = mode
            if mode != nil { UISelectionFeedbackGenerator().selectionChanged() }
        }
    }

    private func ended(_ value: DragGesture.Value) {
        holdTask?.cancel()
        holdTask = nil
        defer { pressing = false }
        if picker.isOpen && !startedOpen {
            if let mode = picker.mode(at: value.location) {
                select(mode)
            } else if moved {
                picker.close()
            }
            // Held and let go in place: the list stays up for a tap.
            return
        }
        if picker.isOpen {
            // Tap on the Feed tab while the list is up: dismiss it.
            picker.close()
            return
        }
        if !moved && frame.contains(value.location) { onTap() }
    }

    private func select(_ mode: FeedMode) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        picker.close()
        if mode != feedService.feedMode { feedService.switchMode(mode) }
        if !selected { onTap() }
    }
}

/// The list itself, drawn over the whole screen so it can rise above the bar.
private struct FeedHoldPickerOverlay: View {
    @ObservedObject var feedService: FeedService
    let onSelect: (FeedMode) -> Void
    @ObservedObject private var picker = FeedHoldPicker.shared

    var body: some View {
        GeometryReader { geo in
            let space = geo.frame(in: .global)
            ZStack(alignment: .bottomLeading) {
                if picker.isOpen {
                    Color.black.opacity(0.28)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture { picker.close() }
                        .transition(.opacity)

                    list
                        .padding(.leading, max(12, picker.anchor.minX - space.minX))
                        .padding(.bottom, max(12, space.maxY - picker.anchor.minY + 10))
                        .transition(
                            .scale(scale: 0.6, anchor: .bottomLeading)
                                .combined(with: .opacity)
                        )
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .bottomLeading)
        }
        .ignoresSafeArea()
        .allowsHitTesting(picker.isOpen)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(FeedHoldPicker.order, id: \.self) { mode in
                row(mode)
            }
        }
        .padding(6)
        .fixedSize()
        .applyGlassRect(cornerRadius: 22)
        .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
    }

    private func row(_ mode: FeedMode) -> some View {
        let current = feedService.feedMode == mode
        let hovered = picker.hovered == mode
        return Button {
            picker.close()
            onSelect(mode)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: mode.symbolName)
                    .font(.appSystem(size: 16, weight: .semibold))
                    .frame(width: 24)
                Text(mode.displayName)
                    .font(.appSystem(size: 16, weight: current ? .bold : .medium))
                Spacer(minLength: 16)
                if current {
                    Image(systemName: "checkmark")
                        .font(.appSystem(size: 13, weight: .bold))
                }
            }
            .foregroundStyle(hovered ? Color.white : (current ? Color.havenPurple : Color.primary))
            .padding(.horizontal, 14)
            .frame(width: 210, height: 42)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(hovered ? Color.havenPurple : Color.clear)
            )
            .scaleEffect(hovered ? 1.04 : 1, anchor: .leading)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: hovered)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { picker.rowFrames[mode] = $0 }
    }
}

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

        tabItem(index: 3, title: "Media", icon: "photo.on.rectangle") {
            if !mediaPath.isEmpty {
                mediaPath = NavigationPath()
            } else {
                NotificationCenter.default.post(name: NSNotification.Name("MediaScrollToTop"), object: nil)
            }
        }

        tabItem(index: 4, title: "Relay", icon: "doc.text.image", hasRedBadge: relayManager.hasNewRelayActivity) {
            if !relayPath.isEmpty {
                relayPath = NavigationPath()
            } else {
                relayManager.markRelayViewed()
                NotificationCenter.default.post(name: NSNotification.Name("RelayScrollToTop"), object: nil)
            }
        }
    }

    // MARK: - Collapsed Content

    /// Feed, Search and Profile compose; Media opens its Blossom dashboard
    /// (the same as Android); Relay opens the relay dashboard.
    private var collapsedFABIcon: String {
        switch selectedTab {
        case ...2: return "square.and.pencil"
        case 3: return "camera.macro"
        default: return "antenna.radiowaves.left.and.right"
        }
    }

    private var collapsedFABColor: Color {
        selectedTab == 4 ? relayStatusColor : Color.havenPurple
    }

    private var collapsedFABLabel: String {
        switch selectedTab {
        case ...2: return "Compose new post"
        case 3: return "Blossom Dashboard"
        default: return "Relay Dashboard"
        }
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
                        if dmService.totalUnreadCount > 0 || relayManager.hasNewRelayActivity {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 10, height: 10)
                                .offset(x: 2, y: -2)
                        }
                    }
            }

            // Contextual FAB icon — triggers compose or relay dashboard
            Button {
                switch selectedTab {
                case ...2:
                    NotificationCenter.default.post(name: .composeFromTabBar, object: selectedTab)
                case 3:
                    NotificationCenter.default.post(name: .openBlossomDashboard, object: selectedTab)
                default:
                    NotificationCenter.default.post(name: .openRelayDashboard, object: selectedTab)
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

    // MARK: - Tab Item

    private func tabItem(index: Int, title: String, icon: String, hasRedBadge: Bool = false, onReselect: @escaping () -> Void) -> some View {
        let selected = selectedTab == index
        return Button {
            if selectedTab == index {
                onReselect()
            } else {
                selectedTab = index
            }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.appSystem(size: 20, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.havenPurple : .white)
                    .frame(height: 24)
                    .overlay(alignment: .topTrailing) {
                        if hasRedBadge {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 8, height: 8)
                                .offset(x: 4, y: -2)
                        }
                    }
                Text(title)
                    .font(.appSystem(size: 10, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.havenPurple : .white)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Expanded Profile Tab Item

    private var expandedProfileTabItem: some View {
        let selected = selectedTab == 2
        return accountSwitchButton {
            if selectedTab == 2 {
                if !profilePath.isEmpty {
                    profilePath = NavigationPath()
                } else {
                    NotificationCenter.default.post(name: NSNotification.Name("ProfileScrollToTop"), object: nil)
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
                    .overlay(alignment: .topTrailing) {
                        if dmService.totalUnreadCount > 0 {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 8, height: 8)
                                .offset(x: 4, y: -2)
                        }
                    }
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
        let name = nostrService.profiles[hex]?.bestName ?? (isOwner ? "Owner" : String(npub.prefix(8)))

        return Button {
            configService.switchActiveAccount(to: npub)
        } label: {
            if isCurrent {
                Label(name, systemImage: "checkmark")
            } else {
                Text(name)
            }
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

// MARK: - Note Split Pane

/// Column widths for [NoteSplitPane]. A separate type because static stored
/// properties are not allowed in a generic one.
private enum NoteSplitMetrics {
    /// Leaves a readable note column on the narrowest iPad in landscape
    /// (1133pt) once the sidebar has claimed its ~320pt.
    static let defaultList: Double = 380
    /// Floors, not preferences: below these a column stops being usable. The
    /// list floor is about one full note row; the detail floor is roughly the
    /// width at which a note's text stops wrapping into a readable measure.
    static let minList: Double = 280
    static let minDetail: Double = 360
}

/// iPad two-pane note layout: the scrolling list on the left, the selected note
/// held open on the right.
///
/// This is what separates an iPad layout from a stretched phone one. Without it
/// the list occupies the entire detail pane and tapping a note pushes the note
/// over all of it, so only one of the two things you are reading is ever on
/// screen. The pane publishes a `NoteDetailSelection` into the environment;
/// `NoteNavigationLink` and the views that open notes by id pick it up and
/// select instead of pushing.
struct NoteSplitPane<Content: View>: View {
    /// Placeholder shown in the detail column before anything is selected.
    let emptyTitle: String
    let emptyMessage: String
    @ViewBuilder var content: () -> Content

    @StateObject private var selection = NoteDetailSelection()

    /// Width of the list column, dragged by the reader and remembered across
    /// launches. The default leaves a readable note column on the narrowest
    /// iPad in landscape (1133pt) once the sidebar has claimed its ~320pt.
    @AppStorage("ipad.noteSplit.listWidth") private var listWidth: Double = NoteSplitMetrics.defaultList

    /// Width when the current drag began, so the column tracks the finger
    /// exactly instead of accelerating away from it (a drag reports total
    /// translation from its start, not a delta since the last callback).
    @State private var dragStartWidth: Double?

    /// The reader folded the note column away to give the list the whole
    /// pane. Remembered across launches; opening a note brings the column back.
    @AppStorage("ipad.noteSplit.detailHidden") private var detailHidden = false

    var body: some View {
        GeometryReader { geo in
            // The ceiling depends on the pane's real width, which changes with
            // rotation, Split View and the sidebar collapsing. Clamping on read
            // means a width saved on a wide layout can't strand the detail
            // column off-screen on a narrow one — and it is restored, not
            // overwritten, when there is room again.
            let maxListWidth = max(NoteSplitMetrics.minList, geo.size.width - NoteSplitMetrics.minDetail)
            let width = min(max(listWidth, NoteSplitMetrics.minList), maxListWidth)

            HStack(spacing: 0) {
                content()
                    .frame(width: detailHidden ? geo.size.width : width)
                    .environment(\.noteDetailSelection, selection)

                if !detailHidden {
                    resizeHandle(maxListWidth: maxListWidth)
                        // The fold tab is wider than the handle; keep the
                        // detail column from drawing over (and taking taps
                        // from) the half that overhangs it.
                        .zIndex(1)

                    detailColumn
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.move(edge: .trailing))
                }
            }
            // GeometryReader hands its child the full space but does not force
            // it to fill: without this the row sizes to its content and the
            // handle has nothing to span.
            .frame(width: geo.size.width, height: geo.size.height)
            .overlay(alignment: .trailing) {
                if detailHidden {
                    detailToggle
                }
            }
            .clipped()
        }
        .onChange(of: selection.note?.id) { _, id in
            if id != nil { setDetailHidden(false) }
        }
        .onChange(of: selection.noteId) { _, id in
            if id != nil { setDetailHidden(false) }
        }
    }

    private func setDetailHidden(_ hidden: Bool) {
        guard hidden != detailHidden else { return }
        withAnimation(.easeInOut(duration: 0.25)) { detailHidden = hidden }
    }

    /// The tab that folds the note column away, or brings it back. It sits on
    /// the divider while the column is open and on the pane's trailing edge
    /// while it is folded, vertically centred so it stays clear of the
    /// navigation bar, which would otherwise take its taps.
    private var detailToggle: some View {
        Button {
            setDetailHidden(!detailHidden)
        } label: {
            Image(systemName: detailHidden ? "chevron.left" : "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 56)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color(uiColor: .separator), lineWidth: 0.5))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .padding(.trailing, detailHidden ? 4 : 0)
        .accessibilityLabel(detailHidden ? "Show note" : "Hide note")
    }

    /// The draggable divider. A plain `Divider()` is one hairline wide and
    /// cannot be hit with a finger, so the visible line stays hairline while the
    /// gesture is attached to 14pt of clear space around it, with a grip so the
    /// column is discoverably resizable rather than secretly so.
    private func resizeHandle(maxListWidth: Double) -> some View {
        ZStack {
            Color.clear
            Rectangle()
                .fill(Color(uiColor: .separator))
                .frame(width: 1)
            // The fold tab doubles as the drag grip's centre mark.
            detailToggle
        }
        .frame(width: 14)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    let start = dragStartWidth ?? listWidth
                    dragStartWidth = start
                    listWidth = min(max(start + value.translation.width, NoteSplitMetrics.minList), maxListWidth)
                }
                .onEnded { _ in dragStartWidth = nil }
        )
        .onTapGesture(count: 2) { listWidth = NoteSplitMetrics.defaultList }
        .accessibilityLabel("Resize note list")
        .accessibilityHint("Drag to change the width of the list. Double tap to reset.")
    }

    @ViewBuilder
    private var detailColumn: some View {
        if let note = selection.note {
            // No selection injected here on purpose: links inside the detail
            // column push onto its own stack rather than replacing the note the
            // reader is looking at.
            NavigationStack {
                // A long-form event opens in the reader, not as a note. This is
                // what makes tapping an Articles card do something on iPad.
                if note.kind == 30023 {
                    ArticleReaderView(note: note)
                        .environmentObject(NostrService.shared)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbarBackground(.hidden, for: .navigationBar)
                } else {
                    NoteDetailView(note: note)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbarBackground(.hidden, for: .navigationBar)
                    .navigationDestination(for: FeedNote.self) { pushed in
                        NoteDetailView(note: pushed)
                    }
                }
            }
            .id(note.id)
        } else if let noteId = selection.noteId {
            NoteDetailViewWrapper(noteId: noteId, onDismiss: { selection.clear() })
                .environmentObject(NostrService.shared)
                .environmentObject(ConfigService.shared)
                .id(noteId)
        } else {
            ContentUnavailableView(
                emptyTitle,
                systemImage: "text.bubble",
                description: Text(emptyMessage)
            )
        }
    }
}
