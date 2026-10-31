import SwiftUI

struct MenuBarView: View {
    @ObservedObject var configService: ConfigService
    @ObservedObject var relayManager: RelayProcessManager
    @ObservedObject var feedService = FeedService.shared
    #if os(macOS)
    @State var selectedTab: Tab = .relay
    #else
    @State var selectedTab: Tab = .feed
    #endif
    @State var settingsPaneRequest: SettingsView.SettingsTab?
    #if os(macOS)
    @Environment(\.openSettings) var openSettings
    @Environment(\.openWindow) var openWindow
    #else
    @Environment(\.horizontalSizeClass) var horizontalSizeClass
    #endif
    var isPoppedOut: Bool = false
    
    @ObservedObject var nostrService = NostrService.shared
    // Rebuilds the account menu once each account's picture is cached.
    @ObservedObject var accountAvatars = AccountMenuAvatars.shared
    @ObservedObject var unreadStore = AccountUnreadStore.shared
    @State var statusPulse = false
    @State private var showingOwnProfile = false
    @State var showingAccountSwitcher = false
    #if os(macOS)
    @State var showingCompose = false
    /// The DM inbox is a sheet on this view, not on ProfileView, for the same
    /// reason iOS presents it from ContentView: a notification route has to be
    /// able to open it without depending on which tab happens to be mounted.
    @State private var showingDMInbox = false
    @State private var dmInboxConversation: String?
    /// macOS has no navigation stack around the feed and vault, so a
    /// `NavigationLink(value:)` inside a note row has nothing to push onto and the
    /// click is swallowed — quoted notes and parent previews did nothing at all.
    /// Publishing a selection here gives every one of those rows the same single
    /// path the iPad two-pane layout already uses, resolved to a sheet below.
    @StateObject private var noteSelection = NoteDetailSelection()
    #endif

    @State var activeHex: String = ConfigService.shared.activeAccountHexPubkey

    private var usesSidebarLayout: Bool {
        #if os(macOS)
        return isPoppedOut
        #else
        return horizontalSizeClass == .regular
        #endif
    }

    var isOwner: Bool {
        configService.config.activeAccountNpub.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    
    var hasMultipleAccounts: Bool {
        configService.allAccountNpubs.count > 1
    }
    
    enum Tab {
        case feed
        case search
        case media
        case profile
        case relay
        case notes
        case settings
    }
    
    var body: some View {
        ZStack {
            Group {
                if isPoppedOut || usesSidebarLayout {
                    sidebarLayout
                } else {
                    tabBarLayout
                }
            }
            .disabled(relayManager.isImporting) // Disable interaction when importing

            importOverlay

            processKillAlertOverlay
        }
        .overlay(alignment: .top) {
            PillLaneStack()
                .padding(.top, 4)
        }
        .overlay { ZapFlightStage() }
        .hashtagLinks()
        .task(id: AccountMenuAvatars.pictureURLs(npubs: configService.allAccountNpubs, profiles: nostrService.profiles)) {
            accountAvatars.prefetch(AccountMenuAvatars.pictureURLs(npubs: configService.allAccountNpubs, profiles: nostrService.profiles))
        }
        #if os(macOS)
        .environment(\.noteDetailSelection, noteSelection)
        .sheet(isPresented: Binding(
            get: { !noteSelection.isEmpty },
            set: { if !$0 { noteSelection.clear() } }
        )) {
            Group {
                if let note = noteSelection.note {
                    NavigationStack {
                        NoteDetailView(note: note)
                            .toolbar {
                                ToolbarItem(placement: .cancellationAction) {
                                    Button("Done") { noteSelection.clear() }
                                        .keyboardShortcut(.cancelAction)
                                }
                            }
                    }
                } else if let noteId = noteSelection.noteId {
                    NoteDetailViewWrapper(noteId: noteId, onDismiss: { noteSelection.clear() })
                }
            }
            .environmentObject(nostrService)
            .environmentObject(configService)
            .frame(minWidth: 560, minHeight: 620)
        }
        .sheet(isPresented: $showingCompose) {
            ComposeView(onDismiss: { showingCompose = false })
                .environmentObject(nostrService)
                .environmentObject(configService)
        }
        .sheet(isPresented: $showingDMInbox) {
            DMInboxView(openConversation: dmInboxConversation)
                .environmentObject(nostrService)
                .environmentObject(configService)
                .frame(minWidth: 480, minHeight: 500)
        }
        // Your own profile, opened from a note or a list: the tab, where editing is.
        .onReceive(NotificationCenter.default.publisher(for: .havenShowMyProfileTab)) { _ in
            selectedTab = .profile
        }
        // Notification taps: LocalNotificationService posts these on both platforms,
        // but until now only iOS listened, so clicking a zap, reaction or repost
        // notification on macOS did nothing at all.
        .onReceive(NotificationCenter.default.publisher(for: .havenOpenRelayLikes)) { _ in
            selectedTab = .notes
        }
        .onReceive(NotificationCenter.default.publisher(for: .havenOpenRelayNotes)) { _ in
            selectedTab = .notes
        }
        .onReceive(NotificationCenter.default.publisher(for: .havenOpenRelayZaps)) { _ in
            selectedTab = .notes
        }
        .onReceive(NotificationCenter.default.publisher(for: .havenOpenRelayFollowers)) { _ in
            selectedTab = .notes
        }
        .onReceive(NotificationCenter.default.publisher(for: .havenOpenMentions)) { notification in
            selectedTab = .feed
            if let eventId = notification.object as? String {
                noteSelection.select(id: eventId)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .havenOpenDMInbox)) { note in
            // Matches iOS: the profile tab comes up behind the inbox, so
            // dismissing the sheet leaves you somewhere related rather than on
            // whatever tab you happened to be on when the message arrived.
            selectedTab = .profile
            dmInboxConversation = note.object as? String
            showingDMInbox = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .composeFromTabBar)) { note in
            // Clear the pending-compose flag before the tab guard, not after.
            // The window is on screen if this fires, so `onAppear` will not run
            // again to consume it — and when the Search tab is showing,
            // SearchView answers this notification instead of us. Clearing after
            // the guard left the flag set in exactly that case, so the next time
            // the window was closed and reopened it mounted with a composer
            // nobody asked for.
            guard (note.object as? Int) == 1 else { return }
            MacWindow.pendingCompose = false
            // SearchView owns object == 1 while it's on screen (selectedTab == .search);
            // for every other tab this is the only listener, so ⌘N works app-wide.
            guard selectedTab != .search, configService.activeAccountCanSign else { return }
            showingCompose = true
        }
        .onAppear {
            FloatingArrowController.shared.dismiss()
            DMService.shared.startListening()
            #if os(macOS)
            MacWindow.isMainWindowMounted = true
            MacWindow.openWindowAction = openWindow
            // The status panel asks for a composer by setting this before the
            // window exists; this is the first moment a receiver could hear it.
            if MacWindow.consumePendingCompose(), configService.activeAccountCanSign {
                showingCompose = true
            }
            // A notification tapped while this window did not exist left its
            // route here rather than posting it to nobody. Replayed as a post,
            // not as direct state, so a tap takes the same path either way —
            // one main-queue hop so this view's own receivers are subscribed.
            if let route = MacWindow.consumePendingRoute() {
                DispatchQueue.main.async {
                    LocalNotificationService.navigate(type: route.type, id: route.id, npub: route.npub)
                }
            }
            #endif
        }
        .onDisappear {
            #if os(macOS)
            MacWindow.isMainWindowMounted = false
            // The pills went with the window: file the ones still up.
            RelayActivityNotificationManager.shared.hostLost()
            #endif
        }
        // Service pausing/resuming on focus change is owned by
        // AppDelegate.startFocusLifecycleObservers(); this view is mounted only
        // by the window scene, so it is the wrong owner for app-wide lifecycle.
        //
        // The 60s "reset to the relay tab on resign" timer that used to live here
        // is gone too. It was written for the menu bar dropdown, where returning
        // to a status view after you look away is reasonable. That surface is now
        // MenuBarStatusView and never used this timer. What was left was a window
        // that silently threw away your tab if you spent a minute in another app —
        // switch to Safari, come back, and Notes or Feed had become Relay.
        .onReceive(NotificationCenter.default.publisher(for: .havenOpenFeedRelaySettings)) { _ in
            settingsPaneRequest = .relays
            selectedTab = .settings
        }
        .onReceive(NotificationCenter.default.publisher(for: .havenOpenSettings)) { _ in
            selectedTab = .settings
        }
        // MARK: - Keyboard Shortcuts
        .background {
            Group {
                Button("") { selectedTab = .feed }
                    .keyboardShortcut("1", modifiers: .command)
                Button("") { selectedTab = .search }
                    .keyboardShortcut("2", modifiers: .command)
                Button("") { selectedTab = .profile }
                    .keyboardShortcut("3", modifiers: .command)
                Button("") { selectedTab = .relay }
                    .keyboardShortcut("4", modifiers: .command)
                Button("") { selectedTab = .notes }
                    .keyboardShortcut("5", modifiers: .command)
                Button("") { selectedTab = .media }
                    .keyboardShortcut("6", modifiers: .command)
                // ⌘, opens the real Settings scene declared in HavenApp.swift.
                // It used to select the .settings tab instead, which left that
                // scene reachable from nothing in the entire app — `openSettings`
                // was declared here and never called. The status panel now does
                // the same thing, so the shortcut means one thing everywhere.
                //
                // The sidebar's embedded Settings tab is untouched and still
                // works; whether a window that hosts settings inline should also
                // have a separate Settings window is a design call, not mine.
                Button("") { openSettings() }
                    .keyboardShortcut(",", modifiers: .command)
                Button("") {
                    NotificationCenter.default.post(name: .composeFromTabBar, object: 1)
                }
                    .keyboardShortcut("n", modifiers: .command)
            }
            .frame(width: 0, height: 0)
            .opacity(0)
        }
        #endif
        .onReceive(ConfigService.shared.$activeAccountHexPubkey) { newHex in
            if activeHex != newHex {
                activeHex = newHex
            }
        }
    }
    
}
