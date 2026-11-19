import SwiftUI

/// A pinned list or relay's notes, opened from the iPad rail. Rows push their
/// thread, as in the hashtag feed.
struct PinFeedView: View {
    let pin: SpaceLayout.Pin
    @EnvironmentObject var nostrService: NostrService
    @EnvironmentObject var configService: ConfigService
    @ObservedObject private var feedService = FeedService.shared
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: PinFeedModel
    @State private var path = NavigationPath()
    @State private var showingProfile: IdentifiableString?
    @State private var showingMediaUrl: IdentifiableURL?
    @State private var composeContext: ComposeContext?
    @Namespace private var mediaZoom

    init?(pin: SpaceLayout.Pin) {
        guard let source = PinFeedModel.source(for: pin.kind) else { return nil }
        self.pin = pin
        _model = StateObject(wrappedValue: PinFeedModel(source: source))
    }

    private var isRelay: Bool { if case .relay = model.source { return true } else { return false } }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(spacing: 12) {
                    header
                    if model.notes.isEmpty { emptyState }
                    ForEach(model.notes) { row($0) }
                }
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .environment(\.feedActions, .make(feedService: feedService, nostrService: nostrService))
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
            .navigationDestination(for: FeedNote.self) { NoteDetailView(note: $0) }
            .navigationDestination(for: NotificationNoteRoute.self) { NoteDetailViewWrapper(noteId: $0.id, pushed: true) }
        }
        .environment(\.pushNoteID, PushNoteAction(stack: "pin-\(pin.id)") { path.pushNote(id: $0) })
        .hashtagLinks()
        .task { model.start() }
        .onDisappear { model.stop() }
        .sheet(item: $showingProfile) { profile in
            ProfileView(pubkey: profile.id, onDismiss: { showingProfile = nil })
                .environmentObject(nostrService)
                .environmentObject(configService)
        }
        .mediaViewer(item: $showingMediaUrl, namespace: mediaZoom)
        .sheet(item: $composeContext) { ctx in
            ComposeView(onDismiss: { composeContext = nil }, replyTo: ctx.replyTo, quoteTo: ctx.quoteTo)
                .environmentObject(nostrService)
                .environmentObject(configService)
        }
    }

    /// A repost is answered on the note it reposts, as in the feed.
    private func reply(to note: FeedNote) {
        if note.kind == 6, let refId = note.repostedEventId, let original = feedService.findNote(id: refId) {
            composeContext = ComposeContext(replyTo: original, quoteTo: nil)
        } else {
            composeContext = ComposeContext(replyTo: note, quoteTo: nil)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: RailPin.symbol(pin.kind))
                .font(.appSystem(size: 20, weight: .semibold))
                .foregroundColor(.accentText)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.title ?? pin.name ?? RailPin.fallbackLabel(pin.kind))
                    .font(.appTitle2)
                    .lineLimit(1)
                if isRelay, case .relay(let url) = model.source {
                    Text(url).font(.appCaption).foregroundColor(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 10) {
            if model.isLoading {
                ProgressView()
            } else {
                Text(model.problem ?? (isRelay ? "Nothing from your web on this relay yet" : "No posts from this list yet"))
                    .font(.appSubheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.top, 60)
    }

    private func row(_ note: FeedNote) -> some View {
        FeedNoteRow(
            note: note,
            profile: nostrService.profiles[note.pubkey],
            rowData: FeedNoteRowData.resolve(for: note, feedService: feedService, nostrService: nostrService),
            onReply: { reply(to: note) },
            onQuote: { composeContext = ComposeContext(replyTo: nil, quoteTo: feedService.quoteTarget(for: note)) },
            onProfile: { showingProfile = IdentifiableString(id: $0) },
            onMedia: { url, urls in showingMediaUrl = IdentifiableURL(url: url, allURLs: urls) },
            showParent: false
        )
        .contentShape(Rectangle())
        .onTapGesture { path.pushNote(note) }
        .padding(.horizontal, 16)
        .onAppear { nostrService.fetchMissingProfiles(for: [note.pubkey]) }
    }
}
