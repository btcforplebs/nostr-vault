import SwiftUI

/// Navigation route for the article reader.
///
/// Deliberately distinct from `FeedNote` so the Articles feed can push a reader
/// without changing what tapping a note does anywhere else in the app.
struct ArticleRoute: Hashable, Identifiable {
    let note: FeedNote
    var id: String { note.id }
}

// MARK: - Reader

/// Full-body reader for a long-form event.
struct ArticleReaderView: View {
    let note: FeedNote
    @EnvironmentObject var nostrService: NostrService
    @ObservedObject private var feedService = FeedService.shared
    @State private var showingMediaUrl: IdentifiableURL?
    @Namespace private var mediaZoom
    @State private var composeContext: ComposeContext?
    @State private var zapSheetContext: ZapSheetContext?
    @State private var noLightningAddressAlert = false
    @State private var highlighting = false
    @State private var highlightDraft: HighlightDraft?
    /// Other people's highlights of this article, newest first.
    @State private var highlights: [ArticleHighlight] = []
    /// Where each highlight sits, worked out once per load, off the main
    /// thread — never in `body`, which re-runs on every profile update.
    @State private var highlightsByBlock: [String: [ArticleHighlight]] = [:]
    @State private var shownHighlights: HighlightGroup?
    /// Replying to a highlight from inside the highlights sheet, which needs
    /// its own compose sheet: a second sheet can't stack on the reader's.
    @State private var highlightCommentContext: ComposeContext?
    /// Likes, zaps and comments from the network.
    @State private var tally = ArticleTally()
    @State private var blocked = ConfigService.shared.activeAccountBlockedHexPubkeys
    @AppStorage(PostButtons.storageKey) private var postButtons = ""
    @Environment(\.floatingTabBarHeight) private var tabBarHeight

    private var metadata: LongFormMetadata { note.longFormMetadata }
    private var profile: FeedProfile? { nostrService.profiles[note.pubkey] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let imageURL = metadata.imageURL {
                    RetryableAsyncImage(url: imageURL, contentMode: .fill, targetSize: CGSize(width: 1000, height: 500))
                        .frame(height: 200)
                        .frame(maxWidth: .infinity)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                Text(note.longFormDisplayTitle)
                    .font(.appSystem(size: 26, weight: .bold))
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    AvatarView(url: profile?.pictureURL, pubkey: note.pubkey, size: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(profile?.bestName ?? "npub…" + String(note.pubkey.suffix(6)))
                            .font(.appSystem(size: 13, weight: .semibold))
                        HStack(spacing: 4) {
                            Text(note.longFormDisplayDate, format: .dateTime.month(.abbreviated).day().year())
                            if note.gatedArticle != nil {
                                Text("· 🔒 Locked")
                            } else if let minutes = LongFormMetadata.readingTimeMinutes(for: note.content) {
                                Text("· \(minutes) min read")
                            }
                        }
                        .font(.appSystem(size: 11))
                        .foregroundColor(.secondary)
                    }
                    Spacer(minLength: 0)
                }

                if let summary = metadata.summary {
                    Text(summary)
                        .font(.appSystem(size: 15))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Divider()
                }

                actionBar

                if highlighting {
                    Label(String(localized: "Tap a paragraph to highlight it"), systemImage: "highlighter")
                        .font(.appSystem(size: 13, weight: .medium))
                        .foregroundColor(.havenPurple)
                }

                if let gated = note.gatedArticle {
                    GatedArticleBody(note: note, gated: gated) { url in
                        showingMediaUrl = IdentifiableURL(url: url, allURLs: [url])
                    }
                } else {
                MarkdownBodyView(
                    markdown: note.content,
                    onImageTap: { url in
                        showingMediaUrl = IdentifiableURL(url: url, allURLs: [url])
                    },
                    onHighlight: highlighting ? { text in highlightDraft = HighlightDraft(context: text) } : nil,
                    highlights: highlightsByBlock,
                    onShowHighlights: { shownHighlights = HighlightGroup(highlights: $0) }
                )
                }

                if !highlights.isEmpty {
                    Divider()
                    highlightsSection
                }

                Divider()
                actionBar

                commentsSection
            }
            .padding(20)
            // The iPhone's tab bar floats over the reader; without this the
            // bottom action bar sits under it and can't be tapped.
            .padding(.bottom, tabBarHeight)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollDirectionTracking(feedService: feedService)
        .background(Color.platformWindowBackground)
        .mediaViewer(item: $showingMediaUrl, namespace: mediaZoom)
        .sheet(item: $composeContext) { ctx in
            ComposeView(onDismiss: { composeContext = nil }, replyTo: ctx.replyTo, quoteTo: ctx.quoteTo)
        }
        .sheet(item: $zapSheetContext) { _ in
            CustomZapSheet(defaultAmount: ConfigService.shared.config.defaultZapAmount / 1000) { amount in
                zap(amount: amount)
            }
            #if os(iOS)
            .presentationDetents([.height(380), .medium])
            .smallSheetSizing()
            .presentationDragIndicator(.visible)
            .presentationBackground(Color.platformWindowBackground)
            #endif
        }
        .task(id: note.id) { await loadHighlights() }
        .task(id: note.id) { await loadEngagement() }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("BlockedAccountsUpdated"))) { _ in
            let now = ConfigService.shared.activeAccountBlockedHexPubkeys
            guard now != blocked else { return }
            blocked = now
            // Fewer is right after a block, so the newer-is-bigger check is skipped.
            let id = note.id
            Task {
                await showHighlights(Self.highlightCache[id] ?? [], replacing: true)
                await showEngagement(Self.engagementCache[id] ?? [], replacing: true)
            }
        }
        // A comment opens as a note with its replies. Declared here as well as
        // by the feeds, because the iPad note column's stack has no route for
        // a FeedNote when it holds an article.
        .navigationDestination(for: FeedNote.self) { NoteDetailView(note: $0) }
        .onChange(of: composeContext == nil) { _, closed in
            // Pick up the comment just posted.
            if closed { Task { await loadEngagement() } }
        }
        .sheet(item: $shownHighlights) { group in
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(group.highlights) { highlight in
                            HighlightRow(highlight: highlight) {
                                highlightCommentContext = ComposeContext(replyTo: highlight.note, quoteTo: nil)
                            }
                        }
                    }
                    .padding(20)
                }
                .sheet(item: $highlightCommentContext) { ctx in
                    ComposeView(onDismiss: { highlightCommentContext = nil }, replyTo: ctx.replyTo, quoteTo: ctx.quoteTo)
                }
                .navigationTitle(Text("Highlights"))
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { shownHighlights = nil }
                    }
                }
            }
            #if os(iOS)
            .presentationDetents([.medium, .large])
            #endif
            #if os(macOS)
            .frame(minWidth: 420, minHeight: 360)
            #endif
        }
        .sheet(item: $highlightDraft) { draft in
            HighlightSheet(draft: draft) { passage, comment in
                publishHighlight(passage: passage, context: draft.context, comment: comment)
            }
        }
        .alert(String(localized: "No Lightning address"), isPresented: $noLightningAddressAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(String(localized: "This author can't receive zaps yet."))
        }
    }

    // MARK: Actions

    private var liked: Bool { feedService.likedEventIds.contains(note.id) }
    private var zapped: Bool { feedService.zappedEventIds[note.id] != nil }

    private var actionBar: some View {
        HStack(spacing: 10) {
            actionButton(liked ? "heart.fill" : "heart", tint: liked ? .red : .secondary, label: "Like", count: likeCount) { like() }
            actionButton("bubble.left", tint: .secondary, label: "Comment", count: tally.commentCount) {
                composeContext = ComposeContext(replyTo: note, quoteTo: nil)
            }
            if PostButtons.showsZap(postButtons) {
                actionButton(zapped ? "bolt.fill" : "bolt", tint: zapped ? .orange : .secondary, label: "Zap",
                             count: zapSats, countText: zapSats > 0 ? Self.compact(zapSats) : nil) {
                    if lightningAddress != nil {
                        zapSheetContext = ZapSheetContext(defaultAmount: ConfigService.shared.config.defaultZapAmount / 1000)
                    } else {
                        noLightningAddressAlert = true
                    }
                }
            }
            actionButton("highlighter", tint: highlighting ? .havenPurple : .secondary, label: "Highlight") {
                withAnimation(Motion.panel) { highlighting.toggle() }
            }
            ShareLink(item: URL(string: "https://mynostrspace.com/thread/\(note.nevent)")!) {
                actionIcon("square.and.arrow.up", tint: .secondary)
            }
            .accessibilityLabel(Text("Share"))
            Spacer(minLength: 0)
        }
    }

    private func actionButton(_ symbol: String, tint: Color, label: LocalizedStringKey, count: Int = 0,
                              countText: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            actionIcon(symbol, tint: tint, countText: countText ?? (count > 0 ? Self.compact(count) : nil))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
        .accessibilityValue(count > 0 ? Text(verbatim: "\(count)") : Text(verbatim: ""))
    }

    private func actionIcon(_ symbol: String, tint: Color, countText: String? = nil) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.appSystem(size: 15, weight: .medium))
            if let countText {
                Text(countText)
                    .font(.appSystem(size: 13, weight: .semibold))
                    .monospacedDigit()
            }
        }
        .foregroundColor(tint)
        .padding(.horizontal, countText == nil ? 0 : 12)
        .frame(minWidth: 38, minHeight: 34)
        .background(Color.secondary.opacity(0.1))
        .clipShape(Capsule())
        .contentShape(Capsule())
    }

    /// 1234 -> "1.2K", the way the feed shows counts.
    private static func compact(_ value: Int) -> String {
        value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
    }

    /// Your own like counts as soon as you tap, before a relay echoes it.
    private var likeCount: Int {
        let me = ConfigService.shared.activeAccountHexPubkey
        return tally.likers.count + (liked && !tally.likers.contains(me) ? 1 : 0)
    }

    /// Your own zap counts as soon as it is paid, before the receipt arrives.
    private var zapSats: Int {
        tally.zapSats + (tally.zapSats == 0 ? (feedService.zappedEventIds[note.id] ?? 0) : 0)
    }

    private var lightningAddress: String? {
        guard let profile = nostrService.profiles[note.pubkey] else { return nil }
        if let lud06 = profile.lud06, !lud06.isEmpty { return "lnurl:" + lud06 }
        if let lud16 = profile.lud16, !lud16.isEmpty { return lud16 }
        return nil
    }

    /// Same optimistic flow as the feed's like, but tagged with the article's
    /// `a` coordinate so clients counting by address see it.
    private func like() {
        guard !liked else { return }
        let noteId = note.id
        feedService.likedEventIds.insert(noteId)
        feedService.saveInteractionState()
        let tags = ArticleEngagement.reactionTags(id: noteId, kind: note.kind, pubkey: note.pubkey, tags: note.tags,
                                                  relayHint: ConfigService.shared.config.nostrURL)
        Task {
            let powSnap = PowPreferences.snapshot()
            let powDiff = powSnap.reactionEnabled ? powSnap.reactionDifficulty : 0
            guard let signed = await nostrService.mineAndSignEventAsync(kind: 7, content: ConfigService.shared.config.defaultReactionEmoji,
                                                                         tags: tags, difficulty: powDiff) else {
                await MainActor.run {
                    feedService.likedEventIds.remove(noteId)
                    feedService.saveInteractionState()
                }
                return
            }
            nostrService.postEvent(signed)
        }
    }

    private func zap(amount: Int) {
        guard let lud16 = lightningAddress else { return }
        let coord = NIP10Thread.coordinate(kind: note.kind, pubkey: note.pubkey, tags: note.tags)
        let noteId = note.id
        Task {
            do {
                try await ZapService.shared.zapNote(noteId: noteId, notePubkey: note.pubkey, lud16: lud16,
                                                    amountSats: amount, addressTag: coord)
                await MainActor.run {
                    feedService.zappedEventIds[noteId] = amount
                    feedService.saveInteractionState()
                }
            } catch {
                print("Article zap failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Highlights from the network

    private var coordinate: String? {
        NIP10Thread.coordinate(kind: note.kind, pubkey: note.pubkey, tags: note.tags)
    }

    private var highlightsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Highlights · \(highlights.count)", systemImage: "highlighter")
                .font(.appSystem(size: 15, weight: .semibold))
            ForEach(highlights) { highlight in
                HighlightRow(highlight: highlight) {
                    composeContext = ComposeContext(replyTo: highlight.note, quoteTo: nil)
                }
            }
        }
    }

    /// The article's relay, the feed relays and the author's outbox: where a
    /// highlight of it is likely to have been sent.
    private var highlightRelays: [URL] {
        let config = ConfigService.shared.config
        var strings = [config.nostrURL]
        strings += config.readRelays
        strings += nostrService.outboxRelays[note.pubkey] ?? []
        var seen = Set<String>()
        return strings
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))).inserted }
            .prefix(8)
            .compactMap { URL(string: $0) }
    }

    /// Highlights already fetched this session, so reopening an article
    /// shows them at once while the relays are asked again.
    @MainActor private static var highlightCache: [String: [[String: Any]]] = [:]

    private func loadHighlights() async {
        let articleId = note.id
        if let cached = Self.highlightCache[articleId] { await showHighlights(cached) }
        // `query` returns only signature-checked events. Show them as each
        // relay answers rather than after the slowest one, which could hold
        // the whole list back for the full timeout.
        let events = await ZapHistoryService.query(
            filters: ArticleEngagement.highlightFilters(id: articleId, coordinate: coordinate),
            relays: highlightRelays,
            onProgress: { partial in Task { await showHighlights(partial) } })
        Self.highlightCache[articleId] = events
        await showHighlights(events)
    }

    private func showHighlights(_ events: [[String: Any]], replacing: Bool = false) async {
        let articleId = note.id
        let events = ArticleBlockFilter.visibleEvents(events, blocked: blocked)
        let coordinate = coordinate
        let content = note.content
        let (found, placed) = await Task.detached(priority: .userInitiated) { () -> ([ArticleHighlight], [String: [ArticleHighlight]]) in
            // Only a 9802 that points at this article counts, spam dropped
            // the same way the thread view drops it.
            let highlights = ArticleEngagement.shown(events.compactMap { event -> ArticleHighlight? in
                if let text = event["content"] as? String, let tags = event["tags"] as? [[String]],
                   FeedNote.isNoiseOrSpam(content: text, tags: tags) { return nil }
                return ArticleHighlight(event: event, articleId: articleId, coordinate: coordinate)
            })
            let blocks = MarkdownParser.parse(content).compactMap { block in
                block.highlightableText.map { (id: block.id, text: ArticleEngagement.plainText($0)) }
            }
            return (highlights, ArticleEngagement.place(highlights, in: blocks))
        }.value
        await MainActor.run {
            // An earlier, smaller snapshot can finish placing after a later one.
            guard replacing || found.count >= highlights.count else { return }
            highlights = found
            highlightsByBlock = placed
            let missing = Set(found.map(\.pubkey)).filter { nostrService.profiles[$0] == nil }
            if !missing.isEmpty { nostrService.fetchMissingProfiles(for: Array(missing)) }
        }
    }

    // MARK: Likes, zaps and comments from the network

    @ViewBuilder
    private var commentsSection: some View {
        if tally.commentCount > 0 {
            VStack(alignment: .leading, spacing: 12) {
                Label("Comments · \(tally.commentCount)", systemImage: "bubble.left.and.bubble.right")
                    .font(.appSystem(size: 15, weight: .semibold))
                ForEach(tally.topLevelComments.compactMap(Self.commentNote)) { comment in
                    ArticleCommentRow(note: comment,
                                      profile: nostrService.profiles[comment.pubkey],
                                      replies: tally.replyCounts[comment.id] ?? 0)
                }
            }
        }
    }

    private static func commentNote(_ event: [String: Any]) -> FeedNote? {
        guard let id = event["id"] as? String, let pubkey = event["pubkey"] as? String,
              let content = event["content"] as? String, let tags = event["tags"] as? [[String]],
              let kind = event["kind"] as? Int,
              let createdAt = (event["created_at"] as? NSNumber)?.doubleValue else { return nil }
        return FeedNote(id: id, pubkey: pubkey, content: content,
                        createdAt: Date(timeIntervalSince1970: createdAt), tags: tags, kind: kind)
    }

    /// Fetched this session, so reopening an article shows its counts at once
    /// while the relays are asked again.
    @MainActor private static var engagementCache: [String: [[String: Any]]] = [:]

    private func loadEngagement() async {
        let articleId = note.id
        if let cached = Self.engagementCache[articleId] { await showEngagement(cached) }
        let events = await ZapHistoryService.query(
            filters: ArticleEngagement.engagementFilters(id: articleId, coordinate: coordinate),
            relays: highlightRelays,
            onProgress: { partial in Task { await showEngagement(partial) } })
        // Keep what an earlier load found if a relay this time came back short.
        var byId: [String: [String: Any]] = [:]
        for event in (Self.engagementCache[articleId] ?? []) + events {
            if let id = event["id"] as? String { byId[id] = event }
        }
        Self.engagementCache[articleId] = Array(byId.values)
        await showEngagement(Array(byId.values))
    }

    private func showEngagement(_ events: [[String: Any]], replacing: Bool = false) async {
        let articleId = note.id
        let events = ArticleBlockFilter.visibleEvents(events, blocked: blocked)
        let coordinate = coordinate
        let found = await Task.detached(priority: .userInitiated) { () -> ArticleTally in
            // Spam comments are dropped the same way the thread view drops them.
            let clean = events.filter { event in
                guard let kind = event["kind"] as? Int,
                      kind == ArticleEngagement.commentKind || kind == ArticleEngagement.noteKind,
                      let text = event["content"] as? String,
                      let tags = event["tags"] as? [[String]] else { return true }
                return !FeedNote.isNoiseOrSpam(content: text, tags: tags)
            }
            return ArticleEngagement.tally(clean, articleId: articleId, coordinate: coordinate)
        }.value
        await MainActor.run {
            // An earlier, smaller snapshot can finish after a later one.
            guard replacing || found.likers.count + found.zaps + found.commentCount
                    >= tally.likers.count + tally.zaps + tally.commentCount else { return }
            tally = found
            let commenters = found.topLevelComments.compactMap { $0["pubkey"] as? String }
            let missing = Set(commenters).filter { nostrService.profiles[$0] == nil }
            if !missing.isEmpty { nostrService.fetchMissingProfiles(for: Array(missing)) }
        }
    }

    private func publishHighlight(passage: String, context: String, comment: String) {
        let relay = ConfigService.shared.config.nostrURL
        let tags = ArticleEngagement.highlightTags(id: note.id, kind: note.kind, pubkey: note.pubkey, tags: note.tags,
                                                   relayHint: relay, passage: passage, context: context, comment: comment)
        let content = passage.trimmingCharacters(in: .whitespacesAndNewlines)
        highlighting = false
        Task {
            _ = try? await ModePostPublisher.publish(kind: ArticleEngagement.highlightKind, content: content,
                                                     tags: tags, nostrService: nostrService)
            // Show it among everyone else's once a relay has it.
            await loadHighlights()
        }
    }
}

extension ArticleHighlight {
    /// The highlight as a note, for composing a comment on it.
    var note: FeedNote {
        FeedNote(id: id, pubkey: pubkey, content: passage, createdAt: createdAt, tags: tags,
                 kind: ArticleEngagement.highlightKind)
    }
}

/// The highlights behind one tinted passage, for the sheet.
struct HighlightGroup: Identifiable {
    let id = UUID()
    let highlights: [ArticleHighlight]
}
