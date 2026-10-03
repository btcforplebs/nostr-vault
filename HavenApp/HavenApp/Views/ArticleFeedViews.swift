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

                    if let minutes = LongFormMetadata.readingTimeMinutes(for: note.content) {
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
        let plain = MarkdownParser.plainText(note.content, limit: 200)
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
                if let minutes = LongFormMetadata.readingTimeMinutes(for: note.content) {
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
                MarkdownBodyView(markdown: note.content, onImageTap: onImageTap)
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
        let plain = MarkdownParser.plainText(note.content, limit: 200)
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
                            if let minutes = LongFormMetadata.readingTimeMinutes(for: note.content) {
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

                MarkdownBodyView(
                    markdown: note.content,
                    onImageTap: { url in
                        showingMediaUrl = IdentifiableURL(url: url, allURLs: [url])
                    },
                    onHighlight: highlighting ? { text in highlightDraft = HighlightDraft(context: text) } : nil
                )

                Divider()
                actionBar
            }
            .padding(20)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
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
            actionButton(liked ? "heart.fill" : "heart", tint: liked ? .red : .secondary, label: "Like") { like() }
            actionButton("bubble.left", tint: .secondary, label: "Comment") {
                composeContext = ComposeContext(replyTo: note, quoteTo: nil)
            }
            actionButton(zapped ? "bolt.fill" : "bolt", tint: zapped ? .orange : .secondary, label: "Zap") {
                if lightningAddress != nil {
                    zapSheetContext = ZapSheetContext(defaultAmount: ConfigService.shared.config.defaultZapAmount / 1000)
                } else {
                    noLightningAddressAlert = true
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

    private func actionButton(_ symbol: String, tint: Color, label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) { actionIcon(symbol, tint: tint) }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(label))
    }

    private func actionIcon(_ symbol: String, tint: Color) -> some View {
        Image(systemName: symbol)
            .font(.appSystem(size: 15, weight: .medium))
            .foregroundColor(tint)
            .frame(width: 38, height: 34)
            .background(Color.secondary.opacity(0.1))
            .clipShape(Capsule())
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

    private func publishHighlight(passage: String, context: String, comment: String) {
        let relay = ConfigService.shared.config.nostrURL
        let tags = ArticleEngagement.highlightTags(id: note.id, kind: note.kind, pubkey: note.pubkey, tags: note.tags,
                                                   relayHint: relay, passage: passage, context: context, comment: comment)
        let content = passage.trimmingCharacters(in: .whitespacesAndNewlines)
        highlighting = false
        Task {
            _ = try? await ModePostPublisher.publish(kind: ArticleEngagement.highlightKind, content: content,
                                                     tags: tags, nostrService: nostrService)
        }
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

    private var blocks: [MarkdownBlock] { MarkdownParser.parse(markdown) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(blocks) { block in
                switch block {
                case .heading(let level, let text):
                    inlineText(text)
                        .font(.appSystem(size: headingSize(level), weight: .bold))
                        .fixedSize(horizontal: false, vertical: true)
                        .highlightable(text, onHighlight)
                        .padding(.top, level <= 2 ? 8 : 2)

                case .paragraph(let text):
                    inlineText(text)
                        .font(.appSystem(size: 16))
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                        .highlightable(text, onHighlight)

                case .bullet(let text):
                    HStack(alignment: .top, spacing: 8) {
                        Text("•").font(.appSystem(size: 16, weight: .bold)).foregroundColor(.havenPurple)
                        inlineText(text).font(.appSystem(size: 16)).fixedSize(horizontal: false, vertical: true)
                    }
                    .highlightable(text, onHighlight)

                case .ordered(let index, let text):
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(index).")
                            .font(.appSystem(size: 16, weight: .bold))
                            .foregroundColor(.havenPurple)
                            .monospacedDigit()
                        inlineText(text).font(.appSystem(size: 16)).fixedSize(horizontal: false, vertical: true)
                    }
                    .highlightable(text, onHighlight)

                case .quote(let text):
                    HStack(alignment: .top, spacing: 10) {
                        Rectangle().fill(Color.havenPurple).frame(width: 3)
                        inlineText(text)
                            .font(.appSystem(size: 16))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .highlightable(text, onHighlight)

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
    @ViewBuilder
    func highlightable(_ markdown: String, _ onHighlight: ((String) -> Void)?) -> some View {
        if let onHighlight {
            self
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.havenPurple.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
                .onTapGesture { onHighlight(ArticleEngagement.plainText(markdown)) }
        } else {
            self
        }
    }
}
