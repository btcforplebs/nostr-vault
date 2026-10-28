import SwiftUI
import Combine


struct NoteDetailView: View {
    let note: FeedNote

    /// A repost opens the note it reposted: the thread, likes, zaps and
    /// replies all belong to the original. Done here so every way into a
    /// thread gets it, not each caller.
    init(note: FeedNote) {
        self.note = FeedService.shared.threadTarget(for: note)
    }
    @StateObject var feedService = FeedService.shared
    @EnvironmentObject var nostrService: NostrService
    @EnvironmentObject var configService: ConfigService
    @Environment(\.presentationMode) var presentationMode
    
    @State var composeContext: ComposeContext?
    @State var isLoadingReplies = false
    @State var pendingReplies: [FeedNote] = []
    @State var parentNotes: [FeedNote] = []
    @State var isLoadingParents = false
    @State private var threadClient: WebSocketClient?
    /// The reply subscriptions, kept open while the page is on screen so a
    /// reply that lands later (yours once it broadcasts, or anyone's) shows up.
    @State var replyClients: [WebSocketClient] = []
    @State var cancellables = Set<AnyCancellable>()
    @State var showingProfilePubkey: String?
    @State private var showingNoteId: String?
    @State var showingMediaUrl: IdentifiableURL?
    @Namespace private var mediaZoom
    @State private var showingReportDialog = false
    @State private var showingDeleteConfirm = false
    @State private var showingBroadcastSheet = false
    @State private var noLightningAddressAlert = false

    @State var detailedReactions: [NostrEvent] = []
    /// Responses that aren't replies (spec "below the fold"): quotes,
    /// highlights, voice replies. Shown in their own section, not as rows.
    @State var otherResponses: [FeedNote] = []
    @State var detailedReposts: [NostrEvent] = []
    @State var detailedZaps: [NostrEvent] = []
    
    @State var showingZappersSheet = false
    @State var showingReactorsSheet = false
    @State var showingRepostersSheet = false

    // Expanded engagement across all thread notes (initialized from config in onAppear)
    @State var expandedEngagement = false
    @State var perNoteReactions: [String: [NostrEvent]] = [:]
    @State var perNoteReposts: [String: [NostrEvent]] = [:]
    @State var perNoteZaps: [String: [NostrEvent]] = [:]
    @State var isLoadingExpandedEngagement = false

    @State var focusedNoteId: String = ""

    /// Replies and the conversation above drawn as condensed lines, the same
    /// lines the threaded feed uses. The note you are reading always stays
    /// full size with its action bar, so replying is still one tap: that is
    /// what the old compact mode got wrong (#56). Remembered across threads.
    @AppStorage("thread.condensedReplies") var condensedReplies = false

    /// The note pinned to the top of the scroll view. Kept in step with
    /// `focusedNoteId` so that whichever note the reader landed on never
    /// moves on screen — thread history that loads in above it just extends
    /// the scrollable area upward instead of shoving the note (and
    /// everything below it) down mid-read.
    @State private var pinnedScrollId: String?
    /// Set once the reader scrolls or picks another note; until then the
    /// opened note is kept at the top as the thread above it loads.
    @State private var didLandOnFocusedNote = false
    /// Shown from the first frame: the opened note is placed by
    /// `scrollPosition` before the screen draws. Kept so a late landing
    /// (history still loading) animates rather than jumps.
    @State private var isSettled = true
    private static let settleCap: TimeInterval = 0.6
    /// Where the opened note's top sits: on the tap landing line, 20 pt
    /// under the toolbar buttons. The scroll content's top margin is the gap
    /// to that line, so a top anchor puts every note there, short or long;
    /// the old 12% anchor put a short reply lower than a long one.
    private static let landingAnchor = UnitPoint.top
    /// Height of the scroll view, for the room left under a short thread.
    @State private var viewportHeight: CGFloat = 0

    var threadRootId: String {
        NIP10Thread.rootEventId(kind: note.kind, tags: note.tags) ?? note.id
    }

    /// The root's `kind:pubkey:d` address when it's an addressable or
    /// replaceable event. Comments root on `A` there, and an edited article
    /// has a new event id, so `#E` alone misses them.
    var threadRootCoordinate: String? {
        if note.kind == NIP10Thread.commentKind {
            return note.tags.first(where: { $0.count >= 2 && $0[0] == "A" })?[1]
        }
        guard threadRootId == note.id else { return nil }
        return NIP10Thread.coordinate(kind: note.kind, pubkey: note.pubkey, tags: note.tags)
    }

    var focusedNote: FeedNote {
        if focusedNoteId.isEmpty {
            return note
        }
        return feedService.findNote(id: focusedNoteId)
            ?? parentNotes.first(where: { $0.id == focusedNoteId })
            ?? note
    }

    var dynamicParents: [FeedNote] {
        var ancestors: [FeedNote] = []
        var current = focusedNote
        while let parentId = current.parentEventId {
            if let parent = feedService.findNote(id: parentId) {
                ancestors.insert(parent, at: 0)
                current = parent
            } else if let parentFromList = parentNotes.first(where: { $0.id == parentId }) {
                ancestors.insert(parentFromList, at: 0)
                current = parentFromList
            } else {
                break
            }
        }
        return ancestors
    }

    /// All notes visible to this thread view: the live feed, the opened note
    /// itself, and every fetched ancestor (parentNotes / parentNotesCache).
    /// Ancestors never enter feedService.notes, so filtering replies against
    /// feedService.notes alone drops any branch that passes through a parent —
    /// e.g. focus a grandparent and the parent (plus the reply you came from)
    /// silently disappears.
    var allThreadNotes: [FeedNote] {
        var seen = Set<String>()
        var pool: [FeedNote] = []
        for n in feedService.notes where seen.insert(n.id).inserted { pool.append(n) }
        if seen.insert(note.id).inserted { pool.append(note) }
        for n in parentNotes where seen.insert(n.id).inserted { pool.append(n) }
        for n in feedService.parentNotesCache.values where seen.insert(n.id).inserted { pool.append(n) }
        return pool
    }

    /// The opened note and the notes above it: always shown, whoever wrote them.
    var contextNoteIds: Set<String> {
        Set([note.id, focusedNote.id] + dynamicParents.map(\.id))
    }

    /// Replies under the opened note, at any depth. `feedService.notes` holds
    /// every note in memory, Global's firehose included, so replies go
    /// through the feed's block rule and spam check; everyone else shows.
    func threadReplies(in all: [FeedNote]) -> [FeedNote] {
        let byId = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let blocked = configService.activeAccountBlockedHexPubkeys
        let mutes = MuteListStore.shared.active
        return ThreadReplyVisibility.shown(under: replyTargetId, in: all, id: \.id, parentId: \.parentEventId) { n in
            FeedFilterEngine.involvesBlocked(n, blocked: blocked, authorOf: { byId[$0]?.pubkey })
                || FeedNote.isNoiseOrSpam(content: n.content, tags: n.tags)
                || mutes.hides(n)
        }
    }

    var replyTargetId: String {
        (focusedNote.kind == 6 && focusedNote.repostedEventId != nil) ? focusedNote.repostedEventId! : focusedNote.id
    }

    /// Puts the note you opened on the landing line, with the posts it
    /// answers scrollable above. Runs again whenever the content above it changes
    /// (history arriving, images in it loading, the screen size settling),
    /// until the reader scrolls: a single jump was undone by whatever loaded
    /// next, and the opened reply ended up down the screen.
    private func landOnFocusedNote(proxy: ScrollViewProxy) {
        guard !didLandOnFocusedNote, !dynamicParents.isEmpty else { return }
        let target = focusedNoteId.isEmpty ? note.id : focusedNoteId
        // Next runloop turn, once the revealed history has laid out, and once
        // more after images above have had a moment to size themselves.
        // Hidden until settled, these moves are invisible; once the thread is
        // showing (a slow history arriving later) it glides instead of jumping.
        let move = { (animated: Bool) in
            guard !didLandOnFocusedNote else { return }
            if animated && isSettled {
                withAnimation(Motion.scrollJump) { proxy.scrollTo(target, anchor: Self.landingAnchor) }
            } else {
                proxy.scrollTo(target, anchor: Self.landingAnchor)
            }
        }
        DispatchQueue.main.async { move(true) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            move(true)
            settle()
        }
    }

    private func settle() {
        guard !isSettled else { return }
        withAnimation(Motion.fade) { isSettled = true }
    }

    func selectAndScrollToNote(_ targetId: String, proxy: ScrollViewProxy) {
        didLandOnFocusedNote = true
        withAnimation(Motion.scrollJump) {
            focusedNoteId = targetId
            pinnedScrollId = targetId
            proxy.scrollTo(targetId, anchor: .center)
        }
    }

    private var noteDetailFeedActions: FeedActions {
        .make(feedService: feedService, nostrService: nostrService)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    // Thread History (Parents) — only revealed once all parents are loaded
                    if !dynamicParents.isEmpty && !isLoadingParents {
                        threadHistory(proxy: proxy)
                            .transition(.opacity)
                    }

                    // Loading indicator while thread is being fetched
                    if isLoadingParents && note.parentEventId != nil {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                                .tint(Color.havenPurple)
                            Text("Loading thread\u{2026}")
                                .font(.appSystem(size: 12, weight: .medium, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .transition(.opacity)
                    }

                    if focusedNoteBlockState == .placeholder {
                        blockedNotePlaceholder
                    } else {
                        // Main Note (focused hero note) + engagement merged into one card
                        mainNoteSection(proxy: proxy)

                        // Replies Section
                        repliesSection(proxy: proxy)

                        otherResponsesSection
                    }

                    // Room under a short thread, so the opened note can scroll
                    // up to the landing line with the posts it answers above it.
                    // Without it a reply with few replies of its own stayed at
                    // the bottom of the screen: there was nothing below to scroll into.
                    if !dynamicParents.isEmpty {
                        Color.clear.frame(height: TapLandingLine.bottomRoom(viewportHeight: viewportHeight))
                    }
                }
                // Makes the opened note (a direct child with its id) a scroll
                // target, so `scrollPosition` below can hold it at the top.
                // Without this the pin was ignored, and the posts loading in
                // above pushed the opened reply down out of view.
                .scrollTargetLayout()
                .padding(.bottom, 90)
                // iPad: a note's text runs to a readable measure down the
                // middle of the pane rather than the full 13in. The scroll
                // view and its background stay full width.
                .readableWidthCap()
                .opacity(isSettled ? 1 : 0)
            }
            // The gap to the landing line. A margin rather than padding, so
            // top-anchored scrolls stop on the line instead of the bar's edge,
            // and a note with nothing above it sits on the line too.
            .contentMargins(.top, TapLandingLine.gap, for: .scrollContent)
            .scrollPosition(id: $pinnedScrollId, anchor: Self.landingAnchor)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewportHeight = $0 }
            // The reader took over: stop putting the opened note back on top.
            .simultaneousGesture(DragGesture(minimumDistance: 8).onChanged { _ in didLandOnFocusedNote = true })
            .onChange(of: dynamicParents.count) { _, _ in landOnFocusedNote(proxy: proxy) }
            .onChange(of: viewportHeight) { _, _ in landOnFocusedNote(proxy: proxy) }
            // Opening a reply loads the conversation above it, which pushed the
            // reply below the fold: the pin above does not hold, because the
            // parents are not direct scroll targets. Once they are shown, put
            // the note you tapped at the top, with its parents scrollable above.
            .onChange(of: isLoadingParents) { _, loading in
                guard !loading else { return }
                landOnFocusedNote(proxy: proxy)
            }
            .task {
                // Parents already cached: they are on screen from the first frame.
                try? await Task.sleep(nanoseconds: 50_000_000)
                if !isLoadingParents { landOnFocusedNote(proxy: proxy) }
                // Nothing above to wait for, or a slow thread: show it anyway.
                if dynamicParents.isEmpty && !isLoadingParents { settle(); return }
                try? await Task.sleep(nanoseconds: UInt64(Self.settleCap * 1_000_000_000))
                settle()
            }
            // Blocked the author of the reply you tapped into: back to the
            // note you opened, as the reply itself is now hidden.
            .onChange(of: focusedNoteBlockState) { _, state in
                guard state == .backToOpened else { return }
                focusedNoteId = note.id
                pinnedScrollId = note.id
            }
            .onChange(of: focusedNoteId) { _, newId in
                if !newId.isEmpty {
                    fetchEngagement(for: newId)
                    fetchRepliesForNote(newId)
                }
            }
        }
        .background(Color.platformWindowBackground)
        .refreshable {
            #if os(iOS)
            // Pull replies that only reached the Mac relay into the local one.
            if !RelayConfiguration.macRelayURL(config: ConfigService.shared.config).isEmpty {
                RequestRelaySyncC()
            }
            #endif
            fetchParents()
            fetchReplies()
        }
        .navigationTitle("")
        .environment(\.feedActions, noteDetailFeedActions)
        .hashtagLinks()

        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        #endif
        .toolbar {
            ToolbarItem(placement: .automatic) {
                HStack(spacing: 8) {
                    // Condensed / full replies
                    IconFilterButton(
                        icon: condensedReplies ? "list.bullet.indent" : "rectangle.grid.1x2",
                        tooltip: condensedReplies ? "Condensed replies" : "Full replies",
                        isSelected: condensedReplies,
                        color: .havenPurple
                    ) {
                        withAnimation(Motion.panel) { condensedReplies.toggle() }
                    }

                    // Stats toggle
                    IconFilterButton(
                        icon: expandedEngagement ? "chart.bar.fill" : "chart.bar",
                        tooltip: "Thread Stats",
                        isSelected: expandedEngagement,
                        color: .havenPurple,
                        label: "Stats"
                    ) {
                        withAnimation(Motion.panel) {
                            expandedEngagement.toggle()
                        }
                        configService.config.noteDetailExpandedEngagement = expandedEngagement
                        configService.save()
                        if expandedEngagement {
                            fetchAllThreadEngagement()
                        }
                    }

                    // Both act on the note shown full size. Behind the
                    // blocked placeholder that is the blocked person's note.
                    if focusedNoteBlockState != .placeholder {
                        // Reply button
                        IconFilterButton(
                            icon: "arrowshape.turn.up.left.fill",
                            tooltip: "Reply",
                            isSelected: false,
                            color: .havenPurple
                        ) {
                            // The toolbar replies to whatever note is focused, the
                            // same target the focused card's own reply button uses.
                            // Pointing it at the entry note instead let the two
                            // buttons disagree once you tapped into a reply.
                            composeContext = ComposeContext(replyTo: feedService.replyTarget(for: focusedNote), quoteTo: nil)
                        }

                        // Event info / re-broadcast
                        IconFilterButton(
                            icon: "antenna.radiowaves.left.and.right",
                            tooltip: "Broadcast",
                            isSelected: false,
                            color: .havenPurple
                        ) {
                            showingBroadcastSheet = true
                        }
                    }
                }
            }
        }
        .sheet(item: $composeContext) { ctx in
            ComposeView(onDismiss: { composeContext = nil }, replyTo: ctx.replyTo, quoteTo: ctx.quoteTo)
                .environmentObject(nostrService)
                .environmentObject(configService)
        }
        .sheet(isPresented: $showingReportDialog) {
            UGCReportingDialog(eventId: note.id, pubkey: note.pubkey, onDismiss: { showingReportDialog = false }) {
                nostrService.objectWillChange.send()
                showingReportDialog = false
            }
            .environmentObject(nostrService)
            .environmentObject(configService)
        }
        .onAppear {
            expandedEngagement = configService.config.noteDetailExpandedEngagement
            if expandedEngagement {
                fetchAllThreadEngagement()
            }
            // Coming back to the page keeps what it already showed; the
            // fetch below adds to it (each list skips ids it already has).
            if focusedNoteId.isEmpty {
                focusedNoteId = note.id
            }
            if pinnedScrollId == nil {
                pinnedScrollId = note.id
            }
            fetchParents()
            fetchReplies()
            feedService.fetchNoteStats(for: note.id)
            let profile = nostrService.profiles[note.pubkey]
            if profile == nil {
                nostrService.fetchMissingProfiles(for: [note.pubkey])
            }
        }
        .onDisappear {
            threadClient?.disconnect()
            replyClients.forEach { $0.disconnect() }
            replyClients.removeAll()
            cancellables.removeAll()
        }
        .sheet(item: Binding<IdentifiableString?>(
            get: { showingProfilePubkey.map { IdentifiableString(id: $0) } },
            set: { showingProfilePubkey = $0?.id }
        )) { p in
            ProfileView(pubkey: p.id, onDismiss: { showingProfilePubkey = nil })
        }
        .sheet(item: Binding<IdentifiableString?>(
            get: { showingNoteId.map { IdentifiableString(id: $0) } },
            set: { showingNoteId = $0?.id }
        )) { noteId in
            NoteDetailViewWrapper(noteId: noteId.id, onDismiss: { showingNoteId = nil })
                .environmentObject(nostrService)
                .environmentObject(configService)
        }
        .mediaViewer(item: $showingMediaUrl, namespace: mediaZoom)
        .sheet(isPresented: $showingBroadcastSheet) {
            // Broadcast follows focus for the same reason Reply does: the
            // toolbar acts on the note you are looking at, not the one you
            // happened to arrive on.
            EventBroadcastSheet(note: focusedNote)
                .environmentObject(nostrService)
                .environmentObject(configService)
        }
        .sheet(isPresented: $showingZappersSheet) {
            ZappersListView(zaps: parsedZaps, onDismiss: { showingZappersSheet = false })
                .environmentObject(nostrService)
        }
        .sheet(isPresented: $showingReactorsSheet) {
            ReactorsListView(reactors: reactorsMapped, onDismiss: { showingReactorsSheet = false })
                .environmentObject(nostrService)
        }
        .sheet(isPresented: $showingRepostersSheet) {
            RepostersListView(pubkeys: repostersMapped, onDismiss: { showingRepostersSheet = false })
                .environmentObject(nostrService)
        }
        .alert("No Lightning Address", isPresented: $noLightningAddressAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("This user hasn't configured a lightning address, so they can't receive zaps.")
        }
        .alert("Delete Post", isPresented: $showingDeleteConfirm) {
            Button("Delete", role: .destructive) {
                nostrService.deleteNote(id: note.id)
                FeedService.shared.removeNote(id: note.id)
                presentationMode.wrappedValue.dismiss()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Request deletion of this post? Not all relays honor NIP-09 deletion requests.")
        }
    }
}
