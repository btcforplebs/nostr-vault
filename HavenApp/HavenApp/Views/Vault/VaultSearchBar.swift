import SwiftUI

// MARK: - Search bar

/// The Vault's search field. It opens out of the magnifying glass at the top
/// right: a circle on the trailing edge that widens into the bar, then the
/// field fades in. The ✕ where the icon was (or Escape on the Mac) folds it
/// back into the circle before `onClose` runs, so the icon is what's left when it goes.
///
/// Laid out at full width from the start; only the glass and its mask move,
/// as in `ChromeMorphCapsule`, so nothing around it relayouts mid-animation.
struct VaultSearchBar: View {
    @Binding var text: String
    var onSubmit: () -> Void = {}
    /// Runs once the bar has folded back into the icon.
    let onClose: () -> Void

    /// 0 is the icon's circle on the trailing edge, 1 the full bar.
    @State private var progress: CGFloat = 0
    @State private var size: CGSize = .zero
    @FocusState private var focused: Bool

    private static let height: CGFloat = 40

    var body: some View {
        let width: CGFloat? = size == .zero ? nil : Self.height + (size.width - Self.height) * progress
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                TextField("Search your Vault", text: $text)
                    .textFieldStyle(.plain)
                    .font(.appSystem(size: 16))
                    .focused($focused)
                    .submitLabel(.search)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                    .onSubmit(onSubmit)
                    .accessibilityLabel("Search your Vault")

                if !text.isEmpty {
                    Button { text = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.appSystem(size: 16))
                            .foregroundColor(.secondary)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .opacity(progress)

            // Where the toolbar's magnifying glass was: the bar grows out of
            // it, and open, the same spot is the ✕ that folds it back.
            Button(action: close) {
                ZStack {
                    Image(systemName: "magnifyingglass")
                        .opacity(1 - progress)
                    Image(systemName: "xmark")
                        .opacity(progress)
                }
                .font(.appSystem(size: 15, weight: .semibold))
                .foregroundColor(.havenPurple)
                .frame(width: Self.height, height: Self.height)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close search")
        }
        .padding(.leading, 16)
        .frame(height: Self.height)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        .mask(alignment: .trailing) { Capsule().frame(width: width) }
        .background(alignment: .trailing) {
            // Solid, not clear glass: on the black Vault the glass was
            // invisible until the bar was nearly open, so the growth from
            // the icon never read.
            Capsule()
                .fill(Color.platformTertiaryGroupedBackground)
                .overlay(Capsule().stroke(Color.platformSeparator, lineWidth: 0.8))
                .frame(width: width)
        }
        .onAppear(perform: open)
        #if os(macOS)
        .onExitCommand(perform: close)
        #endif
    }

    private func open() {
        withAnimation(Motion.expand) { progress = 1 }
        // Focus once the field is mostly in: focusing at once raises the
        // keyboard over a bar that is still a circle.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { focused = true }
    }

    private func close() {
        focused = false
        withAnimation(Motion.expand) {
            progress = 0
        } completion: {
            onClose()
        }
    }
}

// MARK: - Search model

/// Runs the Vault's search against the local relay — the same
/// `localRelaySearch` the Search tab's Relay mode used, widened to the kinds
/// the Vault holds — and turns its matches into the result sections.
@MainActor
final class VaultSearchModel: ObservableObject {
    struct Results {
        var people: [FeedProfile] = []
        var notes: [FeedNote] = []
        var hashtags: [String] = []
        var links: [VaultSearchLogic.Link] = []

        func count(_ section: VaultSearchLogic.Section) -> Int {
            switch section {
            case .people: return people.count
            case .notes, .articles, .media: return notes(in: section).count
            case .hashtags: return hashtags.count
            case .links: return links.count
            }
        }

        func notes(in section: VaultSearchLogic.Section) -> [FeedNote] {
            notes.filter { VaultSearchLogic.section(forKind: $0.kind) == section }
        }

        var isEmpty: Bool { people.isEmpty && notes.isEmpty && hashtags.isEmpty && links.isEmpty }
    }

    typealias Status = VaultSearchLogic.Status

    /// Notes, articles, highlights, comments, polls and media. Reposts are
    /// left out: their content is the reposted event's JSON.
    static let noteKinds: [Int] = NostrService.relayTabNoteKinds.filter { $0 != 6 }
        + VaultSearchLogic.mediaKinds.sorted()

    @Published private(set) var results = Results()
    @Published private(set) var state = VaultSearchLogic.QueryState()

    var status: Status { state.status }
    /// The query the results are for.
    var resultsQuery: String { state.resultsQuery }

    private var pending: Task<Void, Never>?

    /// Searches `query` after a short pause, so typing does not start a walk
    /// of the whole store per keystroke. `now` skips the pause (Return).
    func search(_ query: String, now: Bool = false,
                nostrService: NostrService, feedService: FeedService, blocked: Set<String>) {
        pending?.cancel()
        pending = nil
        switch state.typed(query) {
        case .clear:
            nostrService.cancelLocalRelaySearch()
            results = Results()
        case .keep:
            // Whatever is still walking is for a query the field has left.
            nostrService.cancelLocalRelaySearch()
        case .run(let trimmed):
            pending = Task { [weak self] in
                if !now { try? await Task.sleep(for: .milliseconds(300)) }
                guard !Task.isCancelled, let self else { return }
                self.run(trimmed, nostrService: nostrService, feedService: feedService, blocked: blocked)
            }
        }
    }

    func cancel(nostrService: NostrService) {
        pending?.cancel()
        pending = nil
        nostrService.cancelLocalRelaySearch()
        results = Results()
        state.reset()
    }

    private func run(_ query: String, nostrService: NostrService, feedService: FeedService, blocked: Set<String>) {
        guard state.started(query) else { return }
        guard let relayURL = feedService.localRelayURL else {
            // The relay is still starting: search what the app has loaded
            // rather than show nothing.
            runInMemory(query, nostrService: nostrService, feedService: feedService, blocked: blocked)
            return
        }
        nostrService.localRelaySearch(query: query, relayURL: relayURL,
                                      noteKinds: Self.noteKinds, allTerms: true) { [weak self] found in
            guard let self else { return }
            self.land(query, profiles: found.profiles, notes: found.notes,
                      as: found.isCutShort ? .cutShort : .done,
                      feedService: feedService, blocked: blocked)
        }
    }

    /// The relay-down fallback: the same matching over the profiles, Vault
    /// events and feed notes already in memory.
    private func runInMemory(_ query: String, nostrService: NostrService, feedService: FeedService, blocked: Set<String>) {
        guard let matcher = LocalSearchMatcher(allTermsOf: query) else { return }
        let kinds = Set(Self.noteKinds)
        let profiles = Array(nostrService.profiles.values)
        let events = nostrService.events
        let feedNotes = feedService.notes
        Task.detached(priority: .userInitiated) { [weak self] in
            let people = profiles.filter {
                matcher.matchesProfile(displayName: $0.displayName, name: $0.name, about: $0.about,
                                       nip05: $0.nip05, pubkey: $0.pubkey)
            }
            var seen = Set<String>()
            var notes: [FeedNote] = []
            for event in events where kinds.contains(event.kind)
                && matcher.matchesNote(content: event.content, tags: event.tags)
                && seen.insert(event.id).inserted {
                notes.append(FeedNote(id: event.id, pubkey: event.pubkey, content: event.content,
                                      createdAt: event.createdAtDate, tags: event.tags, kind: event.kind))
            }
            for note in feedNotes where kinds.contains(note.kind)
                && matcher.matchesNote(content: note.content, tags: note.tags)
                && seen.insert(note.id).inserted {
                notes.append(note)
            }
            notes.sort { $0.createdAt > $1.createdAt }
            await self?.land(query, profiles: people, notes: notes, as: .inMemory,
                             feedService: feedService, blocked: blocked)
        }
    }

    private func land(_ query: String, profiles: [FeedProfile], notes found: [FeedNote], as result: Status,
                      feedService: FeedService, blocked: Set<String>) {
        guard state.landed(query, as: result) else { return }
        let filter = SearchBlockFilter(blocked: blocked)
        let people = filter.profiles(profiles, pubkey: \.pubkey)
        let notes = filter.notes(found) { note, blocked in
            FeedFilterEngine.involvesBlocked(note, blocked: blocked,
                                             authorOf: { feedService.findNote(id: $0)?.pubkey })
        }
        let follows = Set(feedService.followedPubkeys)
        var results = Results()
        // People you follow first, then by name.
        results.people = people.sorted {
            let a = follows.contains($0.pubkey), b = follows.contains($1.pubkey)
            if a != b { return a }
            return $0.bestName.localizedCaseInsensitiveCompare($1.bestName) == .orderedAscending
        }
        results.notes = notes
        results.hashtags = VaultSearchLogic.hashtags(contents: notes.map { ($0.content, $0.tags) }, query: query)
        results.links = VaultSearchLogic.links(notes: notes.map { ($0.id, $0.content) })
        self.results = results
    }
}
