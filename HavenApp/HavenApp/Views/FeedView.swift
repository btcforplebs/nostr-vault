import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct IdentifiableString: Identifiable {
    let id: String
}

// MARK: - FeedView

struct FeedView: View {
    @StateObject private var feedService = FeedService.shared
    @EnvironmentObject var relayManager: RelayProcessManager
    @EnvironmentObject var configService: ConfigService
    @EnvironmentObject var nostrService: NostrService
    @State private var showingCompose = false
    @State private var replyToNote: FeedNote?
    @State private var showingRelayStatus = false
    @State private var showingNoteId: String?

    var body: some View {
        #if os(iOS)
        NavigationView {
            rootContent
                .navigationTitle("Feed")
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(Color.platformControlBackground, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
        }
        .navigationViewStyle(.stack)
        #else
        rootContent
        #endif
    }

    @ViewBuilder
    private var rootContent: some View {
        ZStack {
            // Match the platform theme background
            Color(red: 0.08, green: 0.08, blue: 0.1).ignoresSafeArea()

            Group {
                if feedService.isLoadingContacts {
                    loadingContactsView
                } else if feedService.followedPubkeys.isEmpty && !feedService.isLoadingFeed {
                    emptyStateView
                } else {
                    feedList
                }
            }
        }
        #if os(iOS)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button(action: { showingRelayStatus = true }) {
                    Circle()
                        .fill(feedService.connectionStatus == "Live" ? Color(red: 0.2, green: 0.8, blue: 0.6) : Color(red: 1, green: 0.6, blue: 0.1))
                        .frame(width: 10, height: 10)
                        .shadow(color: feedService.connectionStatus == "Live" ? Color(red: 0.2, green: 0.8, blue: 0.6).opacity(0.6) : Color(red: 1, green: 0.6, blue: 0.1).opacity(0.4), radius: 3)
                        .padding(8)
                        .contentShape(Rectangle())
                }
            }

            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: { configService.config.showReplies.toggle(); configService.save() }) {
                    Image(systemName: configService.config.showReplies ? "message.fill" : "message")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(configService.config.showReplies ? Color.havenPurple : .secondary)
                }
            }
        }
        #endif
        .preferredColorScheme(.dark)
        .onAppear {
            feedService.markViewed()
            if feedService.notes.isEmpty && !feedService.isLoadingContacts {
                if relayManager.isRunning && !relayManager.isBooting {
                    feedService.refresh()
                }
            }
        }
        .onChange(of: relayManager.isRunning) { _, running in
            if running && !relayManager.isBooting && feedService.notes.isEmpty && !feedService.isLoadingContacts {
                feedService.refresh()
            }
        }
        .sheet(isPresented: $showingCompose) {
            ComposeView(replyTo: replyToNote)
                .environmentObject(nostrService)
                .environmentObject(configService)
        }
        .sheet(isPresented: $showingRelayStatus) {
            RelayStatusSheet()
                .environmentObject(relayManager)
                .environmentObject(configService)
                .environmentObject(nostrService)
        }
        .sheet(item: Binding<IdentifiableString?>(
            get: { showingNoteId.map { IdentifiableString(id: $0) } },
            set: { showingNoteId = $0?.id }
        )) { noteId in
            NoteDetailViewWrapper(noteId: noteId.id)
                .environmentObject(nostrService)
                .environmentObject(configService)
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

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 40) {
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

                    Text("Start by following npubs on Nostr")
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
                            let isBlacklisted = configService.blacklistedHexPubkeys.contains(note.pubkey)
                            return !isBlacklisted && (configService.config.showReplies || !note.isReply)
                        }

                        ForEach(Array(filteredNotes.enumerated()), id: \.element.id) { index, note in
                            let profile = nostrService.profiles[note.pubkey]

                            // Optimization: If the parent is the very next note in the feed,
                            // don't show the redundant parent header.
                            let parentIsNext = index + 1 < filteredNotes.count &&
                                             filteredNotes[index+1].id == note.parentEventId

                            #if os(iOS)
                            NavigationLink(destination: NoteDetailView(note: note)) {
                                FeedNoteRow(
                                    note: note,
                                    profile: profile,
                                    onReply: {
                                        replyToNote = note
                                        showingCompose = true
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
                                    replyToNote = note
                                    showingCompose = true
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
                    feedService.refresh()
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
                replyToNote = nil
                showingCompose = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.black)
                    .frame(width: 56, height: 56)
                    .background(
                        Circle()
                            .fill(
                                LinearGradient(
                                    gradient: Gradient(colors: [Color.havenPurple, Color.havenPurpleLight]),
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .shadow(color: Color.havenPurple.opacity(0.4), radius: 8, x: 0, y: 4)
                    )
            }
            .padding(24)
            .padding(.bottom, 8) // Adjust for tab bar if present
            #endif
        }
    }
}

// MARK: - FeedNoteRow

struct FeedNoteRow: View {
    let note: FeedNote
    let profile: FeedProfile?
    var onReply: (() -> Void)? = nil
    var showParent: Bool = true
    var isReplyToNext: Bool = false

    @StateObject private var feedService = FeedService.shared
    @EnvironmentObject var nostrService: NostrService
    @EnvironmentObject var configService: ConfigService

    @State private var showingProfileKey: IdentifiableString?
    @State private var showingMediaUrl: IdentifiableURL?
    @State private var showingReportDialog = false
    @State private var showLightning = false
    @State private var showAmountPicker = false
    @State private var zapAmountSats: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Threading View: Parent Note Preview (shows above the current note)
            if showParent, let pId = note.parentEventId {
                if let parent = feedService.notes.first(where: { $0.id == pId }) {
                    NavigationLink(destination: NoteDetailView(note: parent)) {
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(alignment: .top, spacing: 12) {
                                VStack(spacing: 0) {
                                    let parentProfile = nostrService.profiles[parent.pubkey]
                                    AvatarView(url: parentProfile?.pictureURL, pubkey: parent.pubkey)
                                        .frame(width: 28, height: 28)
                                        .opacity(1.0)
                                    
                                    Rectangle()
                                        .fill(Color.havenPurple.opacity(0.3))
                                        .frame(width: 2)
                                        .frame(minHeight: 12)
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
                } else {
                    // Request parent if missing
                    Color.clear
                        .frame(height: 0)
                        .onAppear {
                            feedService.fetchMissingNote(id: pId)
                        }
                }
            }

            // Main Note Content
            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 0) {
                    if let pId = note.parentEventId, feedService.notes.contains(where: { $0.id == pId }) {
                        Rectangle()
                            .fill(Color.havenPurple.opacity(0.3))
                            .frame(width: 2, height: 10)
                    }

                    AvatarView(url: nostrService.profiles[note.pubkey]?.pictureURL, pubkey: note.pubkey)
                        .frame(width: 40, height: 40)
                    
                    if isReplyToNext {
                        Rectangle()
                            .fill(Color.havenPurple.opacity(0.3))
                            .frame(width: 2)
                            .frame(maxHeight: .infinity)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(nostrService.profiles[note.pubkey]?.bestName ?? shortKey(note.pubkey))
                            .font(.system(size: 14, weight: .semibold, design: .default))
                            .foregroundColor(Color(red: 1, green: 1, blue: 1))
                            .lineLimit(1)
                        
                        if let profile = nostrService.profiles[note.pubkey], let nip05 = profile.nip05, !nip05.isEmpty {
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
                                Text("reply to \(shortKey(rPubkey))")
                                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                                    .foregroundColor(.secondary.opacity(0.7))
                                    .tracking(0.1)
                            }
                        }
                    }

                    // Content Body
                    VStack(alignment: .leading, spacing: 8) {
                        Text(NostrContentFormatter.format(note.content, mediaURLs: note.mediaURLs, hideQuotes: true))
                            .font(.system(size: 15, weight: .regular, design: .default))
                            .foregroundColor(Color(red: 1, green: 1, blue: 1))
                            .lineSpacing(2)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 4)

                    // Media previews
                    if !note.mediaURLs.isEmpty {
                        let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: min(note.mediaURLs.count, 3))
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                            ForEach(note.mediaURLs.prefix(3), id: \.absoluteString) { url in
                                Button(action: {
                                    showingMediaUrl = IdentifiableURL(url: url)
                                }) {
                                    FeedMediaThumbnail(url: url)
                                        .aspectRatio(1, contentMode: .fill)
                                        .frame(maxWidth: .infinity)
                                        .cornerRadius(8)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.top, 4)
                    }

                    // Quoted Notes
                    if !note.quotedEventIds.isEmpty {
                        VStack(spacing: 8) {
                            ForEach(note.quotedEventIds, id: \.self) { quoteId in
                                if let quotedNote = feedService.notes.first(where: { $0.id == quoteId }) {
                                    NavigationLink(destination: NoteDetailView(note: quotedNote)) {
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
                        actionButton(icon: "arrow.2.squarepath", action: { repostNote() })
                        actionButton(icon: "quote.closing", action: { quoteNote() })
                        
                        let isLiked = feedService.likedEventIds.contains(note.id)
                        actionButton(
                            icon: isLiked ? "heart.fill" : "heart",
                            color: isLiked ? .red : .secondary,
                            action: { likeNote() }
                        )
                        .scaleEffect(isLiked ? 1.2 : 1.0)
                        .animation(.spring(response: 0.3, dampingFraction: 0.45), value: isLiked)
                        
                        if !ConfigService.shared.config.nwcURI.isEmpty, let lud16 = getLightingAddress(for: note.pubkey) {
                            let isZapped = feedService.zappedEventIds.contains(note.id)
                            Button(action: {
                                Task { await zapNote(lud16: lud16) }
                            }) {
                                ZStack {
                                    Image(systemName: isZapped ? "bolt.fill" : "bolt")
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundColor(isZapped ? .orange : .secondary)
                                        .frame(width: 32, height: 32)
                                        .background(isZapped ? Color.orange.opacity(0.2) : Color.secondary.opacity(0.1))
                                        .clipShape(Circle())
                                }
                                .scaleEffect(isZapped ? 1.2 : 1.0)
                                .animation(.spring(response: 0.3, dampingFraction: 0.45), value: isZapped)
                            }
                            .buttonStyle(.plain)
                            .onLongPressGesture {
                                zapAmountSats = String(ConfigService.shared.config.defaultZapAmount / 1000)
                                showAmountPicker = true
                            }
                        }
                        
                        ShareLink(
                            item: URL(string: "https://mynostrspace.com/thread/\(note.nevent)")!,
                            subject: Text("Nostr Note"),
                            message: Text("Check out this note on Nostr")
                        ) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.secondary)
                                .frame(width: 32, height: 32)
                                .background(Color.secondary.opacity(0.1))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        
                        Spacer()
                    }
                    .padding(.top, 4)
                } // End of RHS VStack (name, time, content, actions)
            } // End of Main Note Content HStack
        } // End of Outer VStack (root row)
        .foregroundColor(Color(red: 1, green: 1, blue: 1))
        .padding(14)
        .background(Color.platformSecondaryGroupedBackground)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.platformSeparator, lineWidth: note.isReply ? 1.2 : 0.8)
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
                        showingProfileKey = IdentifiableString(id: decoded.hexString)
                    } else {
                        // Fallback: show profile view with string if we can't decode (unlikely)
                        showingProfileKey = IdentifiableString(id: identifier)
                    }
                    return .handled
                }
                // Future: handle note1/nevent1 navigation here too
            }
            return .systemAction
        })
        .sheet(item: Binding<IdentifiableString?>(get: { showingProfileKey }, set: { showingProfileKey = $0 })) { p in
            ProfileView(pubkey: p.id)
        }
        .sheet(item: $showingMediaUrl) { media in
            FeedMediaViewer(url: media.url)
        }
        .contextMenu {
            Button(action: {
                showingReportDialog = true
            }) {
                Label("Report Post", systemImage: "flag.fill")
            }
            
            Divider()
            
            Button(action: {
                blockUser(hexPubkey: note.pubkey)
            }) {
                Label("Block User", systemImage: "hand.raised.fill")
            }
        }
        .sheet(isPresented: $showingReportDialog) {
            UGCReportingDialog(eventId: note.id, pubkey: note.pubkey) {
                // Background refresh/filtering will handle hiding it
                nostrService.objectWillChange.send()
            }
            .environmentObject(nostrService)
            .environmentObject(configService)
        }
    }

    private func blockUser(hexPubkey: String) {
        guard let data = Bech32.hexToData(hexPubkey),
              let npub = Bech32.encode(hrp: "npub", data: data) else { return }
        if !configService.config.blacklistedNpubs.contains(npub) {
            configService.config.blacklistedNpubs.append(npub)
            configService.save()
        }
    }

    private func actionButton(icon: String, color: Color = .secondary, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(color)
                .frame(width: 32, height: 32)
                .background(color.opacity(color == .secondary ? 0.1 : 0.15))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
        #if os(macOS)
        .onHover { inside in
            // Handle hover state if needed, though .hoverEffect handles it on iOS
        }
        #endif
    }

    private func likeNote() {
        if !feedService.likedEventIds.contains(note.id) {
            feedService.likedEventIds.insert(note.id)
        }
        guard let signed = nostrService.signEvent(kind: 7, content: "+", tags: [["e", note.id, "", "root"], ["p", note.pubkey]]) else { return }
        nostrService.postEvent(signed)
    }

    private func repostNote() {
        guard let signed = nostrService.signEvent(kind: 6, content: "", tags: [["e", note.id, "", "root"], ["p", note.pubkey]]) else { return }
        nostrService.postEvent(signed)
    }

    private func quoteNote() {
        // Future: implement quote content properly in ComposeView
        onReply?()
    }
    
    private func getLightingAddress(for pubkey: String) -> String? {
        if let profile = nostrService.profiles[pubkey] {
            if let lud16 = profile.lud16, !lud16.isEmpty { return lud16 }
            if let nip05 = profile.nip05, !nip05.isEmpty { return nip05 } // Many users use nip05 as lud16
        }
        return nil
    }
    
    private func zapNote(lud16: String, amount: Int? = nil) async {
        do {
            try await ZapService.shared.zapNote(
                noteId: note.id,
                notePubkey: note.pubkey,
                lud16: lud16,
                amountSats: amount
            )
            // Trigger animation and update state on success
            await MainActor.run {
                feedService.zappedEventIds.insert(note.id)
                showLightning = true
            }
            #if os(iOS)
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.success)
            #endif
        } catch {
            RelayProcessManager.shared.addLog("Zap: Failed to zap note: \(error.localizedDescription)", level: "ERROR")
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

// MARK: - FeedMediaThumbnail

struct FeedMediaThumbnail: View {
    let url: URL
    @State private var image: PlatformImage?
    @State private var isVideo = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.platformTertiaryGroupedBackground)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.platformSeparator, lineWidth: 0.5))

                if let image = image {
                    Image(platformImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                if isVideo {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 24))
                        .foregroundColor(.white.opacity(0.95))
                        .shadow(color: .black.opacity(0.5), radius: 4)
                }
            }
        }
        .onAppear { loadThumbnail() }
    }

    private func loadThumbnail() {
        let ext = url.pathExtension.lowercased()
        isVideo = ["mp4", "mov", "webm", "m4v"].contains(ext)
        guard image == nil else { return }

        Task {
            if isVideo {
                if let thumb = await MediaCacheService.shared.generateThumbnail(for: url) {
                    await MainActor.run { self.image = thumb }
                }
            } else {
                if let data = await MediaCacheService.shared.fetchData(url: url),
                   let img = PlatformImage(data: data) {
                    await MainActor.run { self.image = img }
                }
            }
        }
    }
}

// MARK: - AvatarView

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
        .onChange(of: url) { _, _ in loadImage() }
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
        guard let url = url, image == nil else { return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            if let data = data, let img = PlatformImage(data: data) {
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
                Button(action: { dismiss() }) {
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
                                    Text("Haven Relay")
                                        .font(.system(size: 16, weight: .bold))
                                    Text(relayManager.isBooting ? "Booting..." : (relayManager.isRunning ? "Connected" : "Disconnected"))
                                        .font(.system(size: 13, design: .monospaced))
                                        .foregroundColor(.secondary)
                                }

                                Spacer()

                                Text("127.0.0.1:\(configService.config.relayPort)")
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

                            if let progress = mirrorService.progress {
                                Text("\(progress.completed)/\(progress.total) files")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.secondary.opacity(0.7))
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
                dismiss()
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
}
