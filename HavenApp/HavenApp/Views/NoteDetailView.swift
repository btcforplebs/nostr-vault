import SwiftUI
import Combine

private struct ComposeContext: Identifiable {
    let id = UUID()
    let replyTo: FeedNote?
    let quoteTo: FeedNote?
}

struct NoteDetailView: View {
    let note: FeedNote
    @StateObject private var feedService = FeedService.shared
    @EnvironmentObject var nostrService: NostrService
    @EnvironmentObject var configService: ConfigService
    @Environment(\.presentationMode) var presentationMode
    
    @State private var composeContext: ComposeContext?
    @State private var isLoadingReplies = false
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
    @State private var showAmountPicker = false
    @State private var zapAmountSats: String = ""
    @State private var showingBroadcastSheet = false
    @State private var noLightningAddressAlert = false

    var body: some View {
        ZStack(alignment: .top) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // Thread History (Parents)
                        if !parentNotes.isEmpty {
                            threadSection
                            Divider()
                        }

                        // Main Note
                        mainNoteSection
                            .id("mainNote")

                        Divider()

                        // Replies Section
                        repliesSection

                        #if os(iOS)
                        Color.clear.frame(height: 90)
                        #endif
                    }
                    .padding()
                }
                .onChange(of: isLoadingParents) { _, loading in
                    if !loading && !parentNotes.isEmpty {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                proxy.scrollTo("mainNote", anchor: .top)
                            }
                        }
                    }
                }
            }

            ZapNotificationBanner()
                .zIndex(1)
        }
        .background(Color.platformSecondaryGroupedBackground)
        .refreshable {
            #if os(iOS)
            MacRelaySyncService.shared.syncIfConfigured()
            #endif
            fetchParents()
            fetchReplies()
        }
        .navigationTitle("Note")

        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .automatic) {
                HStack(spacing: 8) {
                    Button {
                        let replyTarget: FeedNote = {
                            if note.kind == 6, let refId = note.repostedEventId,
                               let original = feedService.findNote(id: refId) {
                                return original
                            }
                            return note
                        }()
                        composeContext = ComposeContext(replyTo: replyTarget, quoteTo: nil)
                    } label: {
                        Image(systemName: "arrowshape.turn.up.left.fill")
                    }
                    
                    Menu {
                        if note.pubkey == nostrService.activeHexPubkey {
                            Button(role: .destructive, action: {
                                showingDeleteConfirm = true
                            }) {
                                Label("Delete Post", systemImage: "trash")
                            }
                        }

                        Button(action: {
                            showingReportDialog = true
                        }) {
                            Label("Report Post", systemImage: "flag.fill")
                        }

                        Button(action: {
                            blockUser(hexPubkey: note.pubkey)
                        }) {
                            Label("Block User", systemImage: "hand.raised.fill")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
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
            FeedMediaViewer(url: media.url, onDismiss: { showingMediaUrl = nil })
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
    
    private var mainNoteSection: some View {
        let profile = nostrService.profiles[note.pubkey]
        return VStack(alignment: .leading, spacing: 12) {
            // Repost indicator
            if let reposter = note.repostedBy {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.2.squarepath")
                        .font(.system(size: 10, weight: .semibold))
                    Text("\(nostrService.profiles[reposter]?.bestName ?? String(reposter.prefix(8))) reposted")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(.green.opacity(0.7))
            }

            HStack(spacing: 12) {
                AvatarView(url: profile?.pictureURL, pubkey: note.pubkey)
                    .onTapGesture { showingProfilePubkey = note.pubkey }

                VStack(alignment: .leading, spacing: 2) {
                    let profileName = profile?.bestName ?? "npub…" + String(note.pubkey.suffix(6))
                    Text(profileName)
                        .font(.headline)
                    Text(relativeTime(note.createdAt))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            // Content — for empty-content reposts, show the referenced note
            if note.kind == 6 && note.content.isEmpty, let refId = note.repostedEventId,
               let original = feedService.findNote(id: refId) {
                Text(NostrContentFormatter.format(original.content, mediaURLs: original.mediaURLs, hideQuotes: true))
                    .font(.system(size: 16, weight: .regular, design: .default))
                    .foregroundColor(Color(red: 1, green: 1, blue: 1))
                    .lineSpacing(3)
                    .lineLimit(nil)
                    .textSelection(.enabled)

                if !original.mediaURLs.isEmpty {
                    mediaCarousel(urls: original.mediaURLs)
                }
            } else {
                Text(NostrContentFormatter.format(note.content, mediaURLs: note.mediaURLs, hideQuotes: true))
                    .font(.system(size: 16, weight: .regular, design: .default))
                    .foregroundColor(Color(red: 1, green: 1, blue: 1))
                    .lineSpacing(3)
                    .lineLimit(nil)
                    .textSelection(.enabled)
                    .environment(\.openURL, OpenURLAction { url in
                        if url.scheme == "nostr" {
                            let identifier = url.absoluteString.replacingOccurrences(of: "nostr:", with: "")
                            if identifier.hasPrefix("npub1") || identifier.hasPrefix("nprofile1") {
                                self.showingProfilePubkey = identifier
                                return .handled
                            } else if identifier.hasPrefix("note1") || identifier.hasPrefix("nevent1") {
                                self.showingNoteId = identifier
                                return .handled
                            }
                        }
                        return .systemAction
                    })

                if !note.mediaURLs.isEmpty {
                    mediaCarousel(urls: note.mediaURLs)
                }
            }

            // Quoted Notes
            if !note.quotedEventIds.isEmpty {
                VStack(spacing: 8) {
                    ForEach(note.quotedEventIds, id: \.self) { quoteId in
                        if let quotedNote = feedService.findNote(id: quoteId) {
                            NavigationLink(value: quotedNote) {
                                QuotedNoteView(note: quotedNote)
                                    .environmentObject(nostrService)
                            }
                            .buttonStyle(.plain)
                        } else {
                            // Request missing quote
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
            
            HStack(spacing: 24) {
                let stats = feedService.noteStats[note.id]
                actionButton(icon: "message", count: stats?.replies) {
                    let replyTarget: FeedNote = {
                        if note.kind == 6, let refId = note.repostedEventId,
                           let original = feedService.findNote(id: refId) {
                            return original
                        }
                        return note
                    }()
                    composeContext = ComposeContext(replyTo: replyTarget, quoteTo: nil)
                }
                let repostCheckId = note.repostedEventId ?? note.id
                let isReposted = feedService.repostedEventIds.contains(repostCheckId)
                actionButton(
                    icon: "arrow.2.squarepath",
                    color: isReposted ? .green : .secondary,
                    count: stats?.reposts
                ) {
                    repostNote()
                }
                .scaleEffect(isReposted ? 1.2 : 1.0)
                .animation(.spring(response: 0.3, dampingFraction: 0.45), value: isReposted)
                actionButton(icon: "quote.closing", count: nil) {
                    composeContext = ComposeContext(replyTo: nil, quoteTo: note)
                }

                let isLiked = feedService.likedEventIds.contains(note.id)
                actionButton(
                    icon: isLiked ? "heart.fill" : "heart",
                    color: isLiked ? .red : .secondary,
                    count: stats?.reactions
                ) {
                    likeNote()
                }
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
                    let isZapped = feedService.zappedEventIds[note.id] != nil
                    let hasLightning = lud16 != nil
                    actionButton(
                        icon: isZapped ? "bolt.fill" : "bolt",
                        color: isZapped ? .orange : (hasLightning ? .secondary : .secondary.opacity(0.35)),
                        count: stats?.zaps
                    ) {
                        if let lud16 = lud16 {
                            Task { await zapNote(lud16: lud16) }
                        } else {
                            noLightningAddressAlert = true
                        }
                    }
                    .scaleEffect(isZapped ? 1.2 : 1.0)
                    .animation(.spring(response: 0.3, dampingFraction: 0.45), value: isZapped)
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
                        .scaleEffect(1.0)
                }

                ShareLink(
                    item: URL(string: "https://mynostrspace.com/thread/\(note.nevent)")!,
                    subject: Text("Nostr Note"),
                    message: Text("Check out this note on Nostr")
                ) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                Button {
                    showingBroadcastSheet = true
                } label: {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)

                Spacer()
            }
            .padding(.top, 8)
        }
        .alert("Zap Amount", isPresented: $showAmountPicker) {
            TextField("Amount in sats", text: $zapAmountSats)
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
            Button("Zap!") {
                if let amount = Int(zapAmountSats),
                   let lud16 = getLightingAddress(for: note.pubkey) {
                    Task { await zapNote(lud16: lud16, amount: amount) }
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Enter the amount of sats you want to zap.")
        }
    }
    
    private var threadSection: some View {
        VStack(alignment: .leading, spacing: 12) {

            ForEach(parentNotes) { parent in
                NavigationLink(value: parent) {
                    let parentProfile = nostrService.profiles[parent.pubkey]
                    CompactNoteRow(note: parent, profile: parentProfile)
                }
                .buttonStyle(.plain)
            }

            if isLoadingParents {
                FeedNoteSkeletonRow()
            }
        }
    }

    private var repliesSection: some View {
        let targetId = (note.kind == 6 && note.repostedEventId != nil) ? note.repostedEventId! : note.id
        let currentReplies = feedService.notes.filter { $0.parentEventId == targetId }
            .sorted(by: { $0.createdAt < $1.createdAt })
            
        return VStack(alignment: .leading, spacing: 12) {
            Text("Replies")
                .font(.headline)
                .padding(.bottom, 4)

            if isLoadingReplies && currentReplies.isEmpty {
                ForEach(0..<3, id: \.self) { _ in
                    FeedNoteSkeletonRow()
                }
            } else if currentReplies.isEmpty {
                Text("No replies yet")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
            } else {
                ForEach(currentReplies) { reply in
                    ThreadedReplyNode(
                        reply: reply,
                        allNotes: feedService.notes,
                        depth: 1,
                        onReply: { target in
                            composeContext = ComposeContext(replyTo: target, quoteTo: nil)
                        },
                        onQuote: { target in
                            composeContext = ComposeContext(replyTo: nil, quoteTo: target)
                        },
                        onProfile: { pubkey in
                            showingProfilePubkey = pubkey
                        },
                        onMedia: { url in
                            showingMediaUrl = IdentifiableURL(url: url)
                        }
                    )
                }
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
                onTap: { showingMediaUrl = IdentifiableURL(url: urls[0]) },
                maxHeight: 400,
                isThumbnail: false
            )
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
        } else {
            TabView {
                ForEach(urls, id: \.absoluteString) { url in
                    FeedMediaView(
                        url: url,
                        onTap: { showingMediaUrl = IdentifiableURL(url: url) },
                        maxHeight: 400,
                        isThumbnail: false
                    )
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            .mediaTabViewStyleCompat()
            .frame(height: 400)
            .padding(.top, 4)
        }
    }

    private func actionButton(icon: String, color: Color = .secondary, count: Int?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: icon)
                if let count = count, count > 0 {
                    Text("\(count)")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                }
            }
            .font(.subheadline)
            .foregroundColor(color)
        }
        .buttonStyle(.plain)
    }
    
    private func fetchReplies() {
        guard !isLoadingReplies else { return }
        isLoadingReplies = true

        // Try local relay AND external relays to find replies
        var relayURLs: [URL] = [URL(string: configService.config.nostrURL)!]
        let externalStrs = configService.config.feedRelays.isEmpty ? [
            "wss://relay.damus.io",
            "wss://relay.primal.net",
            "wss://nos.lol",
        ] : configService.config.feedRelays
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
                        let targetId = (self.note.kind == 6 && self.note.repostedEventId != nil) ? self.note.repostedEventId! : self.note.id
                        let filter: [String: Any] = ["kinds": [1], "#e": [targetId], "limit": 100]
                        let req = ["REQ", subId, filter] as [Any]
                        if let data = try? JSONSerialization.data(withJSONObject: req),
                           let str = String(data: data, encoding: .utf8) {
                            client.send(text: str)
                        }
                    }
                }
                .store(in: &cancellables)

            client.connect(url: url)
        }
        
        // Auto-disconnect and stop loading spinner after 6 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) {
            for client in activeClients {
                client.disconnect()
            }
            self.isLoadingReplies = false
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

            let reply = FeedNote(
                id: id,
                pubkey: pubkey,
                content: content,
                createdAt: Date(timeIntervalSince1970: TimeInterval(createdAt)),
                tags: tags,
                kind: kind
            )

            if !FeedNote.isNoiseOrSpam(content: content, tags: tags) {
                if feedService.findNote(id: id) == nil {
                    feedService.addNote(reply)
                }
                
                // Fetch profile for the reply author if missing
                let replyProfile = nostrService.profiles[pubkey]
                if replyProfile == nil {
                    nostrService.fetchMissingProfiles(for: [pubkey])
                }
            }
        } else if type == "EOSE" {
            client.disconnect()
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
        guard let signed = nostrService.signEvent(kind: 7, content: "+", tags: [["e", noteId], ["p", note.pubkey]]) else { return }
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
        guard let signed = nostrService.signEvent(kind: 7, content: emoji, tags: [["e", note.id], ["p", note.pubkey]]) else { return }
        nostrService.postEvent(signed)
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
        } catch {
            print("Zap failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Thread Loading

    private func fetchParents() {
        guard let parentId = note.parentEventId, !isLoadingParents else { return }
        isLoadingParents = true

        // Try local relay AND external relays to find the parent
        var relayURLs: [URL] = [URL(string: configService.config.nostrURL)!]
        let externalStrs = configService.config.feedRelays.isEmpty ? [
            "wss://relay.damus.io",
            "wss://relay.primal.net",
            "wss://nos.lol",
        ] : configService.config.feedRelays
        relayURLs.append(contentsOf: externalStrs.compactMap { URL(string: $0) })

        for url in relayURLs {
            let client = WebSocketClient()
            client.isTemporary = true // Clean up when done

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
                        let filter: [String: Any] = ["ids": [parentId], "limit": 1]
                        let req = ["REQ", "thread-\(UUID().uuidString.prefix(8))", filter] as [Any]
                        if let data = try? JSONSerialization.data(withJSONObject: req),
                           let str = String(data: data, encoding: .utf8) {
                            client.send(text: str)
                        }
                    }
                }
                .store(in: &cancellables)

            client.connect(url: url)

            // Generous timeout so deep chains have time to resolve
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
                client.disconnect()
                self.isLoadingParents = false
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
                // Insert parent at the beginning to maintain chronological order
                parentNotes.insert(parent, at: 0)
                parentNotes.sort { $0.createdAt < $1.createdAt }

                // Recursively fetch the parent's parent
                if let grandparentId = parent.parentEventId {
                    fetchParentNote(id: grandparentId, client: client)
                } else {
                    // Reached root of thread
                    isLoadingParents = false
                    client.disconnect()
                }
            }

            // Fetch profile for the parent note author
            let parentAuthorProfile = nostrService.profiles[pubkey]
            if parentAuthorProfile == nil {
                nostrService.fetchMissingProfiles(for: [pubkey])
            }
        } else if type == "EOSE" {
            // Do NOT disconnect here — we may have already sent another REQ on this
            // client to chase the grandparent. The timeout handles final cleanup.
            // Only mark loading done if we never received any EVENT (no parent found).
            if parentNotes.isEmpty {
                isLoadingParents = false
            }
        }
    }

    private func fetchParentNote(id: String, client: WebSocketClient) {
        let filter: [String: Any] = ["ids": [id], "limit": 1]
        let req = ["REQ", "thread-\(UUID().uuidString.prefix(8))", filter] as [Any]
        if let data = try? JSONSerialization.data(withJSONObject: req),
           let str = String(data: data, encoding: .utf8) {
            client.send(text: str)
        }
    }

    
    private func relativeTime(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        return fmt.string(from: date)
    }
}

// MARK: - ThreadedReplyNode

struct ThreadedReplyNode: View {
    let reply: FeedNote
    let allNotes: [FeedNote]
    let depth: Int
    var onReply: ((FeedNote) -> Void)? = nil
    var onQuote: ((FeedNote) -> Void)? = nil
    var onProfile: ((String) -> Void)? = nil
    var onMedia: ((URL) -> Void)? = nil

    @EnvironmentObject var nostrService: NostrService
    @EnvironmentObject var configService: ConfigService

    var body: some View {
        let childReplies = allNotes.filter { $0.parentEventId == reply.id }
            .sorted(by: { $0.createdAt < $1.createdAt })

        VStack(alignment: .leading, spacing: 8) {
            NavigationLink(value: reply) {
                let replyProfile = nostrService.profiles[reply.pubkey]
                FeedNoteRow(
                    note: reply,
                    profile: replyProfile,
                    onReply: { onReply?(reply) },
                    onQuote: { onQuote?(reply) },
                    onProfile: onProfile,
                    onMedia: onMedia,
                    showParent: false
                )
            }
            .buttonStyle(.plain)
            
            if !childReplies.isEmpty {
                if depth >= 3 {
                    // Prevent excessive indentation squishing on narrow mobile screens
                    NavigationLink(value: reply) {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.turn.down.right")
                                .font(.system(size: 11, weight: .bold))
                            Text("Show \(childReplies.count) more \(childReplies.count == 1 ? "reply" : "replies")")
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                        }
                        .foregroundColor(Color.havenPurple)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 12)
                        .background(Color.havenPurple.opacity(0.1))
                        .cornerRadius(8)
                        .padding(.leading, 8)
                    }
                    .buttonStyle(.plain)
                } else {
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
                                    onReply: onReply,
                                    onQuote: onQuote,
                                    onProfile: onProfile,
                                    onMedia: onMedia
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - CompactNoteRow

struct CompactNoteRow: View {
    let note: FeedNote
    let profile: FeedProfile?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                AvatarView(url: profile?.pictureURL, pubkey: note.pubkey)
                    .frame(width: 28, height: 28)

                Text(profile?.bestName ?? "npub…" + String(note.pubkey.suffix(6)))
                    .font(.caption.bold())

                Spacer()

                Text(relativeTime(note.createdAt))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Text(NostrContentFormatter.format(note.content, mediaURLs: note.mediaURLs))
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(3)
        }
        .padding(10)
        .background(Color.platformControlBackground)
        .cornerRadius(10)
    }

    private func relativeTime(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateStyle = .short
        fmt.timeStyle = .short
        return fmt.string(from: date)
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
                            .font(.largeTitle)
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

        let hexId: String
        if noteId.hasPrefix("note1") {
            hexId = Bech32.decode(noteId)?.hexString ?? noteId
        } else if noteId.hasPrefix("nevent1") {
            hexId = noteId // Simplified
        } else {
            hexId = noteId
        }

        let relays = [URL(string: configService.config.nostrURL)!] + 
                     [URL(string: "wss://relay.damus.io")!, URL(string: "wss://relay.primal.net")!]

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
                        let filter: [String: Any] = ["ids": [hexId], "limit": 1]
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
