import SwiftUI

/// Navigation route for the article reader.
///
/// Deliberately distinct from `FeedNote` so the Articles feed can push a reader
/// without changing what tapping a note does anywhere else in the app.
struct ArticleRoute: Hashable, Identifiable {
    let note: FeedNote
    var id: String { note.id }
}

// MARK: - Card

/// One row in the Articles feed: hero image, title, summary, author and
/// reading time. Renders entirely from tags plus a truncated body preview, so
/// it never needs the full article text.
struct ArticleCardView: View {
    let note: FeedNote
    let profile: FeedProfile?
    var onAuthorTap: ((String) -> Void)? = nil

    private var metadata: LongFormMetadata { note.longFormMetadata }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let imageURL = metadata.imageURL {
                RetryableAsyncImage(url: imageURL, contentMode: .fill, targetSize: CGSize(width: 800, height: 400))
                    .frame(height: 160)
                    .frame(maxWidth: .infinity)
                    .clipped()
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(note.longFormDisplayTitle)
                    .font(.appSystem(size: 18, weight: .bold))
                    .foregroundColor(.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)

                if let preview = previewText, !preview.isEmpty {
                    Text(preview)
                        .font(.appSystem(size: 14))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(3)
                }

                if !metadata.topics.isEmpty {
                    topicChips
                }

                HStack(spacing: 8) {
                    AvatarView(url: profile?.pictureURL, pubkey: note.pubkey, size: 22)
                        .onTapGesture { onAuthorTap?(note.pubkey) }

                    Text(profile?.bestName ?? "npub…" + String(note.pubkey.suffix(6)))
                        .font(.appSystem(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                        .lineLimit(1)

                    Text("·")
                        .foregroundColor(.secondary)

                    Text(note.longFormDisplayDate, format: .dateTime.month(.abbreviated).day().year())
                        .font(.appSystem(size: 12))
                        .foregroundColor(.secondary)

                    if let gated = note.gatedArticle {
                        Text("·")
                            .foregroundColor(.secondary)
                        Label("\(gated.priceSats) sats", systemImage: "lock.fill")
                            .font(.appSystem(size: 12, weight: .semibold))
                            .foregroundColor(.havenPurple)
                    } else if let minutes = LongFormMetadata.readingTimeMinutes(for: note.content) {
                        Text("·")
                            .foregroundColor(.secondary)
                        Text("\(minutes) min read")
                            .font(.appSystem(size: 12))
                            .foregroundColor(.secondary)
                    }

                    Spacer(minLength: 0)
                }
            }
            .padding(14)
        }
        .background(Color.controlBackgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.platformSeparator, lineWidth: 0.5)
        )
        .contentShape(Rectangle())
    }

    /// The author's own `summary` tag when they wrote one, otherwise the top of
    /// the body with markdown syntax stripped.
    private var previewText: String? {
        if let summary = metadata.summary { return summary }
        let body = note.gatedArticle == nil ? note.content : GatedArticleTeaser.strip(note.content)
        let plain = MarkdownParser.plainText(body, limit: 200)
        return plain.isEmpty ? nil : plain
    }

    private var topicChips: some View {
        // A handful of topics keeps the card one line; long-form authors
        // sometimes attach a dozen.
        HStack(spacing: 6) {
            ForEach(metadata.topics.prefix(3), id: \.self) { topic in
                Text(topic)
                    .font(.appSystem(size: 10, weight: .semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.havenPurplePale)
                    .foregroundColor(.havenPurple)
                    .clipShape(Capsule())
            }
        }
    }
}

// MARK: - Inline body (long-form inside the notes feed)

/// A long-form event drawn inside a normal feed row.
///
/// The notes feed carries kinds 1, 6 and 30023, but the row drew every one of
/// them as `Text(content)` — so an article arrived as its whole markdown body,
/// unbounded, with `##` and `---` intact and its title (a tag, not body text)
/// missing entirely.
///
/// Deliberately not `ArticleCardView`: the feed row already draws the author,
/// the timestamp and the action bar, and the card would draw a second author
/// line inside the first one.
struct ArticleInlineBody: View {
    let note: FeedNote
    /// Focused rows are the note detail's own header row, where the reader is
    /// what the user came for. In the feed it stays a preview.
    var isFocused: Bool = false
    var onImageTap: ((URL) -> Void)? = nil

    private var metadata: LongFormMetadata { note.longFormMetadata }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let imageURL = metadata.imageURL {
                RetryableAsyncImage(url: imageURL, contentMode: .fill, targetSize: CGSize(width: 800, height: 400))
                    .frame(height: isFocused ? 180 : 140)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            Text(note.longFormDisplayTitle)
                .font(.appSystem(size: isFocused ? 22 : 18, weight: .bold))
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(isFocused ? nil : 3)

            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                    .font(.appSystem(size: 10, weight: .semibold))
                Text(String(localized: "feed.note.longForm"))
                    .font(.appSystem(size: 11, weight: .semibold))
                if let gated = note.gatedArticle {
                    Text("· 🔒 \(gated.priceSats) sats")
                        .font(.appSystem(size: 11, weight: .semibold))
                } else if let minutes = LongFormMetadata.readingTimeMinutes(for: note.content) {
                    Text("· \(minutes) min read")
                        .font(.appSystem(size: 11))
                }
            }
            .foregroundColor(.havenPurple)
            .accessibilityElement(children: .combine)

            if isFocused {
                if let summary = metadata.summary {
                    Text(summary)
                        .font(.appSystem(size: 15))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Divider()
                }
                if let gated = note.gatedArticle {
                    GatedArticleBody(note: note, gated: gated, onImageTap: onImageTap)
                } else {
                    MarkdownBodyView(markdown: note.content, onImageTap: onImageTap)
                }
            } else if let preview = previewText, !preview.isEmpty {
                Text(preview)
                    .font(.appSystem(size: 15))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(3)
            }
        }
        .padding(.top, 4)
    }

    /// The author's `summary` tag when they wrote one, otherwise the top of the
    /// body with markdown syntax stripped — never the raw markdown.
    private var previewText: String? {
        if let summary = metadata.summary { return summary }
        let body = note.gatedArticle == nil ? note.content : GatedArticleTeaser.strip(note.content)
        let plain = MarkdownParser.plainText(body, limit: 200)
        return plain.isEmpty ? nil : plain
    }
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
                            if let gated = note.gatedArticle {
                                Text("· 🔒 \(gated.priceSats) sats")
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
            .presentationDragIndicator(.visible)
            .presentationBackground(Color.platformWindowBackground)
            #endif
        }
        .task(id: note.id) { await loadHighlights() }
        .task(id: note.id) { await loadEngagement() }
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

    private func showHighlights(_ events: [[String: Any]]) async {
        let articleId = note.id
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
            guard found.count >= highlights.count else { return }
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

    private func showEngagement(_ events: [[String: Any]]) async {
        let articleId = note.id
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
            guard found.likers.count + found.zaps + found.commentCount
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

/// One comment under an article: who, when, what. Opens as a note, where its
/// replies are.
struct ArticleCommentRow: View {
    let note: FeedNote
    let profile: FeedProfile?
    let replies: Int

    var body: some View {
        NoteNavigationLink(note: note) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    AvatarView(url: profile?.pictureURL, pubkey: note.pubkey, size: 24)
                    Text(profile?.bestName ?? "npub…" + String(note.pubkey.suffix(6)))
                        .font(.appSystem(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(note.createdAt, format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
                        .font(.appSystem(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                let text = NostrContentFormatter.format(note.content, mediaURLs: note.mediaURLs)
                if !text.characters.isEmpty {
                    Text(text)
                        .font(.appSystem(size: 14))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if replies > 0 {
                    Label(replies == 1 ? "1 reply" : "\(replies) replies", systemImage: "arrowshape.turn.up.left")
                        .font(.appSystem(size: 12, weight: .medium))
                        .foregroundColor(.havenPurple)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.08)))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}

/// One person's highlight: who, the passage, and their comment if any.
struct HighlightRow: View {
    let highlight: ArticleHighlight
    /// Opens a reply (a NIP-22 comment) to this highlight.
    var onComment: (() -> Void)? = nil
    @EnvironmentObject var nostrService: NostrService

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            content
            if let onComment {
                Button(action: onComment) {
                    Label("Comment", systemImage: "bubble.left")
                        .font(.appSystem(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.secondary.opacity(0.1), in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.leading, 11)
            }
        }
    }

    private var content: some View {
        let profile = nostrService.profiles[highlight.pubkey]
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                AvatarView(url: profile?.pictureURL, pubkey: highlight.pubkey, size: 22)
                Text(profile?.bestName ?? "npub…" + String(highlight.pubkey.suffix(6)))
                    .font(.appSystem(size: 13, weight: .semibold))
                Text(highlight.createdAt, style: .relative)
                    .font(.appSystem(size: 11))
                    .foregroundColor(.secondary)
                Spacer(minLength: 0)
            }
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5).fill(Color.yellow.opacity(0.8)).frame(width: 3)
                Text(highlight.passage)
                    .font(.appSystem(size: 14))
                    .italic()
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let comment = highlight.comment {
                Text(comment)
                    .font(.appSystem(size: 14))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The paragraph a highlight starts from; the sheet lets the reader trim it.
struct HighlightDraft: Identifiable {
    let id = UUID()
    let context: String
}

/// Edit the highlighted passage down to the part that matters and optionally
/// add a thought, which makes it a quote highlight.
struct HighlightSheet: View {
    let draft: HighlightDraft
    let onPublish: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var passage = ""
    @State private var comment = ""

    private var canPublish: Bool { !passage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $passage)
                        .font(.appSystem(size: 16))
                        .frame(minHeight: 140)
                } header: {
                    Text("Highlight")
                } footer: {
                    Text("Delete what you don't want to keep.")
                }
                Section("Your thoughts (optional)") {
                    TextField("Add a comment", text: $comment, axis: .vertical)
                        .lineLimit(2...5)
                }
            }
            .navigationTitle("Highlight")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Publish") {
                        onPublish(passage, comment)
                        dismiss()
                    }
                    .disabled(!canPublish)
                }
            }
        }
        .onAppear { if passage.isEmpty { passage = draft.context } }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 380)
        #endif
    }
}

// MARK: - Markdown body

/// Renders the block subset produced by `MarkdownParser`.
///
/// Inline emphasis is handed to `AttributedString`'s markdown initializer,
/// which covers bold/italic/links; anything it rejects falls back to the raw
/// text rather than dropping the line.
struct MarkdownBodyView: View {
    let markdown: String
    var onImageTap: ((URL) -> Void)? = nil
    /// Set while the reader is in highlight mode: text blocks become tappable
    /// and hand back their plain text.
    var onHighlight: ((String) -> Void)? = nil
    /// Other people's highlights, keyed by block id: those blocks get a tint
    /// and a count that opens them.
    var highlights: [String: [ArticleHighlight]] = [:]
    var onShowHighlights: (([ArticleHighlight]) -> Void)? = nil

    private var blocks: [MarkdownBlock] { MarkdownParser.parse(markdown) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(blocks) { block in
                switch block {
                case .heading(let level, let text):
                    inlineText(text)
                        .font(.appSystem(size: headingSize(level), weight: .bold))
                        .fixedSize(horizontal: false, vertical: true)
                        .highlightable(text, onHighlight, shown: highlights[block.id] ?? [], onShow: onShowHighlights)
                        .padding(.top, level <= 2 ? 8 : 2)

                case .paragraph(let text):
                    inlineText(text)
                        .font(.appSystem(size: 16))
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                        .highlightable(text, onHighlight, shown: highlights[block.id] ?? [], onShow: onShowHighlights)

                case .bullet(let text):
                    HStack(alignment: .top, spacing: 8) {
                        Text("•").font(.appSystem(size: 16, weight: .bold)).foregroundColor(.havenPurple)
                        inlineText(text).font(.appSystem(size: 16)).fixedSize(horizontal: false, vertical: true)
                    }
                    .highlightable(text, onHighlight, shown: highlights[block.id] ?? [], onShow: onShowHighlights)

                case .ordered(let index, let text):
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(index).")
                            .font(.appSystem(size: 16, weight: .bold))
                            .foregroundColor(.havenPurple)
                            .monospacedDigit()
                        inlineText(text).font(.appSystem(size: 16)).fixedSize(horizontal: false, vertical: true)
                    }
                    .highlightable(text, onHighlight, shown: highlights[block.id] ?? [], onShow: onShowHighlights)

                case .quote(let text):
                    HStack(alignment: .top, spacing: 10) {
                        Rectangle().fill(Color.havenPurple).frame(width: 3)
                        inlineText(text)
                            .font(.appSystem(size: 16))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .highlightable(text, onHighlight, shown: highlights[block.id] ?? [], onShow: onShowHighlights)

                case .code(let text):
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(text)
                            .font(.appSystem(size: 13, design: .monospaced))
                            .padding(10)
                    }
                    .background(Color.gray.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                case .image(let url):
                    RetryableAsyncImage(url: url, contentMode: .fill, targetSize: CGSize(width: 900, height: 600))
                        .frame(height: 200)
                        .frame(maxWidth: .infinity)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .onTapGesture { onImageTap?(url) }

                case .rule:
                    Divider()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 24
        case 2: return 20
        case 3: return 18
        default: return 16
        }
    }

    @ViewBuilder
    private func inlineText(_ text: String) -> some View {
        if let attributed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            Text(attributed).textSelection(.enabled)
        } else {
            Text(text).textSelection(.enabled)
        }
    }
}

private extension View {
    /// In highlight mode, tint the block and make the whole of it a tap target
    /// that reports its text without markdown.
    ///
    /// Outside highlight mode, a block other people highlighted gets a soft
    /// yellow tint and a count under it that opens who highlighted it.
    @ViewBuilder
    func highlightable(_ markdown: String, _ onHighlight: ((String) -> Void)?,
                       shown: [ArticleHighlight] = [], onShow: (([ArticleHighlight]) -> Void)? = nil) -> some View {
        if let onHighlight {
            self
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.havenPurple.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
                .onTapGesture { onHighlight(ArticleEngagement.plainText(markdown)) }
        } else if !shown.isEmpty {
            VStack(alignment: .trailing, spacing: 4) {
                self
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.yellow.opacity(0.16), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                Button { onShow?(shown) } label: {
                    Label("\(shown.count)", systemImage: "highlighter")
                        .font(.appSystem(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.yellow.opacity(0.16), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(shown.count == 1 ? "1 highlight" : "\(shown.count) highlights"))
            }
        } else {
            self
        }
    }
}

// MARK: - Gated (zap-to-unlock) body

/// The body of a gated article: its teaser and a lock panel until the reader
/// has paid, then the decrypted article. See `GatedArticle`.
struct GatedArticleBody: View {
    let note: FeedNote
    let gated: GatedArticle
    var onImageTap: ((URL) -> Void)? = nil
    @EnvironmentObject var nostrService: NostrService
    @Environment(\.openURL) private var openURL

    private enum Phase: Equatable {
        case checking, locked, paying, waiting, unlocked(String), failed(String)
    }
    @State private var phase: Phase = .checking
    #if !os(iOS)
    @State private var confirming = false
    #endif
    /// Shares of the price not yet paid. Fewer than all means money may have
    /// moved already: the button then pays only what is left, or just
    /// re-checks for the key, and never pays the same share twice.
    @State private var unpaid: [GatedArticle.Share] = []

    var body: some View {
        if case .unlocked(let markdown) = phase {
            MarkdownBodyView(markdown: markdown, onImageTap: onImageTap)
        } else {
            VStack(alignment: .leading, spacing: 16) {
                let teaser = GatedArticleTeaser.strip(note.content)
                if !teaser.isEmpty, teaser != note.longFormMetadata.summary {
                    MarkdownBodyView(markdown: teaser, onImageTap: onImageTap)
                }
                lockPanel
            }
            // Keyed on the reader too: the stored key and payments belong to
            // one account.
            .task(id: note.id + nostrService.activeHexPubkey) { await checkAccess(auto: true) }
        }
    }

    private var authorName: String {
        nostrService.profiles[note.pubkey]?.bestName ?? "the author"
    }

    private var paid: Bool { unpaid.count < gated.shares.count }
    private var dueSats: Int { unpaid.reduce(0) { $0 + $1.sats } }

    /// iOS never pays to unlock: that is buying digital content (App Store
    /// 3.1.1), and no opt-in changes that. It still opens an article paid for
    /// on the web or in another client, since the key server only checks the
    /// zap receipt.
    private var paysHere: Bool {
        #if os(iOS)
        false
        #else
        true
        #endif
    }

    /// Where to read or buy the article outside the app: the author's own
    /// link, or on iOS (where there is no pay button) the naddr on njump.
    private var webURL: URL? {
        if let url = GatedArticleTeaser.unlockURL(note.content) { return url }
        #if os(iOS)
        let relay = gated.shares.first(where: { $0.pubkey == note.pubkey })?.relay ?? gated.receiptRelays.first
        guard let identifier = note.longFormMetadata.identifier,
              let tlv = GatedArticle.naddrTLV(identifier: identifier, relay: relay, pubkey: note.pubkey, kind: note.kind),
              let naddr = Bech32.encode(hrp: "naddr", data: tlv) else { return nil }
        return URL(string: "https://njump.me/\(naddr)")
        #else
        return nil
        #endif
    }

    private var lockPanel: some View {
        #if os(iOS)
        lockCard
        #else
        lockCard
            .confirmationDialog(confirmTitle, isPresented: $confirming, titleVisibility: .visible) {
                Button("Zap \(dueSats) sats") { Task { await pay() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your zap unlocks the full article.")
            }
        #endif
    }

    private var lockCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "lock.fill")
                Text("Locked article")
                    .font(.appSystem(size: 16, weight: .bold))
                Spacer(minLength: 0)
                Text("\(gated.priceSats) sats")
                    .font(.appSystem(size: 13, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.havenPurplePale)
                    .foregroundColor(.havenPurple)
                    .clipShape(Capsule())
            }

            Text(statusText)
                .font(.appSystem(size: 14))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Re-checking for a key already paid for shows everywhere.
            if paysHere || (paid && unpaid.isEmpty) {
                Button {
                    if paid && unpaid.isEmpty {
                        Task { await waitForKey() }
                    } else {
                        #if !os(iOS)
                        confirming = true
                        #endif
                    }
                } label: {
                    HStack(spacing: 8) {
                        if busy {
                            ProgressView().controlSize(.small).tint(.white)
                        } else {
                            Image(systemName: paid && unpaid.isEmpty ? "arrow.clockwise" : "bolt.fill")
                        }
                        Text(busy ? busyLabel : buttonLabel)
                            .font(.appSystem(size: 15, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.havenPurple.opacity(busy ? 0.6 : 1))
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(busy)
            }

            HStack(spacing: 16) {
                if phase == .locked, !paid || (!paysHere && !unpaid.isEmpty) {
                    Button {
                        Task { await checkAccess(auto: false) }
                    } label: {
                        Label("Already paid?", systemImage: "checkmark.seal")
                            .font(.appSystem(size: 13, weight: .medium))
                            .foregroundColor(.havenPurple)
                    }
                    .buttonStyle(.plain)
                }
                if let web = webURL {
                    Button {
                        openURL(web)
                    } label: {
                        Label("Open on \(web.host ?? "the web")", systemImage: "safari")
                            .font(.appSystem(size: 13, weight: .medium))
                            .foregroundColor(.havenPurple)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
        .background(Color.controlBackgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.havenPurple.opacity(0.35), lineWidth: 1)
        )
    }

    private var confirmTitle: String {
        gated.shares.count == 1 ? "Zap \(dueSats) sats to \(authorName)?" : "Zap \(dueSats) sats to unlock?"
    }

    private var buttonLabel: String {
        if !paid { return "Zap \(gated.priceSats) sats to unlock" }
        return unpaid.isEmpty ? "Check again" : "Zap the remaining \(dueSats) sats"
    }

    private var busy: Bool { phase == .checking || phase == .paying || phase == .waiting }

    private var busyLabel: String {
        switch phase {
        case .paying: return "Zapping…"
        case .waiting: return "Unlocking…"
        default: return "Checking…"
        }
    }

    private var statusText: String {
        switch phase {
        case .failed(let message): return message
        case .waiting: return "Paid. Waiting for the author's server to see your zap. This can take a minute or two."
        case _ where paid && unpaid.isEmpty:
            return "You've zapped for this article. If it hasn't opened, the receipt is still on its way."
        case _ where paid && !paysHere:
            return "Part of the price went through. Pay the rest on the web or in another app, then tap Already paid?"
        case _ where paid:
            return "Part of the price went through. Zap the rest to unlock."
        case _ where !paysHere:
            return "Locked by \(authorName) for \(gated.priceSats) sats. Paid on the web or in another app? Tap Already paid? to read it here."
        default: return "Zap \(authorName) \(gated.priceSats) sats to read the full article here."
        }
    }

    /// - Parameter auto: the check that runs on open. It asks the signer only
    ///   when that's silent (a local key) or money has already moved — a
    ///   remote signer would otherwise prompt on every view.
    private func checkAccess(auto: Bool) async {
        // A payment in flight owns the phase; a re-run of this task (the row
        // scrolled away and back) must not hand the pay button back.
        guard phase != .paying, phase != .waiting else { return }
        unpaid = GatedArticleService.shared.unpaidShares(note: note, gated: gated)
        if auto, !paid, !GatedArticleService.shared.canCheckSilently {
            phase = .locked
            return
        }
        phase = .checking
        do {
            phase = .unlocked(try await GatedArticleService.shared.open(note: note, gated: gated))
        } catch {
            guard phase == .checking else { return }
            // Not paid yet is the normal case; anything else still leaves the
            // way to pay open rather than a dead end.
            phase = .locked
        }
    }

    #if !os(iOS)
    private func pay() async {
        guard !busy else { return }
        phase = .paying
        do {
            try await GatedArticleService.shared.pay(note: note, gated: gated)
        } catch {
            unpaid = GatedArticleService.shared.unpaidShares(note: note, gated: gated)
            phase = .failed(paid
                ? "The zap may not have gone through (\(error.localizedDescription)). Check your wallet before paying again — tap Check again if it did."
                : error.localizedDescription)
            return
        }
        unpaid = GatedArticleService.shared.unpaidShares(note: note, gated: gated)
        await waitForKey()
    }
    #endif

    private func waitForKey() async {
        phase = .waiting
        do {
            phase = .unlocked(try await GatedArticleService.shared.waitForKey(note: note, gated: gated))
        } catch GatedArticleService.UnlockError.notPaid {
            phase = .failed("Your zap went through, but the key server hasn't seen the receipt yet. Tap Check again in a minute. It won't charge you again.")
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}
