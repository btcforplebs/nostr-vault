import SwiftUI

/// GIF keyboard backed by getyarn.io: type a quote, get a grid of movie/TV
/// clips, tap one to hand it back to the caller as a `YarnClip`.
struct YarnGifPickerSheet: View {
    var onSelect: (YarnClip) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [YarnClip] = []
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var searchTask: Task<Void, Never>?
    @State private var selectingUUID: String?
    @FocusState private var searchFocused: Bool
    /// Next getyarn page to request. 0-based, incremented once a page lands.
    @State private var nextPage = 0
    /// getyarn returned a short page, so there is nothing further to ask for.
    @State private var reachedEnd = false
    /// How many of `results` the grid is currently showing. Every revealed cell
    /// pulls its own preview GIF from y.yarn.co, so this is the real bandwidth
    /// dial -- a page of 20 costs one HTML request but twenty ~84 KB GIFs.
    @State private var revealed = 0

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 8)]
    /// Cells revealed per step. Deliberately smaller than getyarn's page of 20.
    private let revealStep = 8
    /// Hard ceiling on pages requested per search. getyarn gives no end signal
    /// -- p=99 still answers with a full page of 20 -- so without a cap "show
    /// more" would happily walk a free service forever.
    private let maxPages = 5

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchField
                Divider()
                content
            }
            .navigationTitle("GIFs")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, idealWidth: 640, minHeight: 420, idealHeight: 560)
        #endif
        .onAppear { searchFocused = true }
        .onDisappear { searchTask?.cancel() }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            // Submit only. getyarn.io is a free service with no public API, and
            // an as-you-type search spent a page request plus a fresh grid of
            // preview GIFs on every pause in typing.
            TextField("Search a quote, then press return", text: $query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .submitLabel(.search)
                .onSubmit { runSearch() }
                .onChange(of: query) { _, _ in
                    // Only clear stale results; never fetch.
                    searchTask?.cancel()
                    if query.trimmingCharacters(in: .whitespaces).isEmpty {
                        resetResults()
                    }
                }
            if isSearching {
                ProgressView().controlSize(.small)
            } else if !query.isEmpty {
                Button {
                    query = ""
                    resetResults()
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private var content: some View {
        if let errorMessage {
            placeholder(icon: "exclamationmark.triangle", text: errorMessage)
        } else if results.isEmpty {
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                placeholder(icon: "film", text: "Search movie and TV quotes from getyarn.io")
            } else if !isSearching {
                placeholder(icon: "magnifyingglass", text: "No clips found for \u{201C}\(query)\u{201D}")
            } else {
                Spacer()
            }
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(results.prefix(revealed)) { clip in
                        YarnClipCell(clip: clip, isSelecting: selectingUUID == clip.uuid)
                            .onTapGesture { select(clip) }
                    }
                }
                .padding(12)

                if isSearching {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.bottom, 12)
                } else if canShowMore {
                    Button("Show more clips") { showMore() }
                        .buttonStyle(.plain)
                        .font(.appSystem(size: 13, weight: .medium))
                        .foregroundColor(.havenPurple)
                        .padding(.bottom, 12)
                }

                Text("Clips from getyarn.io")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.bottom, 12)
            }
        }
    }

    private func placeholder(icon: String, text: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 36))
                .foregroundColor(.secondary)
            Text(text)
                .font(.appSystem(size: 14))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    /// More to show without asking getyarn for anything, or another page to ask for.
    private var canShowMore: Bool {
        revealed < results.count || (!reachedEnd && nextPage < maxPages)
    }

    private func resetResults() {
        results = []
        revealed = 0
        nextPage = 0
        reachedEnd = false
        errorMessage = nil
        isSearching = false
    }

    /// Starts a new search from page 0. Only ever called from the return key.
    private func runSearch() {
        searchTask?.cancel()
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            resetResults()
            return
        }
        resetResults()
        fetchNextPage(for: text)
    }

    /// Reveals already-fetched clips first, and only asks getyarn for another
    /// page once the current one is fully on screen.
    private func showMore() {
        if revealed < results.count {
            revealed = min(revealed + revealStep, results.count)
            return
        }
        guard !reachedEnd, !isSearching, nextPage < maxPages else { return }
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        fetchNextPage(for: text)
    }

    private func fetchNextPage(for text: String) {
        let page = nextPage
        errorMessage = nil
        isSearching = true
        searchTask = Task {
            do {
                let clips = try await YarnClipService.search(text, page: page)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    // getyarn never signals the end and does not return a
                    // stable ordering for a repeated query, so a later page can
                    // hand back clips we already hold. Dedupe, and treat an
                    // all-duplicate page as the end.
                    let known = Set(results.map(\.uuid))
                    let fresh = clips.filter { !known.contains($0.uuid) }
                    results.append(contentsOf: fresh)
                    reachedEnd = fresh.isEmpty
                    nextPage = page + 1
                    revealed = min(revealed + revealStep, results.count)
                    isSearching = false
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isSearching = false
                }
            }
        }
    }

    private func select(_ clip: YarnClip) {
        guard selectingUUID == nil else { return }
        selectingUUID = clip.uuid
        onSelect(clip)
        dismiss()
    }
}

private struct YarnClipCell: View {
    let clip: YarnClip
    let isSelecting: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack {
                Color.platformSecondaryGroupedBackground
                AnimatedImage(url: clip.gifSmallURL, contentMode: .fill, fallbackURL: clip.thumbURL)
                if isSelecting {
                    Color.black.opacity(0.4)
                    ProgressView().tint(.white)
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            Text(clip.transcript)
                .font(.appSystem(size: 12, weight: .medium))
                .lineLimit(2)
            Text(clip.videoTitle)
                .font(.appSystem(size: 11))
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
        .help(clip.transcript)
    }
}
