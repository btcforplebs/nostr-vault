import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct IdentifiableString: Identifiable {
    let id: String
}

private struct ComposeContext: Identifiable {
    let id = UUID()
    let replyTo: FeedNote?
    let quoteTo: FeedNote?
}

// MARK: - FeedView

struct FeedView: View {
    @StateObject private var feedService = FeedService.shared
    @EnvironmentObject var relayManager: RelayProcessManager
    @EnvironmentObject var configService: ConfigService
    @EnvironmentObject var nostrService: NostrService
    @State private var composeContext: ComposeContext?
    @State private var showingRelayStatus = false
    @State private var showingNoteId: String?
    @State private var showingProfileKey: IdentifiableString?
    @State private var showingMediaUrl: IdentifiableURL?
    @State private var isRefreshing = false

    var body: some View {
        #if os(iOS)
        NavigationStack {
            rootContent
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .navigationDestination(for: FeedNote.self) { note in
                    NoteDetailView(note: note)
                }
        }
        #else
        VStack(spacing: 0) {
            macFeedHeader
            Divider()
            rootContent
        }
        #endif
    }

    #if os(macOS)
    private var macFeedHeader: some View {
        HStack(spacing: 12) {
            // Connection dot
            Button(action: { showingRelayStatus = true }) {
                Circle()
                    .fill(feedService.connectionDotColor)
                    .frame(width: 10, height: 10)
                    .shadow(color: feedService.connectionDotColor.opacity(0.8), radius: 3)
            }
            .buttonStyle(.plain)
            .help("Relay Status")

            // Feed mode picker
            Menu {
                ForEach(FeedMode.allCases, id: \.self) { mode in
                    Button(action: { feedService.switchMode(mode) }) {
                        let displayName = mode == .discovery ? "Discover" : mode.rawValue
                        Label(displayName, systemImage: feedService.feedMode == mode ? "checkmark" : "")
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    let displayName = feedService.feedMode == .discovery ? "Discover" : feedService.feedMode.rawValue
                    Text(displayName)
                        .font(.system(size: 13, weight: .semibold))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                }
                .foregroundColor(.primary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Spacer()

            // Auto-load new posts
            Button(action: { configService.config.autoLoadNewPosts.toggle(); configService.save() }) {
                Image(systemName: configService.config.autoLoadNewPosts ? "bolt.circle.fill" : "bolt.circle")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(configService.config.autoLoadNewPosts ? Color.havenPurple : .secondary)
            }
            .buttonStyle(.plain)
            .help(configService.config.autoLoadNewPosts ? "Auto-load On" : "Auto-load Off")

            // Reposts toggle
            Button(action: { configService.config.showReposts.toggle(); configService.save() }) {
                Image(systemName: "arrow.2.squarepath")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(configService.config.showReposts ? Color.havenPurple : .secondary)
            }
            .buttonStyle(.plain)
            .help(configService.config.showReposts ? "Hide Reposts" : "Show Reposts")

            // Replies toggle
            Button(action: { configService.config.showReplies.toggle(); configService.save() }) {
                Image(systemName: configService.config.showReplies ? "message.fill" : "message")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(configService.config.showReplies ? Color.havenPurple : .secondary)
            }
            .buttonStyle(.plain)
            .help(configService.config.showReplies ? "Hide Replies" : "Show Replies")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(red: 0.12, green: 0.12, blue: 0.16))
    }
    #endif

    @ViewBuilder
    private var rootContent: some View {
        ZStack {
            // Match the platform theme background
            Color(red: 0.08, green: 0.08, blue: 0.1).ignoresSafeArea()

            Group {
                // Only show the full-screen contact-loading spinner when there
                // are no cached notes to render. Once a snapshot has been
                // restored (or notes have streamed in), the background sync
                // is surfaced via the inline `syncingPill` instead.
                if feedService.feedMode == .following && feedService.isLoadingContacts && feedService.notes.isEmpty {
                    loadingContactsView
                } else if feedService.feedMode == .discovery && feedService.isLoadingExtendedNetwork && feedService.notes.isEmpty {
                    loadingExtendedNetworkView
                } else if feedService.feedMode == .following && feedService.followedPubkeys.isEmpty && !feedService.isLoadingFeed && !feedService.isLoadingContacts {
                    emptyStateView
                } else if feedService.feedMode == .discovery && feedService.extendedNetworkPubkeys.isEmpty && !feedService.isLoadingFeed && !feedService.isLoadingExtendedNetwork {
                    emptyDiscoveryStateView
                } else {
                    feedList
                }
            }
        }
        #if os(iOS)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                HStack(spacing: 8) {
                    Button(action: { showingRelayStatus = true }) {
                        Circle()
                            .fill(feedService.connectionDotColor)
                            .frame(width: 12, height: 12)
                            .shadow(color: feedService.connectionDotColor.opacity(0.8), radius: 4)
                            .padding(8)
                            .background(Color.primary.opacity(0.08))
                            .clipShape(Circle())
                    }
                    
                    Menu {
                        ForEach(FeedMode.allCases, id: \.self) { mode in
                            Button(action: { feedService.switchMode(mode) }) {
                                let displayName = mode == .discovery ? "Discover" : mode.rawValue
                                Label(displayName, systemImage: feedService.feedMode == mode ? "checkmark" : "")
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            let displayName = feedService.feedMode == .discovery ? "Discover" : feedService.feedMode.rawValue
                            Text(displayName)
                                .font(.system(size: 20, weight: .bold))
                            Image(systemName: "chevron.down")
                                .font(.system(size: 10, weight: .bold))
                        }
                        .foregroundColor(.white)
                    }
                }
            }

            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 16) {
                    // Autoload new posts button
                    Button(action: { configService.config.autoLoadNewPosts.toggle(); configService.save() }) {
                        Image(systemName: configService.config.autoLoadNewPosts ? "bolt.circle.fill" : "bolt.circle")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(configService.config.autoLoadNewPosts ? Color.havenPurple : .secondary)
                    }
                    
                    // Reposts toggle button
                    Button(action: { configService.config.showReposts.toggle(); configService.save() }) {
                        Image(systemName: "arrow.2.squarepath")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(configService.config.showReposts ? Color.havenPurple : .secondary)
                    }
                    
                    // Replies toggle button
                    Button(action: { configService.config.showReplies.toggle(); configService.save() }) {
                        Image(systemName: configService.config.showReplies ? "message.fill" : "message")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(configService.config.showReplies ? Color.havenPurple : .secondary)
                    }
                }
            }
        }
        #endif
        .onAppear {
            feedService.markViewed()
            // Start feed immediately when running, even if still booting.
            // localRelayURL returns nil during boot so no WebSocket errors occur;
            // external relays are contacted right away instead of waiting ~3 minutes.
            if feedService.notes.isEmpty && !feedService.isLoadingContacts {
                feedService.refresh()
            }
        }
        .onChange(of: relayManager.isRunning) { _, running in
            if running && feedService.notes.isEmpty && !feedService.isLoadingContacts {
                feedService.refresh()
            }
        }
        .onChange(of: relayManager.isBooting) { _, booting in
            // Once booting finishes the local relay becomes available — re-subscribe
            // so the feed can pull from it too (unless the feed already populated).
            if !booting && relayManager.isRunning && !feedService.isLoadingFeed {
                feedService.refresh()
            }
        }
        .sheet(item: $composeContext) { ctx in
            ComposeView(onDismiss: { composeContext = nil }, replyTo: ctx.replyTo, quoteTo: ctx.quoteTo)
                .environmentObject(nostrService)
                .environmentObject(configService)
        }
        .sheet(isPresented: $showingRelayStatus) {
            RelayStatusSheet(onDismiss: { showingRelayStatus = false })
                .environmentObject(relayManager)
                .environmentObject(configService)
                .environmentObject(nostrService)
        }
        .sheet(item: Binding<IdentifiableString?>(
            get: { showingNoteId.map { IdentifiableString(id: $0) } },
            set: { showingNoteId = $0?.id }
        )) { noteId in
            NoteDetailViewWrapper(noteId: noteId.id, onDismiss: { showingNoteId = nil })
                .environmentObject(nostrService)
                .environmentObject(configService)
        }
        .sheet(item: $showingProfileKey) { p in
            ProfileView(pubkey: p.id, onDismiss: { showingProfileKey = nil })
                .environmentObject(nostrService)
                .environmentObject(configService)
        }
        .sheet(item: $showingMediaUrl) { media in
            FeedMediaViewer(url: media.url, onDismiss: { showingMediaUrl = nil })
        }
    }

    // MARK: - Loading Contacts

    private var loadingContactsView: some View {
        VStack(spacing: 32) {
            VStack(spacing: 16) {
                ProgressView()
                    .controlSize(.large)
                    .tint(Color.havenPurple)

                VStack(spacing: 8) {
                    Text("Synchronizing")
                        .font(.system(size: 18, weight: .bold, design: .default))
                        .tracking(0.3)
                    Text("fetching your follows")
                        .font(.system(size: 13, weight: .regular, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }

            Text("This may take a moment")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary.opacity(0.6))
                .tracking(0.5)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.platformControlBackground)
    }

    private var loadingExtendedNetworkView: some View {
        VStack(spacing: 32) {
            VStack(spacing: 16) {
                ProgressView()
                    .controlSize(.large)
                    .tint(Color.havenPurple)

                VStack(spacing: 8) {
                    Text("Analyzing Network")
                        .font(.system(size: 18, weight: .bold, design: .default))
                        .tracking(0.3)
                    Text("finding mutual connections")
                        .font(.system(size: 13, weight: .regular, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }

            Text("This may take a moment")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary.opacity(0.6))
                .tracking(0.5)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.platformControlBackground)
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 40) {
            if relayManager.isBooting {
                // Relay is still starting up
                VStack(spacing: 16) {
                    ProgressView()
                        .controlSize(.large)
                        .tint(Color.havenPurple)

                    VStack(spacing: 12) {
                        Text("Relay Starting...")
                            .font(.system(size: 22, weight: .bold, design: .default))
                            .tracking(0.2)

                        Text(relayManager.bootStatusMessage.isEmpty ? "Initializing relay" : relayManager.bootStatusMessage)
                            .font(.system(size: 13, weight: .regular, design: .monospaced))
                            .foregroundColor(.secondary)
                            .tracking(0.3)
                            .multilineTextAlignment(.center)
                    }
                }
            } else {
                // Relay is running but no follows
                VStack(spacing: 16) {
                    Image(systemName: "person.crop.circle.badge.plus")
                        .font(.system(size: 56, weight: .thin))
                        .foregroundStyle(
                            LinearGradient(
                                gradient: Gradient(colors: [Color.havenPurple, Color.havenPurpleLight]),
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )

                    VStack(spacing: 12) {
                        Text("No Following Feed")
                            .font(.system(size: 22, weight: .bold, design: .default))
                            .tracking(0.2)

                        Text("Follow npubs on Nostr to see their posts here")
                            .font(.system(size: 13, weight: .regular, design: .monospaced))
                            .foregroundColor(.secondary)
                            .tracking(0.3)
                    }
                }

                Button {
                    feedService.refresh()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.clockwise")
                        Text("Refresh Feed")
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        LinearGradient(
                            gradient: Gradient(colors: [Color.havenPurple, Color.havenPurpleLight]),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .cornerRadius(10)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(max(16, min(48, 24))) // Adaptive padding
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.platformControlBackground)
    }

    private var emptyDiscoveryStateView: some View {
        VStack(spacing: 40) {
            if relayManager.isBooting {
                // Relay is still starting up
                VStack(spacing: 16) {
                    ProgressView()
                        .controlSize(.large)
                        .tint(Color.havenPurple)

                    VStack(spacing: 12) {
                        Text("Relay Starting...")
                            .font(.system(size: 22, weight: .bold, design: .default))
                            .tracking(0.2)

                        Text(relayManager.bootStatusMessage.isEmpty ? "Initializing relay" : relayManager.bootStatusMessage)
                            .font(.system(size: 13, weight: .regular, design: .monospaced))
                            .foregroundColor(.secondary)
                            .tracking(0.3)
                            .multilineTextAlignment(.center)
                    }
                }
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "network.badge.shield.half.filled")
                        .font(.system(size: 56, weight: .thin))
                        .foregroundStyle(
                            LinearGradient(
                                gradient: Gradient(colors: [Color.havenPurple, Color.havenPurpleLight]),
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )

                    VStack(spacing: 12) {
                        Text("No Discovery Feed")
                            .font(.system(size: 22, weight: .bold, design: .default))
                            .tracking(0.2)

                        Text("Follow more people on Nostr to build your extended network")
                            .font(.system(size: 13, weight: .regular, design: .monospaced))
                            .foregroundColor(.secondary)
                            .tracking(0.3)
                            .multilineTextAlignment(.center)
                    }
                }

                Button {
                    feedService.refresh()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.clockwise")
                        Text("Refresh Feed")
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        LinearGradient(
                            gradient: Gradient(colors: [Color.havenPurple, Color.havenPurpleLight]),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .cornerRadius(10)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(max(16, min(48, 24))) // Adaptive padding
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.platformControlBackground)
    }

    // MARK: - Feed List

    private var feedList: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .top) {
                ScrollView {
                    VStack(spacing: 0) {
                        // Anchor for scroll-to-top
                        Color.clear
                            .frame(height: 1)
                            .id("top")

                        LazyVStack(spacing: 12) {

                        // Loading header
                        if feedService.isLoadingFeed && feedService.notes.isEmpty {
                            ForEach(0..<5, id: \.self) { _ in
                                FeedNoteSkeletonRow()
                                    .padding(.horizontal, 16)
                            }
                        }

                        let filteredNotes = feedService.notes.filter { note in
                            let isBlacklisted = configService.activeAccountBlockedHexPubkeys.contains(note.pubkey)
                            if isBlacklisted { return false }
                            
                            // Check reposts toggle preference
                            let isRepost = note.kind == 6
                            if isRepost && !configService.config.showReposts {
                                return false
                            }
                            
                            // In Global feed mode, we always filter out replies because they lack context and are extremely noisy.
                            if feedService.feedMode == .global {
                                return !note.isReply
                            }
                            
                            // In Following feed mode, respect the user's preference
                            return configService.config.showReplies || !note.isReply
                        }

                        ForEach(Array(filteredNotes.enumerated()), id: \.element.id) { index, note in
                            let profile = nostrService.profiles[note.pubkey]

                            // Optimization: If the parent is the very next note in the feed,
                            // don't show the redundant parent header.
                            let parentIsNext = index + 1 < filteredNotes.count &&
                                             filteredNotes[index+1].id == note.parentEventId

                            #if os(iOS)
                            NavigationLink(value: note) {
                                FeedNoteRow(
                                    note: note,
                                    profile: profile,
                                    onReply: {
                                        if note.kind == 6, let refId = note.repostedEventId,
                                           let original = feedService.findNote(id: refId) {
                                            composeContext = ComposeContext(replyTo: original, quoteTo: nil)
                                        } else {
                                            composeContext = ComposeContext(replyTo: note, quoteTo: nil)
                                        }
                                    },
                                    onQuote: {
                                        composeContext = ComposeContext(replyTo: nil, quoteTo: note)
                                    },
                                    onProfile: { pubkey in
                                        showingProfileKey = IdentifiableString(id: pubkey)
                                    },
                                    onMedia: { url in
                                        showingMediaUrl = IdentifiableURL(url: url)
                                    },
                                    showParent: !parentIsNext,
                                    isReplyToNext: parentIsNext
                                )
                                .padding(.horizontal, 16)
                            }
                            .buttonStyle(.plain)
                            #else
                            FeedNoteRow(
                                note: note,
                                profile: profile,
                                onReply: {
                                    if note.kind == 6, let refId = note.repostedEventId,
                                       let original = feedService.notes.first(where: { $0.id == refId }) {
                                        composeContext = ComposeContext(replyTo: original, quoteTo: nil)
                                    } else {
                                        composeContext = ComposeContext(replyTo: note, quoteTo: nil)
                                    }
                                },
                                onQuote: {
                                    composeContext = ComposeContext(replyTo: nil, quoteTo: note)
                                },
                                onProfile: { pubkey in
                                    showingProfileKey = IdentifiableString(id: pubkey)
                                },
                                onMedia: { url in
                                    showingMediaUrl = IdentifiableURL(url: url)
                                },
                                showParent: !parentIsNext,
                                isReplyToNext: parentIsNext
                            )
                            .padding(.horizontal, 16)
                            .onTapGesture {
                                showingNoteId = note.id
                            }
                            #endif
                        }

                        // Load more
                        if !feedService.notes.isEmpty {
                            Button {
                                feedService.loadMore()
                            } label: {
                                HStack(spacing: 8) {
                                    if feedService.isLoadingFeed {
                                        ProgressView().controlSize(.small).tint(Color.havenPurple)
                                    } else {
                                        Image(systemName: "chevron.down")
                                            .font(.system(size: 12, weight: .semibold))
                                    }
                                    Text(feedService.isLoadingFeed ? "Loading..." : "Show earlier")
                                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                }
                                .foregroundColor(.secondary)
                                .padding(.vertical, 12)
                                .frame(maxWidth: .infinity)
                                .background(Color.platformTertiaryGroupedBackground)
                                .cornerRadius(10)
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.platformSeparator, lineWidth: 1))
                                .padding(.horizontal, 16)
                            }
                            .buttonStyle(.plain)
                            .disabled(feedService.isLoadingFeed)
                        }

                        Color.clear.frame(height: 80) // Space for floating button
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    }
                }
                .refreshable {
                    isRefreshing = true
                    feedService.refresh()
                    // Hold the indicator until loading finishes
                    while feedService.isLoadingFeed {
                        try? await Task.sleep(nanoseconds: 100_000_000)
                    }
                    isRefreshing = false
                }
                .tint(Color.secondary.opacity(0.6))
                .onChange(of: feedService.isLoadingFeed) { _, isLoading in
                    if !isLoading {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                                proxy.scrollTo("top", anchor: .top)
                            }
                        }
                    }
                }

                // Inline "Syncing…" pill: shown while a background top-up runs
                // against an already-rendered snapshot (account switch back).
                // Suppressed when the "New Posts" pill is showing or the full
                // loading spinner is up.
                if feedService.isSyncing && feedService.pendingNotes.isEmpty && !feedService.notes.isEmpty {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                        Text("Syncing…")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundColor(.white)
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 14)
                    .background(
                        Capsule()
                            .fill(Color.black.opacity(0.55))
                            .shadow(color: Color.black.opacity(0.3), radius: 6, x: 0, y: 3)
                    )
                    .padding(.top, 12)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .zIndex(1)
                }

                // Floating "New Posts" indicator
                if !feedService.pendingNotes.isEmpty {
                    Button(action: {
                        feedService.applyPendingNotes()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                                proxy.scrollTo("top", anchor: .top)
                            }
                        }
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 12, weight: .bold))
                            Text("\(feedService.pendingNotes.count) New Posts")
                                .font(.system(size: 13, weight: .bold))
                        }
                        .padding(.vertical, 10)
                        .padding(.horizontal, 20)
                        .background(
                            Capsule()
                                .fill(Color.havenPurple)
                                .shadow(color: Color.black.opacity(0.4), radius: 8, x: 0, y: 4)
                        )
                        .foregroundColor(.white)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 12)
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .opacity.combined(with: .scale(scale: 0.8))
                    ))
                    .zIndex(1)
                }

                // Floating zap status pill
                ZapNotificationBanner()
                    .zIndex(2)
            }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ScrollToTop"))) { _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                        proxy.scrollTo("top", anchor: .top)
                    }
                }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            #if os(iOS)
            Button {
                composeContext = ComposeContext(replyTo: nil, quoteTo: nil)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 15, weight: .bold))
                    Text("Post")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                }
                .foregroundColor(.white)
                .frame(height: 48)
                .padding(.horizontal, 16)
                .background(
                    Capsule()
                        .fill(
                            LinearGradient(
                                gradient: Gradient(colors: [Color.havenPurple, Color.havenPurpleLight]),
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .shadow(color: Color.havenPurple.opacity(0.35), radius: 10, x: 0, y: 5)
                )
            }
            .padding(.trailing, 20)
            .padding(.bottom, 96)
            .hoverEffect(.lift)
            #endif
        }
    }
}

// MARK: - FeedNoteRow

struct FeedNoteRow: View {
    let note: FeedNote
    let profile: FeedProfile?
    var onReply: (() -> Void)? = nil
    var onQuote: (() -> Void)? = nil
    var onProfile: ((String) -> Void)? = nil
    var onMedia: ((URL) -> Void)? = nil
    var showParent: Bool = true
    var isReplyToNext: Bool = false

    @StateObject private var feedService = FeedService.shared
    @EnvironmentObject var nostrService: NostrService
    @EnvironmentObject var configService: ConfigService

    @State private var showingEmojiPicker = false
    @State private var showLightning = false
    @State private var showAmountPicker = false
    @State private var zapAmountSats: String = ""
    
    @State private var repostTask: Task<Void, Never>?
    @State private var showingRepostUndo = false
    @State private var timeRemaining = 5.0
    @State private var postCreationCountdownTask: Task<Void, Never>?
    @State private var showingPostCreatedCountdown = false
    @State private var postCreationTimeRemaining = 10.0
    @State private var showingDeleteConfirm = false
    @State private var showingBroadcastSheet = false
    @State private var noLightningAddressAlert = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Threading View: Parent Note Preview (shows above the current note)
            if showParent, let pId = note.parentEventId {
                if let parent = feedService.findNote(id: pId) {
                    NavigationLink(value: parent) {
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(alignment: .top, spacing: 12) {
                                VStack(spacing: 0) {
                                    let parentProfile = nostrService.profiles[parent.pubkey]
                                    AvatarView(url: parentProfile?.pictureURL, pubkey: parent.pubkey)
                                        .frame(width: 28, height: 28)
                                        .opacity(1.0)
                                        .onTapGesture {
                                            onProfile?(parent.pubkey)
                                        }

                                    Rectangle()
                                        .fill(Color.havenPurple.opacity(0.3))
                                        .frame(width: 2, height: 14)
                                }
                                .frame(width: 40) // Match main avatar container width

                                VStack(alignment: .leading, spacing: 1) {
                                    let parentProfile = nostrService.profiles[parent.pubkey]
                                    Text(parentProfile?.bestName ?? "Someone")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundColor(Color(red: 0.8, green: 0.8, blue: 0.8))

                                    Text(NostrContentFormatter.format(parent.content, mediaURLs: parent.mediaURLs))
                                        .font(.system(size: 13, weight: .regular))
                                        .foregroundColor(Color(red: 0.7, green: 0.7, blue: 0.7))
                                        .lineLimit(2)
                                }
                                .padding(.top, 2)
                                .padding(.bottom, 8)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    // Skeleton while parent is being fetched
                    HStack(alignment: .top, spacing: 12) {
                        VStack(spacing: 0) {
                            Circle()
                                .fill(Color.platformTertiaryGroupedBackground)
                                .frame(width: 28, height: 28)
                            Rectangle()
                                .fill(Color.havenPurple.opacity(0.3))
                                .frame(width: 2, height: 14)
                        }
                        .frame(width: 40)
                        VStack(alignment: .leading, spacing: 5) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.platformTertiaryGroupedBackground)
                                .frame(width: 80, height: 10)
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.platformTertiaryGroupedBackground)
                                .frame(width: 140, height: 10)
                        }
                        .padding(.top, 2)
                        .padding(.bottom, 8)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .onAppear {
                        feedService.fetchMissingNote(id: pId)
                    }
                }
            }

            // Repost indicator
            if let reposter = note.repostedBy {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.2.squarepath")
                        .font(.system(size: 10, weight: .semibold))
                    Text("\(nostrService.profiles[reposter]?.bestName ?? shortKey(reposter)) reposted")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(.green.opacity(0.7))
                .padding(.leading, 52)
            }

            // Main Note Content
            // For empty-content reposts, resolve the original author from the fetched note
            let displayPubkey: String = {
                if note.kind == 6 && note.content.isEmpty, let refId = note.repostedEventId,
                   let original = feedService.notes.first(where: { $0.id == refId }) {
                    return original.pubkey
                }
                return note.pubkey
            }()

            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 0) {
                    if let pId = note.parentEventId, feedService.findNote(id: pId) != nil {
                        Rectangle()
                            .fill(Color.havenPurple.opacity(0.3))
                            .frame(width: 2, height: 10)
                    }

                    AvatarView(url: nostrService.profiles[displayPubkey]?.pictureURL, pubkey: displayPubkey)
                        .frame(width: 40, height: 40)
                        .onTapGesture { onProfile?(displayPubkey) }

                    if isReplyToNext {
                        Rectangle()
                            .fill(Color.havenPurple.opacity(0.3))
                            .frame(width: 2)
                            .frame(maxHeight: .infinity)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(nostrService.profiles[displayPubkey]?.bestName ?? shortKey(displayPubkey))
                            .font(.system(size: 14, weight: .semibold, design: .default))
                            .foregroundColor(Color(red: 1, green: 1, blue: 1))
                            .lineLimit(1)

                        if let profile = nostrService.profiles[displayPubkey], let nip05 = profile.nip05, !nip05.isEmpty {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.caption2)
                                .foregroundColor(Color(red: 0.2, green: 0.8, blue: 0.6))
                        }

                        Spacer()

                        Text(relativeTime(note.createdAt))
                            .font(.system(size: 11, weight: .regular, design: .monospaced))
                            .foregroundColor(.secondary)
                            .tracking(0.2)
                    }
                    .padding(.top, 4)

                    // Reply indicator - subtle
                    if note.isReply {
                        HStack(spacing: 3) {
                            Image(systemName: "arrowshape.turn.up.left.fill")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(Color.havenPurple.opacity(0.6))

                            if let rPubkey = note.replyToPubkey {
                                let name = nostrService.profiles[rPubkey]?.bestName ?? shortKey(rPubkey)
                                Text("reply to \(name)")
                                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                                    .foregroundColor(.secondary.opacity(0.7))
                                    .tracking(0.1)
                                    .onAppear {
                                        if nostrService.profiles[rPubkey] == nil {
                                            nostrService.fetchMissingProfiles(for: [rPubkey])
                                        }
                                    }
                            }
                        }
                    }

                    // Content Body — for empty-content reposts, show the referenced note
                    if note.kind == 6 && note.content.isEmpty, let refId = note.repostedEventId {
                        if let original = feedService.notes.first(where: { $0.id == refId }) {
                            let formattedOriginal = NostrContentFormatter.format(original.content, mediaURLs: original.mediaURLs, hideQuotes: true)
                            VStack(alignment: .leading, spacing: 8) {
                                Text(formattedOriginal)
                                    .font(.system(size: 15, weight: .regular, design: .default))
                                    .foregroundColor(Color(red: 1, green: 1, blue: 1))
                                    .lineSpacing(2)
                                    .lineLimit(nil)
                            }
                            .padding(.top, 4)

                            if !original.mediaURLs.isEmpty {
                                feedMediaCarousel(urls: original.mediaURLs)
                                    .padding(.top, 4)
                            }
                        } else {
                            // Still loading the referenced note
                            HStack(spacing: 6) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Loading reposted note...")
                                    .font(.system(size: 13))
                                    .foregroundColor(.secondary)
                            }
                            .padding(.top, 4)
                        }
                    } else {
                        let formattedContent = NostrContentFormatter.format(note.content, mediaURLs: note.mediaURLs, hideQuotes: true)
                        VStack(alignment: .leading, spacing: 8) {
                            Text(formattedContent)
                                .font(.system(size: 15, weight: .regular, design: .default))
                                .foregroundColor(Color(red: 1, green: 1, blue: 1))
                                .lineSpacing(2)
                                .lineLimit(nil)
                        }
                        .padding(.top, 4)

                        // Media previews
                        if !note.mediaURLs.isEmpty {
                            feedMediaCarousel(urls: note.mediaURLs)
                                .padding(.top, 4)
                        }
                    }

                    // Quoted Notes
                    if !note.quotedEventIds.isEmpty {
                        VStack(spacing: 8) {
                            ForEach(note.quotedEventIds, id: \.self) { quoteId in
                                if let quotedNote = feedService.findNote(id: quoteId) {
                                    NavigationLink(value: quotedNote) {
                                        QuotedNoteView(note: quotedNote)
                                    }
                                    .buttonStyle(.plain)
                                } else {
                                    Color.clear
                                        .frame(height: 0)
                                        .onAppear {
                                            feedService.fetchMissingNote(id: quoteId)
                                        }
                                }
                            }
                        }
                        .padding(.top, 4)
                    }

                    // Actions row - minimal and clean
                    HStack(spacing: 12) {
                        actionButton(icon: "message", action: { onReply?() })

                        let isReposted = feedService.repostedEventIds.contains(note.id)
                        actionButton(
                            icon: "arrow.2.squarepath",
                            color: isReposted ? .green : .secondary,
                            action: { repostNote() }
                        )
                        .scaleEffect(isReposted ? 1.2 : 1.0)
                        .animation(.spring(response: 0.3, dampingFraction: 0.45), value: isReposted)

                        actionButton(icon: "quote.closing", action: { quoteNote() })

                        let isLiked = feedService.likedEventIds.contains(note.id)
                        actionButton(
                            icon: isLiked ? "heart.fill" : "heart",
                            color: isLiked ? .red : .secondary,
                            action: { likeNote() }
                        )
                        .scaleEffect(isLiked ? 1.2 : 1.0)
                        .animation(.spring(response: 0.3, dampingFraction: 0.45), value: isLiked)
                        .simultaneousGesture(
                            LongPressGesture(minimumDuration: 0.5)
                                .onEnded { _ in
                                    #if os(iOS)
                                    let generator = UIImpactFeedbackGenerator(style: .medium)
                                    generator.impactOccurred()
                                    #endif
                                    showingEmojiPicker = true
                                }
                        )
                        .popover(isPresented: $showingEmojiPicker) {
                            EmojiPickerView { emoji in
                                reactToNote(with: emoji)
                            }
                            #if os(iOS)
                            .presentationDetents([.height(520)])
                            #endif
                        }
                        
                        if !ConfigService.shared.config.nwcURI.isEmpty {
                            let lud16 = getLightingAddress(for: note.pubkey)
                            let zapAmount = feedService.zappedEventIds[note.id]
                            let isZapped = zapAmount != nil
                            let hasLightning = lud16 != nil
                            Button(action: {
                                if let lud16 = lud16 {
                                    Task { await zapNote(lud16: lud16) }
                                } else {
                                    noLightningAddressAlert = true
                                }
                            }) {
                                HStack(spacing: 4) {
                                    Image(systemName: isZapped ? "bolt.fill" : "bolt")
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundColor(isZapped ? .orange : (hasLightning ? .secondary : .secondary.opacity(0.35)))
                                    if let amount = zapAmount, amount > 0 {
                                        Text("\(amount)")
                                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                            .foregroundColor(.orange)
                                    }
                                }
                                .frame(height: 32)
                                .padding(.horizontal, (zapAmount ?? 0) > 0 ? 10 : 0)
                                .frame(minWidth: 32)
                                .background(isZapped ? Color.orange.opacity(0.2) : Color.secondary.opacity(0.1))
                                .clipShape(Capsule())
                                .scaleEffect(isZapped ? 1.2 : 1.0)
                                .animation(.spring(response: 0.3, dampingFraction: 0.45), value: isZapped)
                            }
                            .buttonStyle(.plain)
                            .onLongPressGesture {
                                if hasLightning {
                                    zapAmountSats = String(ConfigService.shared.config.defaultZapAmount / 1000)
                                    showAmountPicker = true
                                }
                            }
                        }

                        let onchainZapAmount = feedService.onchainZapEventIds[note.id]
                        if onchainZapAmount != nil {
                            OnchainZapDisplay(amountSats: onchainZapAmount)
                        }

                        Button {
                            showingBroadcastSheet = true
                        } label: {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.secondary)
                                .frame(width: 32, height: 32)
                                .background(Color.secondary.opacity(0.1))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)

                        Spacer()
                    }
                    .padding(.top, 4)

                    if showingPostCreatedCountdown {
                        PostCreatedCountdownBanner(timeRemaining: postCreationTimeRemaining)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                } // End of RHS VStack (name, time, content, actions)
            } // End of Main Note Content HStack
        } // End of Outer VStack (root row)
        .foregroundColor(Color(red: 1, green: 1, blue: 1))
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
                .stroke(Color.havenPurple.opacity(note.isReply ? 0.25 : 0.12), lineWidth: note.isReply ? 1.2 : 0.8)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12))
        #if os(iOS)
        .hoverEffect(.lift)
        #endif
        .clipped()
        .overlay {
            LightningAnimationView(isAnimating: $showLightning)
                .allowsHitTesting(false)
        }
        .alert("Zap Amount", isPresented: $showAmountPicker) {
            TextField("Amount in sats", text: $zapAmountSats)
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
            Button("Zap!") {
                if let amount = Int(zapAmountSats) {
                    if let lud16 = getLightingAddress(for: note.pubkey) {
                        Task { await zapNote(lud16: lud16, amount: amount) }
                    }
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Enter the amount of sats you want to zap.")
        }
        .environment(\.openURL, OpenURLAction { url in
            if url.scheme == "nostr" {
                let identifier = url.absoluteString.replacingOccurrences(of: "nostr:", with: "")
                if identifier.hasPrefix("npub1") || identifier.hasPrefix("nprofile1") {
                    if let decoded = Bech32.decode(identifier) {
                        onProfile?(decoded.hexString)
                    } else {
                        onProfile?(identifier)
                    }
                    return .handled
                }
                // Future: handle note1/nevent1 navigation here too
            }
            return .systemAction
        })
        .overlay(alignment: .bottom) {
            if showingRepostUndo {
                RepostUndoBanner(timeRemaining: timeRemaining, onUndo: undoRepost)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.bottom, 8)
                    .padding(.horizontal, 12)
            }
        }
        .sheet(isPresented: $showingBroadcastSheet) {
            EventBroadcastSheet(note: note)
                .environmentObject(nostrService)
                .environmentObject(configService)
        }
        .alert("No Lightning Address", isPresented: $noLightningAddressAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("This user hasn't configured a lightning address, so they can't receive zaps.")
        }
        .contextMenu {
            if note.pubkey == nostrService.activeHexPubkey {
                Button(role: .destructive) {
                    showingDeleteConfirm = true
                } label: {
                    Label("Delete Post", systemImage: "trash")
                }
            }
        }
        .alert("Delete Post", isPresented: $showingDeleteConfirm) {
            Button("Delete", role: .destructive) {
                nostrService.deleteNote(id: note.id)
                feedService.removeNote(id: note.id)
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Request deletion of this post? Not all relays honor NIP-09 deletion requests.")
        }
        .onAppear {
            let ageInSeconds = Date().timeIntervalSince(note.createdAt)
            if ageInSeconds < 0.5 && note.pubkey == nostrService.activeHexPubkey {
                showingPostCreatedCountdown = true
                postCreationTimeRemaining = 10.0
                postCreationCountdownTask?.cancel()

                postCreationCountdownTask = Task {
                    for _ in 0..<100 {
                        try? await Task.sleep(nanoseconds: 100_000_000)
                        if Task.isCancelled { return }
                        await MainActor.run {
                            postCreationTimeRemaining -= 0.1
                        }
                    }

                    if !Task.isCancelled {
                        await MainActor.run {
                            withAnimation {
                                showingPostCreatedCountdown = false
                            }
                        }
                    }
                }
            }
        }
        .onDisappear {
            postCreationCountdownTask?.cancel()
        }
    }

    private func actionButton(icon: String, color: Color = .secondary, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(color)
            .frame(width: 32, height: 32)
            .background(color.opacity(color == .secondary ? 0.1 : 0.15))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .contentShape(Capsule())
        #if os(macOS)
        .onHover { inside in
            // Handle hover state if needed, though .hoverEffect handles it on iOS
        }
        #endif
    }

    // MARK: - Media Grid Helper

    /// Renders media URLs using FeedMediaView in a swipeable carousel.
    @ViewBuilder
    private func feedMediaCarousel(urls: [URL]) -> some View {
        if urls.isEmpty {
            EmptyView()
        } else if urls.count == 1 {
            // Single media — full width, proper aspect ratio
            FeedMediaView(
                url: urls[0],
                onTap: { onMedia?(urls[0]) },
                maxHeight: 400,
                isThumbnail: false
            )
            .frame(maxWidth: .infinity)
        } else {
            // Multiple media — swipeable carousel
            TabView {
                ForEach(urls, id: \.absoluteString) { url in
                    FeedMediaView(
                        url: url,
                        onTap: { onMedia?(url) },
                        maxHeight: 400,
                        isThumbnail: false
                    )
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            .mediaTabViewStyleCompat()
            .frame(height: 400)
            // Add a subtle border or background if desired to distinguish bounds
            // But FeedMediaView already has clipShape and overlay
        }
    }

    private func likeNote() {
        let noteId = note.id
        if feedService.likedEventIds.contains(noteId) {
            UnlikeNotificationManager.shared.startCountdown {
                self.feedService.likedEventIds.remove(noteId)
                var stats = self.feedService.noteStats[noteId] ?? NoteStats(replies: 0, reactions: 0, reposts: 0)
                stats.reactions = max(0, stats.reactions - 1)
                self.feedService.noteStats[noteId] = stats
                self.feedService.saveInteractionState()
            }
            return
        }
        feedService.likedEventIds.insert(noteId)
        var currentStats = feedService.noteStats[noteId] ?? NoteStats(replies: 0, reactions: 0, reposts: 0)
        currentStats.reactions += 1
        feedService.noteStats[noteId] = currentStats
        feedService.saveInteractionState()
        guard let signed = nostrService.signEvent(kind: 7, content: "+", tags: [["e", noteId, "", "root"], ["p", note.pubkey]]) else { return }
        nostrService.postEvent(signed)
    }
    
    private func reactToNote(with emoji: String) {
        if !feedService.likedEventIds.contains(note.id) {
            feedService.likedEventIds.insert(note.id)
            
            // Proactively update stats locally
            var currentStats = feedService.noteStats[note.id] ?? NoteStats(replies: 0, reactions: 0, reposts: 0)
            currentStats.reactions += 1
            feedService.noteStats[note.id] = currentStats
            
            feedService.saveInteractionState()
        }
        guard let signed = nostrService.signEvent(kind: 7, content: emoji, tags: [["e", note.id, "", "root"], ["p", note.pubkey]]) else { return }
        nostrService.postEvent(signed)
    }

    private func repostNote() {
        showingRepostUndo = true
        timeRemaining = 5.0
        repostTask?.cancel()

        repostTask = Task {
            for _ in 0..<50 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                if Task.isCancelled { return }
                await MainActor.run {
                    timeRemaining -= 0.1
                }
            }

            if Task.isCancelled { return }

            guard let signed = nostrService.signEvent(kind: 6, content: "", tags: [["e", note.id, "", "root"], ["p", note.pubkey]]) else { return }
            nostrService.postEvent(signed)
            feedService.repostedEventIds.insert(note.id)

            await MainActor.run {
                withAnimation {
                    showingRepostUndo = false
                }
            }
        }
    }
    
    private func undoRepost() {
        repostTask?.cancel()
        repostTask = nil
        withAnimation {
            showingRepostUndo = false
        }
    }

    private func quoteNote() {
        onQuote?()
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
                amountSats: amount
            )
            await MainActor.run {
                feedService.zappedEventIds[note.id] = amountSats
                feedService.saveInteractionState()
                showLightning = true
            }
        } catch {
            #if DEBUG
            print("FeedView: Zap failed: \(error)")
            #endif
        }
    }

    private func shortKey(_ key: String) -> String {
        guard key.count >= 12 else { return key }
        return "npub…" + String(key.suffix(6))
    }

    private func formattedContent(_ content: String) -> AttributedString {
        // Strip bare image/video URLs from text (they'll show as thumbnails)
        var text = content
        for url in note.mediaURLs {
            text = text.replacingOccurrences(of: url.absoluteString, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        let npubRegex = try! NSRegularExpression(pattern: "nostr:(npub1[a-z0-9]+)")
        text = npubRegex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "[@user](nostr:$1)")
        
        let nprofileRegex = try! NSRegularExpression(pattern: "nostr:(nprofile1[a-z0-9]+)")
        text = nprofileRegex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "[@user](nostr:$1)")

        let neventRegex = try! NSRegularExpression(pattern: "nostr:(nevent1[a-z0-9]+)")
        text = neventRegex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "[Quote](nostr:$1)")

        let noteRegex = try! NSRegularExpression(pattern: "nostr:(note1[a-z0-9]+)")
        text = noteRegex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "[Quote](nostr:$1)")

        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        
        do {
            var attrString = try AttributedString(markdown: text, options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace))
            attrString.foregroundColor = .primary
            return attrString
        } catch {
            return AttributedString(text)
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
}

// FeedMediaThumbnail has been replaced by FeedMediaView (see Components/FeedMediaView.swift)

// MARK: - AvatarView

private final class AvatarImageCache {
    static let shared = AvatarImageCache()
    private var cache = NSCache<NSURL, PlatformImage>()

    init() {
        cache.countLimit = 200
    }

    func image(for url: URL) -> PlatformImage? {
        cache.object(forKey: url as NSURL)
    }

    func store(_ image: PlatformImage, for url: URL) {
        cache.setObject(image, forKey: url as NSURL)
    }
}

struct AvatarView: View {
    let url: URL?
    let pubkey: String
    var size: CGFloat = 40
    @State private var image: PlatformImage?

    var body: some View {
        ZStack {
            Circle()
                .fill(avatarGradient)
                .frame(width: size, height: size)

            if let image = image {
                Image(platformImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } else {
                Text(String(pubkey.prefix(1)).uppercased())
                    .font(.system(size: max(8, size * 0.325), weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
            }

            Circle()
                .stroke(Color.platformSeparator, lineWidth: 0.5)
                .frame(width: size, height: size)
        }
        .frame(width: size, height: size)
        .onAppear { loadImage() }
        .onChange(of: url) { _, _ in
            image = nil
            loadImage()
        }
        .onChange(of: pubkey) { _, _ in
            image = nil
            loadImage()
        }
    }

    private var avatarGradient: LinearGradient {
        let first = pubkey.unicodeScalars.first?.value ?? 200
        let hue = Double(first % 360) / 360.0
        let saturation = 0.6 + Double((first / 10) % 30) / 100.0

        return LinearGradient(
            colors: [
                Color(hue: hue, saturation: saturation, brightness: 0.75),
                Color(hue: (hue + 0.15).truncatingRemainder(dividingBy: 1), saturation: saturation, brightness: 0.55)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private func loadImage() {
        guard let url = url else { return }

        // Check in-memory cache first
        if let cached = AvatarImageCache.shared.image(for: url) {
            if image == nil { image = cached }
            return
        }

        guard image == nil else { return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            if let data = data, let img = PlatformImage(data: data) {
                AvatarImageCache.shared.store(img, for: url)
                DispatchQueue.main.async { image = img }
            }
        }.resume()
    }
}

// MARK: - Skeleton Loading Row

struct FeedNoteSkeletonRow: View {
    @State private var shimmer = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Circle()
                    .fill(Color.platformTertiaryGroupedBackground)
                    .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 4) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.platformTertiaryGroupedBackground)
                        .frame(width: 100, height: 12)

                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.platformTertiaryGroupedBackground)
                        .frame(width: 60, height: 10)
                }

                Spacer()
            }

            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.platformTertiaryGroupedBackground)
                    .frame(maxWidth: .infinity)
                    .frame(height: 12)

                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.platformTertiaryGroupedBackground)
                    .frame(maxWidth: .infinity)
                    .frame(height: 12)

                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.platformTertiaryGroupedBackground)
                    .frame(width: 180, height: 12)
            }

            HStack(spacing: 12) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle()
                        .fill(Color.platformTertiaryGroupedBackground)
                        .frame(width: 28, height: 28)
                }
                Spacer()
            }
        }
        .padding(14)
        .background(Color.platformSecondaryGroupedBackground)
        .cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.platformSeparator, lineWidth: 0.8))
        .opacity(shimmer ? 0.5 : 1.0)
        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: shimmer)
        .onAppear { shimmer = true }
    }
}

// MARK: - Relay Status Sheet

struct RelayStatusSheet: View {
    @Environment(\.dismiss) var dismiss
    var onDismiss: (() -> Void)? = nil
    @EnvironmentObject var relayManager: RelayProcessManager
    @EnvironmentObject var configService: ConfigService
    @EnvironmentObject var nostrService: NostrService
    @ObservedObject private var mirrorService = MirrorService.shared

    var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            HStack {
                Text("Relay Status")
                    .font(.headline)
                Spacer()
                Button(action: { performDismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()
            #endif

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Main Relay Status
                    Section {
                        VStack(spacing: 12) {
                            HStack(spacing: 12) {
                                Circle()
                                    .fill(relayManager.isRunning ? Color.green : Color.orange)
                                    .frame(width: 12, height: 12)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Nostr Vault Relay")
                                        .font(.system(size: 16, weight: .bold))
                                    Text(relayManager.isBooting ? "Booting..." : (relayManager.isRunning ? "Connected" : "Disconnected"))
                                        .font(.system(size: 13, design: .monospaced))
                                        .foregroundColor(.secondary)
                                }

                                Spacer()

                                Text(verbatim: "127.0.0.1:\(configService.config.relayPort)")
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                            .padding(12)
                            .background(Color.platformTertiaryGroupedBackground)
                            .cornerRadius(10)
                        }
                    } header: {
                        Text("Write Relay")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundColor(.secondary.opacity(0.7))
                            .tracking(0.5)
                    }
                    .padding(.horizontal)

                    Divider()
                        .padding(.vertical, 8)

                    // Mac Relay Sync
                    Section {
                        VStack(alignment: .leading, spacing: 12) {
                            let macURL = configService.config.macRelayURL
                            if macURL.isEmpty {
                                Text("No Mac relay configured in settings")
                                    .font(.system(size: 13, design: .monospaced))
                                    .foregroundColor(.secondary)
                            } else {
                                HStack(spacing: 8) {
                                    Circle()
                                        .fill(MacRelaySyncService.shared.isSyncing ? Color.havenPurple : (MacRelaySyncService.shared.lastSyncDate != nil ? Color.green : Color.secondary))
                                        .frame(width: 8, height: 8)
                                    Text(MacRelaySyncService.shared.isSyncing ? "Syncing..." : (MacRelaySyncService.shared.syncStatus.isEmpty ? "Idle" : MacRelaySyncService.shared.syncStatus))
                                        .font(.system(size: 13, design: .monospaced))
                                        .foregroundColor(MacRelaySyncService.shared.isSyncing ? .havenPurple : .secondary)
                                }
                                
                                if let lastSync = MacRelaySyncService.shared.lastSyncDate {
                                    Text("Last successful sync: \(lastSync.formatted())")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(.secondary.opacity(0.7))
                                }
                                
                                HStack(spacing: 12) {
                                    Button {
                                        MacRelaySyncService.shared.forceSync()
                                    } label: {
                                        HStack(spacing: 6) {
                                            if MacRelaySyncService.shared.isSyncing {
                                                ProgressView().controlSize(.small).tint(.black)
                                            } else {
                                                Image(systemName: "arrow.clockwise")
                                            }
                                            Text("Sync Now")
                                        }
                                        .font(.system(size: 12, weight: .bold))
                                        .padding(.vertical, 8)
                                        .padding(.horizontal, 16)
                                        .background(Color.havenPurple)
                                        .foregroundColor(.white)
                                        .cornerRadius(8)
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(MacRelaySyncService.shared.isSyncing)
                                    
                                    Button {
                                        MacRelaySyncService.shared.resetSync()
                                    } label: {
                                        Text("Reset Progress")
                                            .font(.system(size: 12, weight: .medium))
                                            .padding(.vertical, 8)
                                            .padding(.horizontal, 16)
                                            .background(Color.secondary.opacity(0.1))
                                            .foregroundColor(.secondary)
                                            .cornerRadius(8)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.top, 4)
                            }
                        }
                        .padding(12)
                        .background(Color.platformTertiaryGroupedBackground)
                        .cornerRadius(10)
                    } header: {
                        Text("Mac Relay Sync")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundColor(.secondary.opacity(0.7))
                            .tracking(0.5)
                    }
                    .padding(.horizontal)

                    #if os(iOS)
                    Divider()
                        .padding(.vertical, 8)

                    // Media Mirroring
                    Section {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(mirrorService.state == .mirroring ? Color.havenPurple :
                                          (mirrorService.state == .complete ? Color.green : Color.secondary))
                                    .frame(width: 8, height: 8)
                                Text(mirrorService.state == .mirroring ? "Mirroring..." :
                                     (mirrorService.state == .complete ? "Complete" : "Idle"))
                                    .font(.system(size: 13, design: .monospaced))
                                    .foregroundColor(mirrorService.state == .mirroring ? .havenPurple : .secondary)
                            }

                            if !mirrorService.statusText.isEmpty {
                                Text(mirrorService.statusText)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.havenPurple.opacity(0.8))
                            }

                            if let progress = mirrorService.progress {
                                ProgressView(value: Double(progress.completed), total: Double(max(progress.total, 1)))
                                    .tint(.havenPurple)
                            }

                            if !mirrorService.lastResult.isEmpty {
                                Text(mirrorService.lastResult)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.secondary.opacity(0.7))
                            }

                            if let lastMirror = mirrorService.lastMirrorDate {
                                Text("Last mirror: \(lastMirror.formatted())")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.secondary.opacity(0.7))
                            }

                            Button {
                                mirrorService.runMirror(
                                    configService: configService,
                                    nostrService: nostrService
                                )
                            } label: {
                                HStack(spacing: 6) {
                                    if mirrorService.state == .mirroring {
                                        ProgressView().controlSize(.small).tint(.black)
                                    } else {
                                        Image(systemName: "arrow.triangle.2.circlepath")
                                    }
                                    Text("Mirror Now")
                                }
                                .font(.system(size: 12, weight: .bold))
                                .padding(.vertical, 8)
                                .padding(.horizontal, 16)
                                .background(Color.havenPurple)
                                .foregroundColor(.white)
                                .cornerRadius(8)
                            }
                            .buttonStyle(.plain)
                            .disabled(mirrorService.state == .mirroring || configService.config.blossomMirrors.isEmpty)
                            .padding(.top, 4)
                        }
                        .padding(12)
                        .background(Color.platformTertiaryGroupedBackground)
                        .cornerRadius(10)
                    } header: {
                        Text("Media Mirroring")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundColor(.secondary.opacity(0.7))
                            .tracking(0.5)
                    }
                    .padding(.horizontal)
                    #endif

                    Divider()
                        .padding(.vertical, 8)

                    // Feed Relays
                    Section {
                        VStack(spacing: 8) {
                            Text("Configured to read from \(configService.config.feedRelays.count) external relays")
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundColor(.secondary)

                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(configService.config.feedRelays.prefix(5), id: \.self) { relay in
                                    HStack(spacing: 8) {
                                        Circle()
                                            .fill(Color.havenPurple.opacity(0.3))
                                            .frame(width: 4, height: 4)

                                        Text(relay)
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundColor(.secondary.opacity(0.8))
                                            .lineLimit(1)
                                    }
                                }

                                if configService.config.feedRelays.count > 5 {
                                    Text("+ \(configService.config.feedRelays.count - 5) more")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(.secondary.opacity(0.6))
                                        .padding(.top, 4)
                                }
                            }
                        }
                        .padding(12)
                        .background(Color(red: 0.12, green: 0.12, blue: 0.16))
                        .cornerRadius(10)
                    } header: {
                        Text("Feed Reading Relays")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundColor(.secondary.opacity(0.7))
                            .tracking(0.5)
                    }
                    .padding(.horizontal)

                }
                .padding(.vertical)
            }

            #if os(iOS)
            Divider()
            Button {
                performDismiss()
            } label: {
                Text("Done")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.havenPurple)
                    .cornerRadius(10)
            }
            .padding()
            #endif
        }
        #if os(iOS)
        .navigationTitle("Relay Status")
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .background(Color.platformControlBackground)
        .frame(minWidth: 400, minHeight: 500)
    }

    private func performDismiss() {
        if let onDismiss = onDismiss {
            onDismiss()
        } else {
            dismiss()
        }
    }
}

// MARK: - RepostUndoBanner

struct RepostUndoBanner: View {
    var timeRemaining: Double
    var totalTime: Double = 10.0
    var onUndo: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.2.squarepath")
                .foregroundColor(.white)
            
            VStack(alignment: .leading, spacing: 4) {
                Text("Reposting in \(Int(ceil(timeRemaining)))s")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.3))
                        Capsule()
                            .fill(Color.white)
                            .frame(width: max(0, geo.size.width * (timeRemaining / totalTime)))
                    }
                }
                .frame(height: 4)
            }
            
            Spacer()
            
            Button("Undo") {
                onUndo()
            }
            .font(.system(size: 13, weight: .bold))
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.2))
            .cornerRadius(6)
        }
        .padding(12)
        .background(Color.havenPurple)
        .cornerRadius(8)
        .shadow(color: .black.opacity(0.2), radius: 5, y: 3)
    }
}

struct PostCreatedCountdownBanner: View {
    var timeRemaining: Double
    var totalTime: Double = 10.0

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.white)

            VStack(alignment: .leading, spacing: 4) {
                Text("Post created - editing in \(Int(ceil(timeRemaining)))s")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.3))
                        Capsule()
                            .fill(Color.white)
                            .frame(width: max(0, geo.size.width * (timeRemaining / totalTime)))
                    }
                }
                .frame(height: 4)
            }

            Spacer()
        }
        .padding(12)
        .background(Color.green.opacity(0.85))
        .cornerRadius(8)
        .shadow(color: .black.opacity(0.2), radius: 5, y: 3)
    }
}
