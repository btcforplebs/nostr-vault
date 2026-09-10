import SwiftUI
import Combine


struct NoteDetailView: View {
    let note: FeedNote
    @StateObject private var feedService = FeedService.shared
    @EnvironmentObject var nostrService: NostrService
    @EnvironmentObject var configService: ConfigService
    @Environment(\.presentationMode) var presentationMode
    
    @State private var composeContext: ComposeContext?
    @State private var isLoadingReplies = false
    @State private var pendingReplies: [FeedNote] = []
    @State private var parentNotes: [FeedNote] = []
    @State private var isLoadingParents = false
    @State private var threadClient: WebSocketClient?
    @State private var cancellables = Set<AnyCancellable>()
    @State private var showingProfilePubkey: String?
    @State private var showingNoteId: String?
    @State private var showingMediaUrl: IdentifiableURL?
    @State private var showingReportDialog = false
    @State private var showingDeleteConfirm = false
    @State private var showingEmojiPicker = false
    @State private var showingBroadcastSheet = false
    @State private var noLightningAddressAlert = false

    @State private var detailedReactions: [NostrEvent] = []
    @State private var detailedReposts: [NostrEvent] = []
    @State private var detailedZaps: [NostrEvent] = []
    
    @State private var showingZappersSheet = false
    @State private var showingReactorsSheet = false
    @State private var showingRepostersSheet = false

    // Expanded engagement across all thread notes (initialized from config in onAppear)
    @State private var expandedEngagement = false
    @State private var perNoteReactions: [String: [NostrEvent]] = [:]
    @State private var perNoteReposts: [String: [NostrEvent]] = [:]
    @State private var perNoteZaps: [String: [NostrEvent]] = [:]
    @State private var isLoadingExpandedEngagement = false

    @State private var focusedNoteId: String = ""

    // Compact mode for entire thread (initialized from config in onAppear)
    @State private var isCompactView = false

    private var threadRootId: String {
        let eTags = note.tags.filter { $0.count >= 2 && $0[0] == "e" }
        if let explicitRoot = eTags.first(where: { $0.count >= 4 && $0[3] == "root" }) {
            return explicitRoot[1]
        }
        return eTags.first?[1] ?? note.id
    }

    private var focusedNote: FeedNote {
        if focusedNoteId.isEmpty {
            return note
        }
        return feedService.findNote(id: focusedNoteId)
            ?? parentNotes.first(where: { $0.id == focusedNoteId })
            ?? note
    }

    private var dynamicParents: [FeedNote] {
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
    private var threadPool: [FeedNote] {
        var seen = Set<String>()
        var pool: [FeedNote] = []
        for n in feedService.notes where seen.insert(n.id).inserted { pool.append(n) }
        if seen.insert(note.id).inserted { pool.append(note) }
        for n in parentNotes where seen.insert(n.id).inserted { pool.append(n) }
        for n in feedService.parentNotesCache.values where seen.insert(n.id).inserted { pool.append(n) }
        return pool
    }

    private var dynamicReplies: [FeedNote] {
        let targetId = (focusedNote.kind == 6 && focusedNote.repostedEventId != nil) ? focusedNote.repostedEventId! : focusedNote.id
        return threadPool.filter { $0.parentEventId == targetId }
            .sorted(by: { $0.createdAt < $1.createdAt })
    }

    private func selectAndScrollToNote(_ targetId: String, proxy: ScrollViewProxy) {
        withAnimation(Motion.scrollJump) {
            focusedNoteId = targetId
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
                        threadSection(proxy: proxy)
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

                    // Main Note (focused hero note) + engagement merged into one card
                    mainNoteSection(proxy: proxy)

                    // Replies Section
                    repliesSection(proxy: proxy)


                }
                .padding(.top, 16)
                .padding(.bottom, 90)
            }
            .onChange(of: isLoadingParents) { _, loading in
                if !loading {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        withAnimation(Motion.scrollJump) {
                            let target = focusedNoteId.isEmpty ? note.id : focusedNoteId
                            proxy.scrollTo(target, anchor: .center)
                        }
                    }
                }
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
            MacRelaySyncService.shared.syncIfConfigured()
            #endif
            fetchParents()
            fetchReplies()
        }
        .navigationTitle("")
        .environment(\.feedActions, noteDetailFeedActions)

        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        #endif
        .toolbar {
            ToolbarItem(placement: .automatic) {
                HStack(spacing: 8) {
                    // Compact mode toggle
                    IconFilterButton(
                        icon: isCompactView ? "rectangle.compress.vertical" : "rectangle.expand.vertical",
                        tooltip: "Compact View",
                        isSelected: isCompactView,
                        color: .havenPurple
                    ) {
                        withAnimation(Motion.panel) {
                            isCompactView.toggle()
                        }
                        configService.config.noteDetailCompactView = isCompactView
                        configService.save()
                    }

                    // Stats toggle
                    IconFilterButton(
                        icon: expandedEngagement ? "chart.bar.fill" : "chart.bar",
                        tooltip: "Thread Stats",
                        isSelected: expandedEngagement,
                        color: .havenPurple
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

                    // Reply button
                    IconFilterButton(
                        icon: "arrowshape.turn.up.left.fill",
                        tooltip: "Reply",
                        isSelected: false,
                        color: .havenPurple
                    ) {
                        let replyTarget: FeedNote = {
                            if note.kind == 6, let refId = note.repostedEventId,
                               let original = feedService.findNote(id: refId) {
                                return original
                            }
                            return note
                        }()
                        composeContext = ComposeContext(replyTo: replyTarget, quoteTo: nil)
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
            isCompactView = configService.config.noteDetailCompactView
            expandedEngagement = configService.config.noteDetailExpandedEngagement
            if expandedEngagement {
                fetchAllThreadEngagement()
            }
            detailedReactions.removeAll()
            detailedReposts.removeAll()
            detailedZaps.removeAll()
            if focusedNoteId.isEmpty {
                focusedNoteId = note.id
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
        .sheet(item: $showingMediaUrl) { media in
            FeedMediaPager(urls: media.allURLs, selected: media.url, onDismiss: { showingMediaUrl = nil })
        }
        .sheet(isPresented: $showingBroadcastSheet) {
            EventBroadcastSheet(note: note)
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
    
    private func mainNoteSection(proxy: ScrollViewProxy) -> some View {
        let profile = nostrService.profiles[focusedNote.pubkey]
        let rowData = FeedNoteRowData.resolve(
            for: focusedNote,
            feedService: feedService,
            nostrService: nostrService
        )
        let hasEngagement = (!detailedReactions.isEmpty && !configService.config.zapsOnlyMode) || !detailedZaps.isEmpty || !detailedReposts.isEmpty

        return Group {
            if isCompactView {
                compactMainNoteLayout(profile: profile, hasEngagement: hasEngagement)
                    .transition(.asymmetric(
                        insertion: AnyTransition.opacity.combined(with: AnyTransition.scale(scale: 0.95)),
                        removal: AnyTransition.opacity
                    ))
            } else {
                fullMainNoteLayout(profile: profile, rowData: rowData, hasEngagement: hasEngagement)
                    .transition(.asymmetric(
                        insertion: AnyTransition.opacity.combined(with: AnyTransition.scale(scale: 0.95)),
                        removal: AnyTransition.opacity
                    ))
            }
        }
        .animation(Motion.panel, value: isCompactView)
        .id(focusedNote.id)
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private func fullMainNoteLayout(profile: FeedProfile?, rowData: FeedNoteRowData, hasEngagement: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            FeedNoteRow(
                note: focusedNote,
                profile: profile,
                rowData: rowData,
                onReply: {
                    let replyTarget: FeedNote = {
                        if focusedNote.kind == 6, let refId = focusedNote.repostedEventId,
                           let original = feedService.findNote(id: refId) {
                            return original
                        }
                        return focusedNote
                    }()
                    composeContext = ComposeContext(replyTo: replyTarget, quoteTo: nil)
                },
                onQuote: {
                    composeContext = ComposeContext(replyTo: nil, quoteTo: focusedNote)
                },
                onProfile: { pubkey in
                    showingProfilePubkey = pubkey
                },
                onMedia: { url, urls in
                    showingMediaUrl = IdentifiableURL(url: url, allURLs: urls)
                },
                showParent: false,
                layoutMode: .wide,
                isFocused: true,
                suppressCardStyling: true
            )

            if hasEngagement {
                engagementDetailSection
                    .transition(.opacity)
            }
        }
        .padding(14)
        .background(
            ZStack {
                Color.platformSecondaryGroupedBackground
                Color.havenPurple.opacity(0.015)
            }
        )
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.havenPurple, lineWidth: 2.0)
        )
        .shadow(color: Color.havenPurple.opacity(0.35), radius: 8)
    }

    @ViewBuilder
    private func compactMainNoteLayout(profile: FeedProfile?, hasEngagement: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                // Avatar (32x32)
                AvatarView(url: profile?.pictureURL, pubkey: focusedNote.pubkey)
                    .frame(width: 32, height: 32)
                    .onTapGesture {
                        showingProfilePubkey = focusedNote.pubkey
                    }

                // Content (flexible)
                VStack(alignment: .leading, spacing: 2) {
                    // Header row
                    HStack(spacing: 4) {
                        Text(profile?.bestName ?? shortKey(focusedNote.pubkey))
                            .font(.appSystem(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                            .lineLimit(1)

                        if let nip05 = profile?.nip05, !nip05.isEmpty {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.appSystem(size: 9))
                                .foregroundColor(Color(red: 0.2, green: 0.8, blue: 0.6))
                        }

                        Text("· \(relativeTime(focusedNote.createdAt))")
                            .font(.appSystem(size: 11))
                            .foregroundColor(.secondary)

                        Spacer()

                        // Reply/Repost indicators
                        if focusedNote.isReply {
                            Image(systemName: "arrowshape.turn.up.left.fill")
                                .font(.appSystem(size: 10))
                                .foregroundColor(Color.havenPurple.opacity(0.7))
                        }
                        if focusedNote.repostedBy != nil {
                            Image(systemName: "arrow.2.squarepath")
                                .font(.appSystem(size: 10))
                                .foregroundColor(.green.opacity(0.7))
                        }
                    }

                    // Truncated content (2 lines max)
                    if !focusedNote.content.isEmpty {
                        Text(focusedNote.content)
                            .font(.appSystem(size: 14))
                            .foregroundColor(.white)
                            .lineLimit(2)
                            .lineSpacing(1)
                    }

                    // Inline engagement stats
                    if hasEngagement {
                        HStack(spacing: 8) {
                            // Reactions - compact
                            if !groupedReactions.isEmpty {
                                HStack(spacing: 2) {
                                    ForEach(groupedReactions.prefix(3), id: \.emoji) { group in
                                        HStack(spacing: 1) {
                                            Text(group.emoji)
                                                .font(.appSystem(size: 10))
                                            Text("\(group.count)")
                                                .font(.appSystem(size: 9, weight: .bold, design: .monospaced))
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                }
                            }

                            // Zaps - compact
                            if !parsedZaps.isEmpty {
                                HStack(spacing: 2) {
                                    Image(systemName: "bolt.fill")
                                        .font(.appSystem(size: 9, weight: .bold))
                                        .foregroundColor(.orange)
                                    Text("\(parsedZaps.count)")
                                        .font(.appSystem(size: 9, weight: .semibold, design: .monospaced))
                                        .foregroundColor(.secondary)
                                }
                            }

                            // Reposts - compact
                            if !detailedReposts.isEmpty {
                                HStack(spacing: 2) {
                                    Image(systemName: "arrow.2.squarepath")
                                        .font(.appSystem(size: 9, weight: .bold))
                                        .foregroundColor(.green)
                                    Text("\(repostersMapped.count)")
                                        .font(.appSystem(size: 9, weight: .semibold, design: .monospaced))
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .padding(.top, 4)
                    }
                }

                Spacer(minLength: 8)

                // Media thumbnail (60x60)
                if let firstMedia = focusedNote.mediaURLs.first {
                    ZStack(alignment: .bottomTrailing) {
                        FeedMediaView(
                            url: firstMedia,
                            isThumbnail: true
                        )
                        .frame(width: 60, height: 60)
                        .aspectRatio(1, contentMode: .fill)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .onTapGesture {
                            showingMediaUrl = IdentifiableURL(url: firstMedia, allURLs: focusedNote.mediaURLs)
                        }

                        // Multi-media badge
                        if focusedNote.mediaURLs.count > 1 {
                            Text("+\(focusedNote.mediaURLs.count - 1)")
                                .font(.appSystem(size: 10, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Color.black.opacity(0.7))
                                .clipShape(Capsule())
                                .padding(4)
                        }
                    }
                }
            }
            .padding(12)
        }
        .background(
            ZStack {
                Color.platformSecondaryGroupedBackground
                Color.havenPurple.opacity(0.015)
            }
        )
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.havenPurple, lineWidth: 2.0)
        )
        .shadow(color: Color.havenPurple.opacity(0.35), radius: 8)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(Motion.panel) {
                isCompactView = false
            }
        }
    }
    
    private func threadSection(proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: isCompactView ? 6 : 12) {
            ForEach(dynamicParents) { parent in
                let parentProfile = nostrService.profiles[parent.pubkey]

                if isCompactView {
                    compactParentNoteView(parent: parent, profile: parentProfile, proxy: proxy)
                } else {
                    let rowData = FeedNoteRowData.resolve(
                        for: parent,
                        feedService: feedService,
                        nostrService: nostrService
                    )

                    // Check if this parent has engagement to show
                    let hasEngagement = expandedEngagement && parent.id != focusedNoteId && (
                        !groupedReactionsForNote(parent.id).isEmpty ||
                        zapTotalForNote(parent.id).count > 0 ||
                        repostCountForNote(parent.id) > 0
                    )

                    VStack(alignment: .leading, spacing: 0) {
                        FeedNoteRow(
                            note: parent,
                            profile: parentProfile,
                            rowData: rowData,
                            onReply: {
                                composeContext = ComposeContext(replyTo: parent, quoteTo: nil)
                            },
                            onQuote: {
                                composeContext = ComposeContext(replyTo: nil, quoteTo: parent)
                            },
                            onProfile: { pubkey in
                                showingProfilePubkey = pubkey
                            },
                            onMedia: { url, urls in
                                showingMediaUrl = IdentifiableURL(url: url, allURLs: urls)
                            },
                            showParent: false,
                            layoutMode: .wide,
                            isFocused: parent.id == focusedNoteId
                        )

                        // Expanded engagement for parent notes - inside the note box
                        if hasEngagement {
                            Rectangle()
                                .fill(Color.secondary.opacity(0.1))
                                .frame(height: 0.5)
                                .padding(.horizontal, 12)
                                .padding(.top, 8)

                            ThreadNoteEngagementRow(
                                reactions: groupedReactionsForNote(parent.id),
                                zapCount: zapTotalForNote(parent.id).count,
                                zapSats: zapTotalForNote(parent.id).sats,
                                repostCount: repostCountForNote(parent.id)
                            )
                            .padding(.horizontal, 12)
                            .padding(.bottom, 8)
                        }
                    }
                    .id(parent.id)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectAndScrollToNote(parent.id, proxy: proxy)
                    }
                    .padding(.horizontal, 16)
                }
            }

            if isLoadingParents {
                FeedNoteSkeletonRow()
                    .padding(.horizontal, 16)
            }
        }
    }

    @ViewBuilder
    private func compactParentNoteView(parent: FeedNote, profile: FeedProfile?, proxy: ScrollViewProxy) -> some View {
        let isOLED = ConfigService.shared.config.useOLED
        let isFocusedParent = parent.id == focusedNoteId

        HStack(alignment: .top, spacing: 8) {
            // Avatar
            AvatarView(url: profile?.pictureURL, pubkey: parent.pubkey)
                .frame(width: 28, height: 28)
                .onTapGesture {
                    showingProfilePubkey = parent.pubkey
                }

            // Content
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(profile?.bestName ?? shortKey(parent.pubkey))
                        .font(.appSystem(size: 12, weight: .semibold))
                        .foregroundColor(.white.opacity(isOLED ? 0.85 : 0.9))
                        .lineLimit(1)

                    Text("\u{b7} \(relativeTime(parent.createdAt))")
                        .font(.appSystem(size: 10))
                        .foregroundColor(.secondary.opacity(0.7))

                    Spacer()
                }

                if !parent.content.isEmpty {
                    Text(parent.content)
                        .font(.appSystem(size: 12))
                        .foregroundColor(.white.opacity(isOLED ? 0.7 : 0.75))
                        .lineLimit(1)
                }
            }
        }
        .id(parent.id)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(
                    isFocusedParent
                        ? Color.havenPurple.opacity(isOLED ? 0.08 : 0.12)
                        : Color.platformSecondaryGroupedBackground
                )
        )
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.havenPurple.opacity(0.015))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    isFocusedParent
                        ? Color.havenPurple.opacity(isOLED ? 0.6 : 0.4)
                        : Color.havenPurple.opacity(isOLED ? 0.30 : 0.15),
                    lineWidth: isFocusedParent ? 1.5 : (isOLED ? 1.0 : 0.5)
                )
        )
        .padding(.horizontal, 16)
        .contentShape(Rectangle())
        .onTapGesture {
            selectAndScrollToNote(parent.id, proxy: proxy)
        }
    }

    private func repliesSection(proxy: ScrollViewProxy) -> some View {
        let currentReplies = dynamicReplies
        let pool = threadPool

        return VStack(alignment: .leading, spacing: 12) {
            if isLoadingReplies {
                // Subtle loading indicator — replies are being buffered
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Color.havenPurple)
                    Text("Loading replies\u{2026}")
                        .font(.appSystem(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                .transition(.opacity)
            } else if currentReplies.isEmpty {
                Text("No replies yet")
                    .font(.appSystem(size: 13, weight: .regular, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
                    .transition(.opacity)
            } else {
                Text("Replies")
                    .font(.appSystem(size: 14, weight: .semibold))
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.5)
                    .padding(.bottom, 2)
                    .padding(.horizontal, 16)

                ForEach(currentReplies) { reply in
                    ThreadedReplyNode(
                        reply: reply,
                        allNotes: pool,
                        depth: 1,
                        isCompactMode: isCompactView,
                        onReply: { target in
                            composeContext = ComposeContext(replyTo: target, quoteTo: nil)
                        },
                        onQuote: { target in
                            composeContext = ComposeContext(replyTo: nil, quoteTo: target)
                        },
                        onProfile: { pubkey in
                            showingProfilePubkey = pubkey
                        },
                        onMedia: { url, urls in
                            showingMediaUrl = IdentifiableURL(url: url, allURLs: urls)
                        },
                        focusedNoteId: $focusedNoteId,
                        proxy: proxy,
                        expandedEngagement: expandedEngagement,
                        perNoteReactions: perNoteReactions,
                        perNoteReposts: perNoteReposts,
                        perNoteZaps: perNoteZaps
                    )
                    .padding(.horizontal, 16)
                }
                .transition(.opacity)
            }
        }
    }
    
    @ViewBuilder
    private func mediaCarousel(urls: [URL]) -> some View {
        if urls.isEmpty {
            EmptyView()
        } else if urls.count == 1 {
            FeedMediaView(
                url: urls[0],
                onTap: { showingMediaUrl = IdentifiableURL(url: urls[0], allURLs: urls) },
                maxHeight: 400,
                isThumbnail: false
            )
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
        } else {
            MediaPagerView(items: urls) { url in
                FeedMediaView(
                    url: url,
                    onTap: { showingMediaUrl = IdentifiableURL(url: url, allURLs: urls) },
                    maxHeight: 400,
                    isThumbnail: false
                )
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                #if os(iOS)
                .transition(.opacity.animation(Motion.media))
                #endif
            }
            .frame(height: 400)
            .padding(.top, 4)
        }
    }

    private func actionButton(icon: String, color: Color = .secondary, count: Int?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.appSystem(size: 14, weight: .medium))
                    .foregroundColor(color)
                if let count = count, count > 0 {
                    Text("\(count)")
                        .font(.appSystem(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(color)
                }
            }
            .frame(height: 32)
            .padding(.horizontal, (count ?? 0) > 0 ? 10 : 0)
            .frame(minWidth: 32)
            .background(color.opacity(color == .secondary ? 0.1 : 0.15))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
    
    private func fetchReplies() {
        guard !isLoadingReplies else { return }
        isLoadingReplies = true

        // Try local relay AND external relays to find replies
        var relayURLs: [URL] = [configService.config.nostrURL].compactMap { URL(string: $0) }
        let externalStrs = configService.config.activeFeedRelays.isEmpty ? [
            "wss://relay.primal.net",
            "wss://nos.lol",
        ] : configService.config.activeFeedRelays
        relayURLs.append(contentsOf: externalStrs.compactMap { URL(string: $0) })

        let subId = "replies-\(UUID().uuidString.prefix(8))"
        var activeClients: [WebSocketClient] = []

        for url in relayURLs {
            let client = WebSocketClient()
            client.isTemporary = true // Clean up when done
            activeClients.append(client)

            client.messageSubject
                .receive(on: DispatchQueue.main)
                .sink { msg in
                    self.handleReplyMessage(msg, client: client)
                }
                .store(in: &cancellables)

            client.$connectionState
                .receive(on: DispatchQueue.main)
                .sink { state in
                    if state == .connected {
                        let targetRootId = self.threadRootId
                        let activeFocusId = self.focusedNoteId.isEmpty ? self.note.id : self.focusedNoteId
                        
                        let repliesFilter: [String: Any] = ["kinds": [1], "#e": [targetRootId], "limit": 150]
                        let engagementFilter: [String: Any] = ["kinds": [6, 7, 9735], "#e": [activeFocusId], "limit": 150]
                        let req = ["REQ", subId, repliesFilter, engagementFilter] as [Any]
                        if let data = try? JSONSerialization.data(withJSONObject: req),
                           let str = String(data: data, encoding: .utf8) {
                            client.send(text: str)
                        }
                    }
                }
                .store(in: &cancellables)

            client.connect(url: url)
        }
        
        // Auto-disconnect and flush any remaining buffered replies after 6 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) {
            for client in activeClients {
                client.disconnect()
            }
            if self.isLoadingReplies {
                self.flushPendingReplies()
            }
        }
    }

    private func handleReplyMessage(_ msg: String, client: WebSocketClient) {
        guard let data = msg.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let type = json[0] as? String else { return }

        if type == "EVENT", json.count >= 3,
           let ev = json[2] as? [String: Any],
           let id = ev["id"] as? String,
           let pubkey = ev["pubkey"] as? String,
           let content = ev["content"] as? String,
           let createdAt = ev["created_at"] as? Int64,
           let kind = ev["kind"] as? Int,
           let tags = ev["tags"] as? [[String]] {

            if kind == 1 {
                let reply = FeedNote(
                    id: id,
                    pubkey: pubkey,
                    content: content,
                    createdAt: Date(timeIntervalSince1970: TimeInterval(createdAt)),
                    tags: tags,
                    kind: kind
                )

                if !FeedNote.isNoiseOrSpam(content: content, tags: tags) {
                    if isLoadingReplies {
                        // Buffer while loading — all revealed at once on EOSE
                        if !pendingReplies.contains(where: { $0.id == id }) {
                            pendingReplies.append(reply)
                        }
                    } else {
                        // Already revealed — late arrivals added directly
                        if feedService.findNote(id: id) == nil {
                            feedService.addNote(reply)
                        }
                    }

                    // Pre-fetch profile so it's ready by reveal time
                    if nostrService.profiles[pubkey] == nil {
                        nostrService.fetchMissingProfiles(for: [pubkey])
                    }
                }
            } else if kind == 7 {
                if !self.detailedReactions.contains(where: { $0.id == id }) {
                    if let evData = try? JSONSerialization.data(withJSONObject: ev),
                       let event = try? JSONDecoder().decode(NostrEvent.self, from: evData) {
                        self.detailedReactions.append(event)
                        if nostrService.profiles[pubkey] == nil {
                            nostrService.fetchMissingProfiles(for: [pubkey])
                        }
                    }
                }
            } else if kind == 6 {
                if !self.detailedReposts.contains(where: { $0.id == id }) {
                    if let evData = try? JSONSerialization.data(withJSONObject: ev),
                       let event = try? JSONDecoder().decode(NostrEvent.self, from: evData) {
                        self.detailedReposts.append(event)
                        if nostrService.profiles[pubkey] == nil {
                            nostrService.fetchMissingProfiles(for: [pubkey])
                        }
                    }
                }
            } else if kind == 9735 {
                if !self.detailedZaps.contains(where: { $0.id == id }) {
                    if let evData = try? JSONSerialization.data(withJSONObject: ev),
                       let event = try? JSONDecoder().decode(NostrEvent.self, from: evData) {
                        self.detailedZaps.append(event)
                        if let descJson = event.tags.first(where: { $0.count >= 2 && $0[0] == "description" })?[1],
                           let descData = descJson.data(using: .utf8),
                           let zapReq = try? JSONSerialization.jsonObject(with: descData) as? [String: Any],
                           let senderPubkey = zapReq["pubkey"] as? String {
                            if nostrService.profiles[senderPubkey] == nil {
                                nostrService.fetchMissingProfiles(for: [senderPubkey])
                            }
                        }
                    }
                }
            }
        } else if type == "EOSE" {
            client.disconnect()
            if isLoadingReplies {
                flushPendingReplies()
            }
        }
    }

    private func flushPendingReplies() {
        // Add all buffered replies to feedService at once
        for reply in pendingReplies {
            if feedService.findNote(id: reply.id) == nil {
                feedService.addNote(reply)
            }
        }
        pendingReplies.removeAll()

        withAnimation(Motion.fade) {
            isLoadingReplies = false
        }
    }

    /// Fetch replies specifically for a given note ID (used when focus changes within the thread).
    /// The initial fetchReplies() queries by thread root; this catches any replies that only
    /// reference this specific note and not the root (e.g. legacy clients).
    private func fetchRepliesForNote(_ noteId: String) {
        var relayURLs: [URL] = [configService.config.nostrURL].compactMap { URL(string: $0) }
        let externalStrs = configService.config.activeFeedRelays.isEmpty ? [
            "wss://relay.primal.net",
            "wss://nos.lol",
        ] : configService.config.activeFeedRelays
        relayURLs.append(contentsOf: externalStrs.compactMap { URL(string: $0) })

        let subId = "focus-replies-\(UUID().uuidString.prefix(8))"

        for url in relayURLs {
            let client = WebSocketClient()
            client.isTemporary = true

            client.messageSubject
                .receive(on: DispatchQueue.main)
                .sink { msg in
                    guard let data = msg.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
                          let type = json[0] as? String else { return }

                    if type == "EVENT", json.count >= 3,
                       let ev = json[2] as? [String: Any],
                       let id = ev["id"] as? String,
                       let pubkey = ev["pubkey"] as? String,
                       let content = ev["content"] as? String,
                       let createdAt = ev["created_at"] as? Int64,
                       let kind = ev["kind"] as? Int,
                       let tags = ev["tags"] as? [[String]],
                       kind == 1 {

                        let reply = FeedNote(
                            id: id,
                            pubkey: pubkey,
                            content: content,
                            createdAt: Date(timeIntervalSince1970: TimeInterval(createdAt)),
                            tags: tags,
                            kind: kind
                        )

                        if !FeedNote.isNoiseOrSpam(content: content, tags: tags),
                           self.feedService.findNote(id: id) == nil {
                            self.feedService.addNote(reply)
                        }

                        if self.nostrService.profiles[pubkey] == nil {
                            self.nostrService.fetchMissingProfiles(for: [pubkey])
                        }
                    } else if type == "EOSE" {
                        client.disconnect()
                    }
                }
                .store(in: &cancellables)

            client.$connectionState
                .receive(on: DispatchQueue.main)
                .sink { state in
                    if state == .connected {
                        let filter: [String: Any] = ["kinds": [1], "#e": [noteId], "limit": 150]
                        let req = ["REQ", subId, filter] as [Any]
                        if let data = try? JSONSerialization.data(withJSONObject: req),
                           let str = String(data: data, encoding: .utf8) {
                            client.send(text: str)
                        }
                    }
                }
                .store(in: &cancellables)

            client.connect(url: url)

            DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) {
                client.disconnect()
            }
        }
    }

    private func fetchEngagement(for eventId: String) {
        // Clear previous reactions to prevent flash of wrong data
        detailedReactions.removeAll()
        detailedReposts.removeAll()
        detailedZaps.removeAll()

        var relayURLs: [URL] = [configService.config.nostrURL].compactMap { URL(string: $0) }
        let externalStrs = configService.config.activeFeedRelays.isEmpty ? [
            "wss://relay.primal.net",
            "wss://nos.lol",
        ] : configService.config.activeFeedRelays
        relayURLs.append(contentsOf: externalStrs.compactMap { URL(string: $0) })

        let subId = "eng-\(eventId.prefix(6))-\(UUID().uuidString.prefix(4))"
        
        for url in relayURLs {
            let client = WebSocketClient()
            client.isTemporary = true

            client.messageSubject
                .receive(on: DispatchQueue.main)
                .sink { msg in
                    self.handleReplyMessage(msg, client: client)
                }
                .store(in: &cancellables)

            client.$connectionState
                .receive(on: DispatchQueue.main)
                .sink { state in
                    if state == .connected {
                        let filter: [String: Any] = ["kinds": [6, 7, 9735], "#e": [eventId], "limit": 100]
                        let req = ["REQ", subId, filter] as [Any]
                        if let data = try? JSONSerialization.data(withJSONObject: req),
                           let str = String(data: data, encoding: .utf8) {
                            client.send(text: str)
                        }
                    }
                }
                .store(in: &cancellables)

            client.connect(url: url)

            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                client.disconnect()
            }
        }
    }

    // MARK: - Expanded Thread Engagement

    /// All note IDs in the current thread (parents + focused + all replies).
    private var allThreadNoteIds: Set<String> {
        var ids = Set(dynamicParents.map(\.id))
        ids.insert(focusedNote.id)
        // BFS to collect all reply IDs
        var queue = [focusedNote.id]
        while !queue.isEmpty {
            let current = queue.removeFirst()
            let children = feedService.notes.filter { $0.parentEventId == current }
            for child in children {
                if ids.insert(child.id).inserted {
                    queue.append(child.id)
                }
            }
        }
        return ids
    }

    private func fetchAllThreadEngagement() {
        let noteIds = Array(allThreadNoteIds)
        guard !noteIds.isEmpty else { return }
        isLoadingExpandedEngagement = true

        var relayURLs: [URL] = [configService.config.nostrURL].compactMap { URL(string: $0) }
        let externalStrs = configService.config.activeFeedRelays.isEmpty ? [
            "wss://relay.primal.net",
            "wss://nos.lol",
        ] : configService.config.activeFeedRelays
        relayURLs.append(contentsOf: externalStrs.compactMap { URL(string: $0) })

        let subId = "thread-eng-\(UUID().uuidString.prefix(6))"

        for url in relayURLs {
            let client = WebSocketClient()
            client.isTemporary = true
            let threadIds = Set(noteIds)

            client.messageSubject
                .receive(on: DispatchQueue.main)
                .sink { msg in
                    self.handleExpandedEngagementMessage(msg, threadIds: threadIds, client: client)
                }
                .store(in: &cancellables)

            client.$connectionState
                .receive(on: DispatchQueue.main)
                .sink { state in
                    if state == .connected {
                        let filter: [String: Any] = ["kinds": [6, 7, 9735], "#e": noteIds, "limit": 500]
                        let req = ["REQ", subId, filter] as [Any]
                        if let data = try? JSONSerialization.data(withJSONObject: req),
                           let str = String(data: data, encoding: .utf8) {
                            client.send(text: str)
                        }
                    }
                }
                .store(in: &cancellables)

            client.connect(url: url)

            DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) {
                client.disconnect()
                if self.isLoadingExpandedEngagement {
                    self.isLoadingExpandedEngagement = false
                }
            }
        }
    }

    private func handleExpandedEngagementMessage(_ msg: String, threadIds: Set<String>, client: WebSocketClient) {
        guard let data = msg.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let type = json[0] as? String else { return }

        if type == "EVENT", json.count >= 3,
           let ev = json[2] as? [String: Any],
           let id = ev["id"] as? String,
           let pubkey = ev["pubkey"] as? String,
           let kind = ev["kind"] as? Int,
           let tags = ev["tags"] as? [[String]] {

            // Find which thread note this engagement targets (last matching e-tag per NIP-25)
            let eTags = tags.filter { $0.count >= 2 && $0[0] == "e" }
            guard let targetNoteId = eTags.last(where: { threadIds.contains($0[1]) })?[1] else { return }

            guard let evData = try? JSONSerialization.data(withJSONObject: ev),
                  let event = try? JSONDecoder().decode(NostrEvent.self, from: evData) else { return }

            if kind == 7 {
                if !(perNoteReactions[targetNoteId]?.contains(where: { $0.id == id }) ?? false) {
                    perNoteReactions[targetNoteId, default: []].append(event)
                }
            } else if kind == 6 {
                if !(perNoteReposts[targetNoteId]?.contains(where: { $0.id == id }) ?? false) {
                    perNoteReposts[targetNoteId, default: []].append(event)
                }
            } else if kind == 9735 {
                if !(perNoteZaps[targetNoteId]?.contains(where: { $0.id == id }) ?? false),
                   let recipientPubkey = tags.first(where: { $0.count >= 2 && $0[0] == "p" })?[1] {
                    Task {
                        guard await ZapValidationService.isValidReceipt(pubkey: pubkey, recipientPubkey: recipientPubkey) else { return }
                        if !(self.perNoteZaps[targetNoteId]?.contains(where: { $0.id == id }) ?? false) {
                            self.perNoteZaps[targetNoteId, default: []].append(event)
                        }
                    }
                }
            }

            if nostrService.profiles[pubkey] == nil {
                nostrService.fetchMissingProfiles(for: [pubkey])
            }
            // For zaps, also fetch the sender profile
            if kind == 9735,
               let descJson = tags.first(where: { $0.count >= 2 && $0[0] == "description" })?[1],
               let descData = descJson.data(using: .utf8),
               let zapReq = try? JSONSerialization.jsonObject(with: descData) as? [String: Any],
               let senderPubkey = zapReq["pubkey"] as? String,
               nostrService.profiles[senderPubkey] == nil {
                nostrService.fetchMissingProfiles(for: [senderPubkey])
            }
        } else if type == "EOSE" {
            client.disconnect()
            isLoadingExpandedEngagement = false
        }
    }

    // MARK: - Per-Note Engagement Helpers

    private func groupedReactionsForNote(_ noteId: String) -> [(emoji: String, count: Int)] {
        if configService.config.zapsOnlyMode { return [] }
        let reactions = perNoteReactions[noteId] ?? []
        var groups: [String: Int] = [:]
        for rx in reactions {
            let emoji = (rx.content == "+" || rx.content.isEmpty) ? "❤️" : rx.content
            guard emoji.count <= 4 else { continue }
            groups[emoji, default: 0] += 1
        }
        return groups.map { (emoji: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count }
    }

    private func zapTotalForNote(_ noteId: String) -> (count: Int, sats: Int64) {
        let zaps = perNoteZaps[noteId] ?? []
        var totalSats: Int64 = 0
        for zap in zaps {
            if let descJson = zap.tags.first(where: { $0.count >= 2 && $0[0] == "description" })?[1],
               let descData = descJson.data(using: .utf8),
               let zapReq = try? JSONSerialization.jsonObject(with: descData) as? [String: Any],
               let reqTags = zapReq["tags"] as? [[String]],
               let amountTag = reqTags.first(where: { $0.count >= 2 && $0[0] == "amount" }),
               let msats = Int64(amountTag[1]) {
                totalSats += msats / 1000
            }
        }
        return (count: zaps.count, sats: totalSats)
    }

    private func repostCountForNote(_ noteId: String) -> Int {
        Set((perNoteReposts[noteId] ?? []).map(\.pubkey)).count
    }

    private func likeNote() {
        let noteId = note.id
        if feedService.likedEventIds.contains(noteId) {
            UnlikeNotificationManager.shared.startCountdown {
                self.feedService.likedEventIds.remove(noteId)
                var stats = self.feedService.noteStats[noteId] ?? NoteStats()
                stats.reactions = max(0, stats.reactions - 1)
                self.feedService.noteStats[noteId] = stats
                self.feedService.saveInteractionState()
            }
            return
        }
        feedService.likedEventIds.insert(noteId)
        var currentStats = feedService.noteStats[noteId] ?? NoteStats()
        currentStats.reactions += 1
        feedService.noteStats[noteId] = currentStats
        feedService.saveInteractionState()
        let relayHint = ConfigService.shared.config.nostrURL
        Task {
            guard let signed = await nostrService.signEventAsync(kind: 7, content: "+", tags: [["e", noteId, relayHint], ["p", note.pubkey], ["k", String(note.kind)]]) else { return }
            nostrService.postEvent(signed)
        }
    }

    private func reactToNote(with emoji: String) {
        if !feedService.likedEventIds.contains(note.id) {
            feedService.likedEventIds.insert(note.id)

            // Proactively update stats locally
            var currentStats = feedService.noteStats[note.id] ?? NoteStats()
            currentStats.reactions += 1
            feedService.noteStats[note.id] = currentStats

            feedService.saveInteractionState()
        }
        let relayHint = ConfigService.shared.config.nostrURL
        Task {
            guard let signed = await nostrService.signEventAsync(kind: 7, content: emoji, tags: [["e", note.id, relayHint], ["p", note.pubkey], ["k", String(note.kind)]]) else { return }
            nostrService.postEvent(signed)
        }
    }
    
    private func blockUser(hexPubkey: String) {
        guard let data = Bech32.hexToData(hexPubkey),
              let npub = Bech32.encode(hrp: "npub", data: data) else { return }
        configService.blockProfile(npub)
        nostrService.objectWillChange.send()
        presentationMode.wrappedValue.dismiss()
    }
    
    private func repostNote() {
        PendingPostManager.shared.startRepost(sourceNote: note, nostrService: nostrService)
    }

    private func getLightingAddress(for pubkey: String) -> String? {
        if let profile = nostrService.profiles[pubkey] {
            if let lud06 = profile.lud06, !lud06.isEmpty { return "lnurl:" + lud06 }
            if let lud16 = profile.lud16, !lud16.isEmpty { return lud16 }
            // NIP-05 resolves to /.well-known/nostr.json — a completely different endpoint
            // from the LUD-16 /.well-known/lnurlp/ path. Do NOT use NIP-05 as a lightning address.
        }
        return nil
    }
    
    private func zapNote(lud16: String, amount: Int? = nil) async {
        let amountSats = amount ?? (ConfigService.shared.config.defaultZapAmount / 1000)

        do {
            try await ZapService.shared.zapNote(
                noteId: note.id,
                notePubkey: note.pubkey,
                lud16: lud16,
                amountSats: amountSats
            )
            await MainActor.run {
                feedService.zappedEventIds[note.id] = amountSats
                feedService.saveInteractionState()
            }
            // Re-fetch engagement after a delay so the zap receipt has time to propagate
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await MainActor.run {
                fetchEngagement(for: note.id)
            }
        } catch {
            print("Zap failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Thread Loading

    private func fetchParents() {
        // NIP-10: A reply note includes e-tags for all thread ancestors.
        // Extract ALL ancestor IDs and fetch them in a single batch request
        // instead of chasing parents one-by-one with sequential round-trips.
        let ancestorIds = note.tags
            .filter { $0.count >= 2 && $0[0] == "e" }
            .filter { tag in
                // Skip explicitly-marked mentions (not thread ancestors)
                if tag.count >= 4 && tag[3] == "mention" { return false }
                return true
            }
            .map { $0[1] }

        guard !ancestorIds.isEmpty, !isLoadingParents else { return }
        isLoadingParents = true

        var relayURLs: [URL] = [configService.config.nostrURL].compactMap { URL(string: $0) }
        let externalStrs = configService.config.activeFeedRelays.isEmpty ? [
            "wss://relay.primal.net",
            "wss://nos.lol",
        ] : configService.config.activeFeedRelays
        relayURLs.append(contentsOf: externalStrs.compactMap { URL(string: $0) })

        let subId = "thread-\(UUID().uuidString.prefix(8))"

        for url in relayURLs {
            let client = WebSocketClient()
            client.isTemporary = true

            client.messageSubject
                .receive(on: DispatchQueue.main)
                .sink { msg in
                    self.handleParentMessage(msg, client: client)
                }
                .store(in: &cancellables)

            client.$connectionState
                .receive(on: DispatchQueue.main)
                .sink { state in
                    if state == .connected {
                        // Single batch request for ALL ancestors at once
                        let filter: [String: Any] = ["ids": ancestorIds, "limit": 50]
                        let req = ["REQ", subId, filter] as [Any]
                        if let data = try? JSONSerialization.data(withJSONObject: req),
                           let str = String(data: data, encoding: .utf8) {
                            client.send(text: str)
                        }
                    }
                }
                .store(in: &cancellables)

            client.connect(url: url)

            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                client.disconnect()
                if self.isLoadingParents {
                    withAnimation(Motion.fade) {
                        self.isLoadingParents = false
                    }
                }
            }
        }
    }

    private func handleParentMessage(_ msg: String, client: WebSocketClient) {
        guard let data = msg.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let type = json[0] as? String else { return }

        if type == "EVENT", json.count >= 3,
           let ev = json[2] as? [String: Any],
           let id = ev["id"] as? String,
           let pubkey = ev["pubkey"] as? String,
           let content = ev["content"] as? String,
           let createdAt = ev["created_at"] as? Int64,
           let kind = ev["kind"] as? Int,
           let tags = ev["tags"] as? [[String]] {

            let parent = FeedNote(
                id: id,
                pubkey: pubkey,
                content: content,
                createdAt: Date(timeIntervalSince1970: TimeInterval(createdAt)),
                tags: tags,
                kind: kind
            )

            if !parentNotes.contains(where: { $0.id == id }) {
                parentNotes.append(parent)
                parentNotes.sort { $0.createdAt < $1.createdAt }
            }

            // Also store in feedService so focusedNote / dynamicReplies can resolve them
            if feedService.findNote(id: id) == nil {
                feedService.parentNotesCache[id] = parent
            }

            if nostrService.profiles[pubkey] == nil {
                nostrService.fetchMissingProfiles(for: [pubkey])
            }
        } else if type == "EOSE" {
            client.disconnect()
            withAnimation(Motion.fade) {
                isLoadingParents = false
            }
        }
    }

    
    private func relativeTime(_ date: Date) -> String {
        let diff = Date().timeIntervalSince(date)
        switch diff {
        case ..<60:         return "now"
        case ..<3600:       return "\(Int(diff / 60))m"
        case ..<86400:      return "\(Int(diff / 3600))h"
        case ..<604800:     return "\(Int(diff / 86400))d"
        default:
            let fmt = DateFormatter()
            fmt.dateFormat = "MMM d"
            return fmt.string(from: date)
        }
    }

    private func shortKey(_ key: String) -> String {
        guard key.count >= 12 else { return key }
        return "npub…" + String(key.suffix(6))
    }

    // MARK: - Rich Engagement Computations

    private var groupedReactions: [(emoji: String, count: Int, reactorPubkeys: [String])] {
        if configService.config.zapsOnlyMode { return [] }
        var groups: [String: [String]] = [:]
        for rx in detailedReactions {
            let emoji = (rx.content == "+" || rx.content.isEmpty) ? "❤️" : rx.content
            guard emoji.count <= 4 else { continue }
            groups[emoji, default: []].append(rx.pubkey)
        }
        return groups.map { (emoji: $0.key, count: $0.value.count, reactorPubkeys: $0.value) }
            .sorted { $0.count > $1.count }
    }

    struct ZapDetail: Hashable {
        let id: String
        let zapperPubkey: String
        let amountSats: Int64
        let comment: String
    }

    private var parsedZaps: [ZapDetail] {
        var list: [ZapDetail] = []
        for zap in detailedZaps {
            guard let descJson = zap.tags.first(where: { $0.count >= 2 && $0[0] == "description" })?[1],
                  let descData = descJson.data(using: .utf8),
                  let zapReq = try? JSONSerialization.jsonObject(with: descData) as? [String: Any],
                  let senderPubkey = zapReq["pubkey"] as? String else { continue }
            
            var amountSats: Int64 = 0
            if let reqTags = zapReq["tags"] as? [[String]],
               let amountTag = reqTags.first(where: { $0.count >= 2 && $0[0] == "amount" }),
               let msats = Int64(amountTag[1]) {
                amountSats = msats / 1000
            }
            let comment = zapReq["content"] as? String ?? ""
            list.append(ZapDetail(id: zap.id, zapperPubkey: senderPubkey, amountSats: amountSats, comment: comment))
        }
        return list.sorted { $0.amountSats > $1.amountSats }
    }

    private var totalZappedSats: Int64 {
        parsedZaps.reduce(0) { $0 + $1.amountSats }
    }

    private var reactorsMapped: [(pubkey: String, emoji: String)] {
        detailedReactions.map { (pubkey: $0.pubkey, emoji: ($0.content == "+" || $0.content.isEmpty) ? "❤️" : $0.content) }
    }

    private var repostersMapped: [String] {
        Array(Set(detailedReposts.map { $0.pubkey }))
    }

    // MARK: - Engagement Panel View

    @ViewBuilder
    private var engagementDetailSection: some View {
        // Thin separator between note content and engagement
        Rectangle()
            .fill(Color.havenPurple.opacity(0.15))
            .frame(height: 0.5)
            .padding(.top, 10)

        // Compact inline engagement row
        HStack(spacing: 12) {
            // Reactions — tappable pill list
            if !groupedReactions.isEmpty {
                Button {
                    showingReactorsSheet = true
                } label: {
                    HStack(spacing: 4) {
                        ForEach(groupedReactions.prefix(4), id: \.emoji) { group in
                            HStack(spacing: 2) {
                                Text(group.emoji)
                                    .font(.appSystem(size: 12))
                                Text("\(group.count)")
                                    .font(.appSystem(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                        }
                        if groupedReactions.count > 4 {
                            Text("+\(groupedReactions.count - 4)")
                                .font(.appSystem(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.05))
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }

            // Zaps — compact
            if !parsedZaps.isEmpty {
                Button {
                    showingZappersSheet = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "bolt.fill")
                            .font(.appSystem(size: 10, weight: .bold))
                            .foregroundColor(.orange)
                        Text(compactZapText)
                            .font(.appSystem(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.05))
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }

            // Reposts — compact
            if !detailedReposts.isEmpty {
                Button {
                    showingRepostersSheet = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.2.squarepath")
                            .font(.appSystem(size: 10, weight: .bold))
                            .foregroundColor(.green)
                        Text("\(repostersMapped.count)")
                            .font(.appSystem(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.05))
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }

            Spacer()
        }
        .padding(.top, 8)
    }

    private var compactZapText: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        let totalStr = formatter.string(from: NSNumber(value: totalZappedSats)) ?? "\(totalZappedSats)"
        return "\(parsedZaps.count) · \(totalStr)"
    }

}

// MARK: - ZappersListView

struct ZappersListView: View {
    let zaps: [NoteDetailView.ZapDetail]
    var onDismiss: (() -> Void)? = nil
    @EnvironmentObject var nostrService: NostrService
    @Environment(\.presentationMode) var presentationMode
    @State private var selectedProfilePubkey: String?

    var body: some View {
        NavigationView {
            List(zaps, id: \.id) { zap in
                let profile = nostrService.profiles[zap.zapperPubkey]
                Button {
                    selectedProfilePubkey = zap.zapperPubkey
                } label: {
                    HStack(spacing: 12) {
                        AvatarView(url: profile?.pictureURL, pubkey: zap.zapperPubkey, size: 40)
                            .overlay(Circle().stroke(Color.platformSecondaryGroupedBackground, lineWidth: 2))
                            .shadow(color: Color.black.opacity(0.1), radius: 3)

                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(profile?.bestName ?? "npub…" + String(zap.zapperPubkey.suffix(6)))
                                    .font(.appSystem(size: 15, weight: .semibold))
                                    .foregroundColor(.primary)
                                Spacer()
                                Text("\(zap.amountSats) sats")
                                    .font(.appSystem(size: 13, weight: .bold, design: .monospaced))
                                    .foregroundColor(.orange)
                            }
                            if !zap.comment.isEmpty {
                                Text(zap.comment)
                                    .font(.appSystem(size: 13))
                                    .foregroundColor(.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                }
                .buttonStyle(.plain)
                .padding(.vertical, 4)
            }
            .listStyle(.plain)
            .navigationTitle("Zaps")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        if let onDismiss = onDismiss {
                            onDismiss()
                        } else {
                            presentationMode.wrappedValue.dismiss()
                        }
                    }
                }
            }
            .sheet(item: Binding<IdentifiableString?>(
                get: { selectedProfilePubkey.map { IdentifiableString(id: $0) } },
                set: { selectedProfilePubkey = $0?.id }
            )) { p in
                ProfileView(pubkey: p.id, onDismiss: { selectedProfilePubkey = nil })
            }
        }
        #if os(macOS)
        .frame(minWidth: 300, minHeight: 400)
        #endif
    }
}

// MARK: - Thread Note Engagement Row (reusable compact row for expanded view)

struct ThreadNoteEngagementRow: View {
    let reactions: [(emoji: String, count: Int)]
    let zapCount: Int
    let zapSats: Int64
    let repostCount: Int

    private var hasContent: Bool {
        !reactions.isEmpty || zapCount > 0 || repostCount > 0
    }

    var body: some View {
        if hasContent {
            HStack(spacing: 8) {
                if !reactions.isEmpty {
                    HStack(spacing: 3) {
                        ForEach(reactions.prefix(3), id: \.emoji) { group in
                            HStack(spacing: 1) {
                                Text(group.emoji).font(.appSystem(size: 11))
                                Text("\(group.count)")
                                    .font(.appSystem(size: 9, weight: .bold, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                        }
                        if reactions.count > 3 {
                            Text("+\(reactions.count - 3)")
                                .font(.appSystem(size: 9, weight: .bold, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.04))
                    .cornerRadius(6)
                }

                if zapCount > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "bolt.fill")
                            .font(.appSystem(size: 8, weight: .bold))
                            .foregroundColor(.orange)
                        Text(formatSats(zapSats))
                            .font(.appSystem(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.04))
                    .cornerRadius(6)
                }

                if repostCount > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "arrow.2.squarepath")
                            .font(.appSystem(size: 8, weight: .bold))
                            .foregroundColor(.green)
                        Text("\(repostCount)")
                            .font(.appSystem(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.04))
                    .cornerRadius(6)
                }

                Spacer()
            }
            .padding(.top, 4)
        }
    }

    private func formatSats(_ sats: Int64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: sats)) ?? "\(sats)"
    }
}

// MARK: - ThreadedReplyNode

struct ThreadedReplyNode: View {
    let reply: FeedNote
    let allNotes: [FeedNote]
    let depth: Int
    var isCompactMode: Bool = false
    var onReply: ((FeedNote) -> Void)? = nil
    var onQuote: ((FeedNote) -> Void)? = nil
    var onProfile: ((String) -> Void)? = nil
    var onMedia: ((URL, [URL]) -> Void)? = nil
    @Binding var focusedNoteId: String
    let proxy: ScrollViewProxy

    // Expanded engagement data
    var expandedEngagement: Bool = false
    var perNoteReactions: [String: [NostrEvent]] = [:]
    var perNoteReposts: [String: [NostrEvent]] = [:]
    var perNoteZaps: [String: [NostrEvent]] = [:]

    @EnvironmentObject var nostrService: NostrService
    @EnvironmentObject var configService: ConfigService

    var body: some View {
        let childReplies = allNotes.filter { $0.parentEventId == reply.id }
            .sorted(by: { $0.createdAt < $1.createdAt })

        let isCurrentFocused = reply.id == focusedNoteId

        VStack(alignment: .leading, spacing: isCompactMode ? 6 : 8) {
            if isCompactMode {
                compactReplyView(isCurrentFocused: isCurrentFocused, childReplies: childReplies)
            } else {
                fullReplyView(isCurrentFocused: isCurrentFocused)
            }

            if !childReplies.isEmpty {
                if depth >= 3 && !isCompactMode {
                    // Prevent excessive indentation squishing on narrow mobile screens
                    Button {
                        withAnimation(Motion.scrollJump) {
                            focusedNoteId = reply.id
                            proxy.scrollTo(reply.id, anchor: .center)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.turn.down.right")
                                .font(.appSystem(size: 11, weight: .bold))
                            Text("Show \(childReplies.count) more \(childReplies.count == 1 ? "reply" : "replies")")
                                .font(.appSystem(size: 12, weight: .bold, design: .rounded))
                        }
                        .foregroundColor(Color.havenPurple)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 12)
                        .background(Color.havenPurple.opacity(0.1))
                        .cornerRadius(8)
                        .padding(.leading, 8)
                    }
                    .buttonStyle(.plain)
                } else if !isCompactMode {
                    HStack(alignment: .top, spacing: 0) {
                        // Thread vertical connecting line
                        Rectangle()
                            .fill(Color.havenPurple.opacity(0.25))
                            .frame(width: 1.5)
                            .padding(.leading, 8)
                            .padding(.trailing, 6)
                            .padding(.vertical, 2)

                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(childReplies) { child in
                                ThreadedReplyNode(
                                    reply: child,
                                    allNotes: allNotes,
                                    depth: depth + 1,
                                    isCompactMode: isCompactMode,
                                    onReply: onReply,
                                    onQuote: onQuote,
                                    onProfile: onProfile,
                                    onMedia: onMedia,
                                    focusedNoteId: $focusedNoteId,
                                    proxy: proxy,
                                    expandedEngagement: expandedEngagement,
                                    perNoteReactions: perNoteReactions,
                                    perNoteReposts: perNoteReposts,
                                    perNoteZaps: perNoteZaps
                                )
                            }
                        }
                    }
                } else {
                    // Compact mode: show nested replies with visual depth indicators
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(childReplies) { child in
                            ThreadedReplyNode(
                                reply: child,
                                allNotes: allNotes,
                                depth: depth + 1,
                                isCompactMode: isCompactMode,
                                onReply: onReply,
                                onQuote: onQuote,
                                onProfile: onProfile,
                                onMedia: onMedia,
                                focusedNoteId: $focusedNoteId,
                                proxy: proxy,
                                expandedEngagement: expandedEngagement,
                                perNoteReactions: perNoteReactions,
                                perNoteReposts: perNoteReposts,
                                perNoteZaps: perNoteZaps
                            )
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func fullReplyView(isCurrentFocused: Bool) -> some View {
        let replyProfile = nostrService.profiles[reply.pubkey]
        let rowData = FeedNoteRowData.resolve(
            for: reply,
            feedService: FeedService.shared,
            nostrService: nostrService
        )

        // Check if this reply has engagement to show
        let hasEngagement = expandedEngagement && !isCurrentFocused && (
            !groupedReactionsForReply(reply.id).isEmpty ||
            zapTotalForReply(reply.id).count > 0 ||
            repostCountForReply(reply.id) > 0
        )

        VStack(alignment: .leading, spacing: 0) {
            FeedNoteRow(
                note: reply,
                profile: replyProfile,
                rowData: rowData,
                onReply: { onReply?(reply) },
                onQuote: { onQuote?(reply) },
                onProfile: onProfile,
                onMedia: onMedia,
                showParent: false,
                layoutMode: .wide,
                isFocused: isCurrentFocused
            )

            // Expanded engagement for this reply - inside the note box
            if hasEngagement {
                Rectangle()
                    .fill(Color.secondary.opacity(0.1))
                    .frame(height: 0.5)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)

                ThreadNoteEngagementRow(
                    reactions: groupedReactionsForReply(reply.id),
                    zapCount: zapTotalForReply(reply.id).count,
                    zapSats: zapTotalForReply(reply.id).sats,
                    repostCount: repostCountForReply(reply.id)
                )
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
        }
        .id(reply.id)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(Motion.scrollJump) {
                focusedNoteId = reply.id
                proxy.scrollTo(reply.id, anchor: .center)
            }
        }
    }

    @ViewBuilder
    private func compactReplyView(isCurrentFocused: Bool, childReplies: [FeedNote]) -> some View {
        let replyProfile = nostrService.profiles[reply.pubkey]
        let indentMultiplier = min(depth - 1, 5) // Cap indentation at depth 5
        let indentWidth: CGFloat = CGFloat(indentMultiplier) * 16
        let isOLED = ConfigService.shared.config.useOLED

        HStack(alignment: .top, spacing: 8) {
            // Avatar
            AvatarView(url: replyProfile?.pictureURL, pubkey: reply.pubkey)
                .frame(width: 28, height: 28)
                .onTapGesture {
                    onProfile?(reply.pubkey)
                }

            // Content
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(replyProfile?.bestName ?? "npub\u{2026}" + String(reply.pubkey.suffix(6)))
                        .font(.appSystem(size: 12, weight: .semibold))
                        .foregroundColor(.white.opacity(isOLED ? 0.92 : 0.95))
                        .lineLimit(1)

                    if let nip05 = replyProfile?.nip05, !nip05.isEmpty {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.appSystem(size: 8))
                            .foregroundColor(Color.havenPurple.opacity(0.8))
                    }

                    Text("\u{b7} \(relativeTime(reply.createdAt))")
                        .font(.appSystem(size: 10))
                        .foregroundColor(.secondary.opacity(isOLED ? 0.7 : 0.8))

                    Spacer()

                    // Reply count badge
                    if !childReplies.isEmpty {
                        HStack(spacing: 3) {
                            Image(systemName: "text.bubble")
                                .font(.appSystem(size: 9, weight: .medium))
                            Text("\(childReplies.count)")
                                .font(.appSystem(size: 9, weight: .semibold, design: .monospaced))
                        }
                        .foregroundColor(.secondary.opacity(isOLED ? 0.5 : 0.6))
                    }
                }

                if !reply.content.isEmpty {
                    Text(reply.content)
                        .font(.appSystem(size: 12))
                        .foregroundColor(.white.opacity(isOLED ? 0.8 : 0.85))
                        .lineLimit(2)
                        .lineSpacing(1.5)
                        .padding(.top, 1)
                }

                // Compact engagement
                if expandedEngagement {
                    let reactions = groupedReactionsForReply(reply.id)
                    let zapInfo = zapTotalForReply(reply.id)
                    let repostCount = repostCountForReply(reply.id)

                    if !reactions.isEmpty || zapInfo.count > 0 || repostCount > 0 {
                        HStack(spacing: 6) {
                            if !reactions.isEmpty {
                                HStack(spacing: 2) {
                                    Text(reactions.first?.emoji ?? "")
                                        .font(.appSystem(size: 10))
                                    Text("\(reactions.reduce(0) { $0 + $1.count })")
                                        .font(.appSystem(size: 9, weight: .semibold, design: .monospaced))
                                        .foregroundColor(.secondary)
                                }
                            }
                            if zapInfo.count > 0 {
                                HStack(spacing: 2) {
                                    Image(systemName: "bolt.fill")
                                        .font(.appSystem(size: 8))
                                        .foregroundColor(.orange)
                                    Text("\(zapInfo.count)")
                                        .font(.appSystem(size: 9, weight: .semibold, design: .monospaced))
                                        .foregroundColor(.secondary)
                                }
                            }
                            if repostCount > 0 {
                                HStack(spacing: 2) {
                                    Image(systemName: "arrow.2.squarepath")
                                        .font(.appSystem(size: 8))
                                        .foregroundColor(.green)
                                    Text("\(repostCount)")
                                        .font(.appSystem(size: 9, weight: .semibold, design: .monospaced))
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .padding(.top, 2)
                    }
                }
            }
        }
        .id(reply.id)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(
                    isCurrentFocused
                        ? Color.havenPurple.opacity(isOLED ? 0.08 : 0.12)
                        : Color.platformSecondaryGroupedBackground
                )
        )
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.havenPurple.opacity(0.015))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    isCurrentFocused
                        ? Color.havenPurple.opacity(isOLED ? 0.6 : 0.4)
                        : Color.havenPurple.opacity(isOLED ? 0.30 : 0.15),
                    lineWidth: isCurrentFocused ? 1.5 : (isOLED ? 1.0 : 0.5)
                )
        )
        .padding(.leading, indentWidth)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(Motion.scrollJump) {
                focusedNoteId = reply.id
                proxy.scrollTo(reply.id, anchor: .center)
            }
        }
    }

    private func depthIndicatorColor(for depth: Int) -> Color {
        // Simplified to use consistent theme color throughout
        return Color.havenPurple.opacity(0.6)
    }

    private func relativeTime(_ date: Date) -> String {
        let diff = Date().timeIntervalSince(date)
        switch diff {
        case ..<60:         return "now"
        case ..<3600:       return "\(Int(diff / 60))m"
        case ..<86400:      return "\(Int(diff / 3600))h"
        case ..<604800:     return "\(Int(diff / 86400))d"
        default:
            let fmt = DateFormatter()
            fmt.dateFormat = "MMM d"
            return fmt.string(from: date)
        }
    }

    // Per-note engagement helpers for this reply node
    private func groupedReactionsForReply(_ noteId: String) -> [(emoji: String, count: Int)] {
        if configService.config.zapsOnlyMode { return [] }
        let reactions = perNoteReactions[noteId] ?? []
        var groups: [String: Int] = [:]
        for rx in reactions {
            let emoji = (rx.content == "+" || rx.content.isEmpty) ? "❤️" : rx.content
            guard emoji.count <= 4 else { continue }
            groups[emoji, default: 0] += 1
        }
        return groups.map { (emoji: $0.key, count: $0.value) }.sorted { $0.count > $1.count }
    }

    private func zapTotalForReply(_ noteId: String) -> (count: Int, sats: Int64) {
        let zaps = perNoteZaps[noteId] ?? []
        var totalSats: Int64 = 0
        for zap in zaps {
            if let descJson = zap.tags.first(where: { $0.count >= 2 && $0[0] == "description" })?[1],
               let descData = descJson.data(using: .utf8),
               let zapReq = try? JSONSerialization.jsonObject(with: descData) as? [String: Any],
               let reqTags = zapReq["tags"] as? [[String]],
               let amountTag = reqTags.first(where: { $0.count >= 2 && $0[0] == "amount" }),
               let msats = Int64(amountTag[1]) {
                totalSats += msats / 1000
            }
        }
        return (count: zaps.count, sats: totalSats)
    }

    private func repostCountForReply(_ noteId: String) -> Int {
        Set((perNoteReposts[noteId] ?? []).map(\.pubkey)).count
    }
}

// MARK: - NoteDetailViewWrapper

struct NoteDetailViewWrapper: View {
    let noteId: String
    var onDismiss: (() -> Void)? = nil
    @State private var resolvedNote: FeedNote?
    @State private var isLoading = true
    @State private var error: String?

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var nostrService: NostrService
    @EnvironmentObject var configService: ConfigService
    @StateObject private var feedService = FeedService.shared
    @State private var cancellables = Set<AnyCancellable>()

    var body: some View {
        NavigationStack {
            Group {
                if let note = resolvedNote {
                    NoteDetailView(note: note)
                } else if isLoading {
                    VStack {
                        ProgressView()
                        Text("Fetching note...")
                            .foregroundColor(.secondary)
                            .padding()
                    }
                } else if let error = error {
                    VStack {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.appLargeTitle)
                        Text(error)
                            .padding()
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        if let onDismiss = onDismiss {
                            onDismiss()
                        } else {
                            dismiss()
                        }
                    }
                }
            }
        }
        .onAppear {
            fetchNote()
        }
    }

    private func fetchNote() {
        if let existing = feedService.findNote(id: noteId) {
            self.resolvedNote = existing
            self.isLoading = false
            return
        }

        // Build the appropriate REQ filter based on identifier type
        let filter: [String: Any]
        if noteId.hasPrefix("naddr1") {
            // NIP-19 naddr TLV: type 0 = d-tag, type 1 = relay, type 2 = pubkey, type 3 = kind
            guard let decoded = Bech32.decode(noteId) else {
                self.isLoading = false
                self.error = "Invalid naddr identifier"
                return
            }
            var data = decoded.data
            var dTag: String?
            var pubkey: String?
            var kind: Int?
            while data.count >= 2 {
                let tlvType = data.removeFirst()
                let length = Int(data.removeFirst())
                guard data.count >= length else { break }
                let value = data.prefix(length)
                switch tlvType {
                case 0: dTag = String(data: Data(value), encoding: .utf8)
                case 2 where length == 32: pubkey = value.map { String(format: "%02x", $0) }.joined()
                case 3 where length == 4:
                    kind = Int(Data(value).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })
                default: break
                }
                data.removeFirst(length)
            }
            guard let k = kind, let p = pubkey else {
                self.isLoading = false
                self.error = "Could not decode naddr"
                return
            }
            filter = ["kinds": [k], "authors": [p], "#d": [dTag ?? ""], "limit": 1]
        } else {
            let hexId: String
            if noteId.hasPrefix("note1") {
                hexId = Bech32.decode(noteId)?.hexString ?? noteId
            } else if noteId.hasPrefix("nevent1") {
                hexId = noteId // Simplified
            } else {
                hexId = noteId
            }
            filter = ["ids": [hexId], "limit": 1]
        }

        let relays = [configService.config.nostrURL, "wss://relay.primal.net"].compactMap { URL(string: $0) }
        guard !relays.isEmpty else { return }

        for url in relays {
            let client = WebSocketClient()
            client.isTemporary = true

            client.messageSubject
                .receive(on: DispatchQueue.main)
                .sink { msg in
                    self.handleNoteMessage(msg, client: client)
                }
                .store(in: &cancellables)

            client.$connectionState
                .receive(on: DispatchQueue.main)
                .sink { state in
                    if state == .connected {
                        let req = ["REQ", "load-\(UUID().uuidString.prefix(8))", filter] as [Any]
                        if let data = try? JSONSerialization.data(withJSONObject: req),
                           let str = String(data: data, encoding: .utf8) {
                            client.send(text: str)
                        }
                    }
                }
                .store(in: &cancellables)

            client.connect(url: url)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            if self.isLoading {
                self.isLoading = false
                if self.resolvedNote == nil {
                    self.error = "Could not find note"
                }
            }
        }
    }

    private func handleNoteMessage(_ msg: String, client: WebSocketClient) {
        guard let data = msg.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let type = json[0] as? String, type == "EVENT",
              let ev = json[2] as? [String: Any],
              let id = ev["id"] as? String,
              let pubkey = ev["pubkey"] as? String,
              let content = ev["content"] as? String,
              let createdAt = ev["created_at"] as? Int64,
              let kind = ev["kind"] as? Int,
              let tags = ev["tags"] as? [[String]] else { return }

        let note = FeedNote(
            id: id,
            pubkey: pubkey,
            content: content,
            createdAt: Date(timeIntervalSince1970: TimeInterval(createdAt)),
            tags: tags,
            kind: kind
        )
        
        DispatchQueue.main.async {
            self.resolvedNote = note
            self.isLoading = false
            client.disconnect()
        }
    }
}

// MARK: - Note Detail Selection

/// Selection model for the iPad two-pane note layout.
///
/// When a `NoteDetailSelection` is present in the environment, note rows select
/// into a sibling detail pane instead of pushing a destination over the whole
/// pane (or presenting a full-screen sheet). Views that can open a note check
/// for one and fall back to their existing push/sheet behaviour when it is
/// absent — which is always the case on iPhone and on macOS.
final class NoteDetailSelection: ObservableObject {
    /// Selected note, when the caller already holds the decoded event.
    @Published var note: FeedNote?
    /// Selected note id, for callers that only know the id and need a lookup.
    @Published var noteId: String?

    var isEmpty: Bool { note == nil && noteId == nil }

    func select(_ note: FeedNote) {
        noteId = nil
        self.note = note
    }

    func select(id: String) {
        note = nil
        noteId = id
    }

    func clear() {
        note = nil
        noteId = nil
    }
}

private struct NoteDetailSelectionKey: EnvironmentKey {
    static let defaultValue: NoteDetailSelection? = nil
}

extension EnvironmentValues {
    var noteDetailSelection: NoteDetailSelection? {
        get { self[NoteDetailSelectionKey.self] }
        set { self[NoteDetailSelectionKey.self] = newValue }
    }
}

// MARK: - Note Navigation Link

/// Opens a note the right way for the layout it finds itself in: a
/// `NavigationLink` push inside a plain navigation stack, or a selection into
/// the detail pane when the iPad two-pane layout supplies one.
///
/// Drop-in replacement for `NavigationLink(value: someFeedNote)`.
struct NoteNavigationLink<Label: View>: View {
    let note: FeedNote
    @ViewBuilder var label: () -> Label

    @Environment(\.noteDetailSelection) private var selection

    var body: some View {
        if let selection {
            // A tap gesture, NOT a Button. Note rows embed their own Buttons for
            // reply/repost/like/zap, and on iOS a Button nested inside another
            // Button never receives the tap -- the outer one swallows it, so
            // every action in the row dies. NavigationLink does not have that
            // problem, which is why the push path can stay a link. This mirrors
            // what the macOS branch of FeedView already does for the same reason.
            label()
                .contentShape(Rectangle())
                .onTapGesture {
                    selection.select(note)
                }
        } else {
            NavigationLink(value: note) {
                label()
            }
            .buttonStyle(.plain)
        }
    }
}
