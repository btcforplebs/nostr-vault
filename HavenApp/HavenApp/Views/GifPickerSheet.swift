import SwiftUI

/// GIF keyboard with two sources: getyarn.io for captioned movie and TV
/// quotes, Tenor for everything else. Type a search, get a grid, tap one to
/// hand it back to the caller as a `GifItem`.
struct GifPickerSheet: View {
    var onSelect: (GifItem) -> Void

    /// Everything a single source remembers between switches. Held per source
    /// so flipping back and forth does not re-fetch a page of previews that is
    /// already on screen -- the expensive part of this sheet is the grid of
    /// animated GIFs, not the search request.
    private struct SourceState {
        /// The query these results answer. A mismatch with the field means
        /// they are stale and the source needs to search again.
        var query = ""
        var items: [GifItem] = []
        var revealed = 0
        var nextPage = 0
        var reachedEnd = false
        var errorMessage: String?
        /// A request for `query` has come back. Until it has, an empty grid
        /// means "nothing asked for yet", not "nothing found" -- the search
        /// runs on return, so the field is full long before the grid is.
        var hasSearched = false
    }

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var source: GifSource = .yarn
    @State private var states: [GifSource: SourceState] = [:]
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?
    @State private var selectingID: String?
    @FocusState private var searchFocused: Bool
    @Namespace private var sourcePill

    // Rough type metrics for the column-balancing estimate, scaled so the
    // estimate tracks Dynamic Type the way the real caption does.
    @ScaledMetric(relativeTo: .footnote) private var captionLineHeight: Double = 15
    @ScaledMetric(relativeTo: .caption2) private var subcaptionLineHeight: Double = 13
    @ScaledMetric(relativeTo: .footnote) private var captionBlockPadding: Double = 16
    /// Cells revealed per step. Deliberately smaller than either source's page
    /// -- getyarn returns 20, Tenor 50 -- because every revealed cell pulls its
    /// own preview GIF.
    private let revealStep = 8
    /// Hard ceiling on pages requested per search, for sources that page at
    /// all. getyarn gives no end signal -- p=99 still answers with a full page
    /// -- so without a cap "show more" would walk a free service forever.
    private let maxPages = 5

    private var state: SourceState { states[source] ?? SourceState() }
    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                searchField
                sourcePicker
                content
            }
            .background(Color.platformSecondaryGroupedBackground)
            #if os(iOS)
            .navigationBarHidden(true)
            #endif
        }
        #if os(macOS)
        .frame(minWidth: 520, idealWidth: 640, minHeight: 420, idealHeight: 560)
        #endif
        .onAppear { searchFocused = true }
        .onDisappear { searchTask?.cancel() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "film.fill")
                .font(.appSystem(size: 16, weight: .bold))
                .foregroundColor(.havenPurple)

            Text("GIFs")
                .font(.appSystem(size: 18, weight: .bold, design: .rounded))

            Spacer()

            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.appSystem(size: 22))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 10)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.appSystem(size: 14, weight: .semibold))
                .foregroundColor(searchFocused ? .havenPurple : .secondary)
            // Submit only. Both sources are free services being read through
            // their own web pages, and an as-you-type search spent a page
            // request plus a fresh grid of preview GIFs on every pause.
            TextField(source.fieldPrompt, text: $query)
                .textFieldStyle(.plain)
                .font(.appSystem(size: 15))
                .focused($searchFocused)
                .submitLabel(.search)
                .onSubmit { runSearch() }
                .onChange(of: query) { _, _ in
                    // Only clear stale results; never fetch.
                    searchTask?.cancel()
                    isSearching = false
                    if trimmedQuery.isEmpty { states = [:] }
                }
            if isSearching {
                ProgressView().controlSize(.small)
            } else if !query.isEmpty {
                Button {
                    query = ""
                    states = [:]
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.platformTertiaryGroupedBackground)
        .clipShape(Capsule())
        .overlay(
            Capsule().stroke(searchFocused ? Color.havenPurple.opacity(0.6) : Color.platformSeparator, lineWidth: searchFocused ? 1.5 : 0.8)
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
        .animation(.easeOut(duration: 0.15), value: searchFocused)
    }

    /// Scope bar under the field, the way a search scope reads on both
    /// platforms. 44pt overall so a segment is a real tap target rather than
    /// the 32pt a stock segmented control would give.
    private var sourcePicker: some View {
        HStack(spacing: 0) {
            ForEach(GifSource.allCases) { candidate in
                Button {
                    switchTo(candidate)
                } label: {
                    Text(candidate.title)
                        .font(.appSystem(size: 13, weight: .semibold))
                        .foregroundColor(candidate == source ? .white : .secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                        .background {
                            if candidate == source {
                                Capsule()
                                    .fill(Color.havenPurple)
                                    .matchedGeometryEffect(id: "gifSourcePill", in: sourcePill)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(candidate == source ? [.isButton, .isSelected] : .isButton)
                .accessibilityHint(candidate == source ? "" : "Search \(candidate.title) instead")
            }
        }
        .padding(3)
        .background(Color.platformTertiaryGroupedBackground)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Color.platformSeparator, lineWidth: 0.8))
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: source)
    }

    @ViewBuilder
    private var content: some View {
        if let errorMessage = state.errorMessage {
            placeholder(icon: "exclamationmark.triangle", text: errorMessage)
                .frame(maxHeight: .infinity)
        } else if state.items.isEmpty {
            if isSearching {
                searchingPlaceholder
                    .frame(maxHeight: .infinity)
            } else if state.hasSearched && !trimmedQuery.isEmpty {
                placeholder(icon: "film", text: source.noResults(for: trimmedQuery))
                    .frame(maxHeight: .infinity)
            } else {
                placeholder(icon: "quote.bubble", text: source.searchPrompt)
                    .frame(maxHeight: .infinity)
            }
        } else {
            GeometryReader { geo in
                ScrollView {
                    masonry(availableWidth: Double(geo.size.width) - 32)
                        .padding(.horizontal, 16)
                        .padding(.top, 4)

                    if isSearching {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.havenPurple)
                            .padding(.top, 16)
                            .padding(.bottom, 12)
                    } else if canShowMore {
                        Button {
                            showMore()
                        } label: {
                            HStack(spacing: 6) {
                                Text(source.moreLabel)
                                Image(systemName: "chevron.down")
                            }
                            .font(.appSystem(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 9)
                            .background(Color.havenPurple)
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 16)
                        .padding(.bottom, 12)
                    }

                    Text(source.attribution)
                        .font(.appCaption2)
                        .foregroundColor(.secondary)
                        .padding(.bottom, 14)
                }
            }
        }
    }

    /// Waterfall grid, not a `LazyVGrid`: cells differ in height -- a Tenor GIF
    /// takes its own shape and a captioned clip carries a caption of its own
    /// depth -- and a row-based grid sizes each row to its tallest cell, which
    /// leaves a hole under every shorter one. Columns are filled shortest-first
    /// so the cells tile instead.
    ///
    /// Building every revealed cell up front, rather than lazily, is affordable
    /// because `revealStep` is what bounds the count: nothing is on screen that
    /// the reader has not asked to see.
    private func masonry(availableWidth: Double) -> some View {
        let width = max(0, availableWidth)
        let columnCount = GifGridLayout.columnCount(forWidth: width)
        let columnWidth = GifGridLayout.columnWidth(forWidth: width, columns: columnCount)
        let buckets = GifGridLayout.distribute(
            Array(state.items.prefix(state.revealed)),
            columns: columnCount
        ) { estimatedHeight(for: $0, columnWidth: columnWidth) }

        return HStack(alignment: .top, spacing: GifGridLayout.spacing) {
            ForEach(Array(buckets.enumerated()), id: \.offset) { _, bucket in
                VStack(spacing: GifGridLayout.spacing) {
                    ForEach(bucket) { item in
                        GifResultCell(item: item, isSelecting: selectingID == item.id)
                            .onTapGesture { select(item) }
                    }
                }
                .frame(width: columnWidth)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// What a cell is likely to measure, used only to balance the columns.
    /// SwiftUI still lays each cell out at whatever its content needs, so an
    /// estimate a few points out costs an uneven column bottom and nothing more.
    private func estimatedHeight(for item: GifItem, columnWidth: Double) -> Double {
        let ratio = item.aspectRatio > 0.05 ? item.aspectRatio : 1
        var height = columnWidth / ratio
        if let caption = item.caption, !caption.isEmpty {
            height += captionHeight(caption, subcaption: item.subcaption, width: columnWidth)
        }
        return height
    }

    private func captionHeight(_ caption: String, subcaption: String?, width: Double) -> Double {
        // Deliberately rough: about 0.55em per character at 12pt, and never
        // more than the two lines the label is clamped to.
        let charsPerLine = max(8, width / (12 * 0.55))
        let lines = min(2, max(1, (Double(caption.count) / charsPerLine).rounded(.up)))
        var height = captionBlockPadding + lines * captionLineHeight
        if let subcaption, !subcaption.isEmpty { height += subcaptionLineHeight }
        return height
    }

    private var searchingPlaceholder: some View {
        VStack {
            Spacer()
            ProgressView()
                .controlSize(.large)
                .tint(.havenPurple)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .accessibilityLabel("Searching")
    }

    private func placeholder(icon: String, text: String) -> some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: icon)
                .font(.appSystem(size: 40, weight: .thin))
                .foregroundColor(.havenPurple.opacity(0.6))
            Text(text)
                .font(.appSystem(size: 14, weight: .medium))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    /// More to show without asking the source for anything, or -- where the
    /// source pages -- another page to ask for.
    private var canShowMore: Bool {
        if state.revealed < state.items.count { return true }
        return source.supportsPaging && !state.reachedEnd && state.nextPage < maxPages
    }

    // MARK: - Searching

    /// Switches scope, keeping the typed query. The new source searches only
    /// if what it is holding does not already answer that query.
    private func switchTo(_ newSource: GifSource) {
        guard newSource != source else { return }
        searchTask?.cancel()
        isSearching = false
        source = newSource
        guard !trimmedQuery.isEmpty else { return }
        if states[newSource]?.query != trimmedQuery {
            states[newSource] = SourceState(query: trimmedQuery)
            fetchNextPage()
        }
    }

    /// Starts a new search for the current source. Only ever called from the
    /// return key.
    private func runSearch() {
        searchTask?.cancel()
        isSearching = false
        guard !trimmedQuery.isEmpty else {
            states = [:]
            return
        }
        // Other sources keep their results; they are re-checked against the
        // query when the scope is switched.
        states[source] = SourceState(query: trimmedQuery)
        fetchNextPage()
    }

    /// Reveals already-fetched items first, and only asks the source for
    /// another page once the current one is fully on screen.
    private func showMore() {
        if state.revealed < state.items.count {
            states[source]?.revealed = min(state.revealed + revealStep, state.items.count)
            return
        }
        guard source.supportsPaging, !state.reachedEnd, !isSearching, state.nextPage < maxPages else { return }
        guard !trimmedQuery.isEmpty else { return }
        fetchNextPage()
    }

    private func fetchNextPage() {
        let requested = source
        let text = trimmedQuery
        let page = states[requested]?.nextPage ?? 0
        states[requested]?.errorMessage = nil
        isSearching = true
        searchTask = Task {
            do {
                let items: [GifItem]
                switch requested {
                case .yarn:
                    items = try await YarnClipService.search(text, page: page).map(GifItem.init)
                case .tenor:
                    items = try await TenorGifService.search(text).map(GifItem.init)
                }
                guard !Task.isCancelled else { return }
                await MainActor.run { apply(items, for: requested, page: page, query: text) }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    states[requested]?.errorMessage = error.localizedDescription
                    states[requested]?.hasSearched = true
                    if source == requested { isSearching = false }
                }
            }
        }
    }

    @MainActor
    private func apply(_ items: [GifItem], for requested: GifSource, page: Int, query text: String) {
        // The field may have moved on while the request was in flight.
        guard states[requested]?.query == text else { return }
        // A later getyarn page can hand back clips we already hold -- it never
        // signals the end and does not order a repeated query stably. Dedupe,
        // and treat an all-duplicate page as the end. Tenor answers once, so
        // its end is simply the page it gave us.
        states[requested]?.hasSearched = true
        let known = Set(states[requested]?.items.map(\.id) ?? [])
        let fresh = items.filter { !known.contains($0.id) }
        states[requested]?.items.append(contentsOf: fresh)
        states[requested]?.reachedEnd = !requested.supportsPaging || fresh.isEmpty
        states[requested]?.nextPage = page + 1
        let total = states[requested]?.items.count ?? 0
        states[requested]?.revealed = min((states[requested]?.revealed ?? 0) + revealStep, total)
        if source == requested { isSearching = false }
    }

    private func select(_ item: GifItem) {
        guard selectingID == nil else { return }
        selectingID = item.id
        onSelect(item)
        dismiss()
    }
}

private struct GifResultCell: View {
    let item: GifItem
    let isSelecting: Bool

    private var caption: String? {
        guard let caption = item.caption, !caption.isEmpty else { return nil }
        return caption
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                Color.platformTertiaryGroupedBackground
                AnimatedImage(url: item.previewURL, contentMode: .fill, fallbackURL: item.stillURL)

                if isSelecting {
                    Color.black.opacity(0.55)
                    ProgressView().tint(.white)
                }
            }
            // Each source has its own shape -- getyarn clips are 16:9, Tenor
            // GIFs are anything -- so the art takes the item's ratio instead of
            // cropping everything into one frame.
            .aspectRatio(CGFloat(item.aspectRatio), contentMode: .fit)
            .clipped()

            // Under the art, not over it. A getyarn transcript is the reason to
            // pick the clip, so it is content rather than an overlay: laid over
            // the frame it competed with the art at two lines, needed a scrim to
            // stay legible, and covered the part of the picture it was quoting.
            if let caption {
                VStack(alignment: .leading, spacing: 2) {
                    Text(caption)
                        .font(.appSystem(size: 12, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if let subcaption = item.subcaption, !subcaption.isEmpty {
                        Text(subcaption)
                            .font(.appSystem(size: 10, weight: .medium))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color.platformTertiaryGroupedBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.platformSeparator, lineWidth: 0.8)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .help(item.accessibilityText)
        // A caption is clamped to two lines and one, so the rendered text is
        // not the whole of it, and a Tenor cell renders no text at all. Read
        // the full description out either way.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(item.accessibilityText))
        .accessibilityAddTraits(.isButton)
    }
}
