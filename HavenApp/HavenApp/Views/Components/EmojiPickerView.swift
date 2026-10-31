import SwiftUI

/// The emoji picker sheet: search on top, then one scrolling grid (Recents,
/// Your emoji, each pack, then every Unicode emoji) with a jump strip at the
/// bottom that follows the scroll. Reacting (`init(onSelect:)`) adds the
/// editable quick bar and custom emoji; choosing the default reaction
/// (`init(onSelectEmoji:)`) offers Unicode only.
/// Opens at half height on iPhone; pull up for full. Emoji data: `EmojiCatalog`.
/// Android: `EmojiPickerSheet.kt`.
struct EmojiPickerView: View {
    @Environment(\.dismiss) private var dismiss
    private let reacting: Bool
    private let onSelect: (ReactionPick) -> Void

    @ObservedObject private var palette = EmojiPaletteStore.shared
    @ObservedObject private var emojiList = EmojiListService.shared
    private let catalog = EmojiCatalog.shared

    @State private var searchText = ""
    /// The section at the top of the grid; setting it scrolls there.
    @State private var visibleSection: Int?
    // Editing the quick bar: tap a slot, then any emoji to put there.
    @State private var editingBar = false
    @State private var editSlot: ReactionPick?

    /// Reacting to a note: custom emoji and the quick bar included.
    init(onSelect: @escaping (ReactionPick) -> Void) {
        reacting = true
        self.onSelect = onSelect
    }

    /// Choosing an emoji (the default reaction): Unicode only.
    init(onSelectEmoji: @escaping (String) -> Void) {
        reacting = false
        onSelect = { onSelectEmoji($0.content) }
    }

    private let columns = [GridItem(.adaptive(minimum: 40, maximum: 48), spacing: 4)]

    private var tabs: [EmojiPickerTabs.Tab] {
        EmojiPickerTabs.build(categories: catalog.tabs, palette: palette.state, library: emojiList.library, reacting: reacting)
    }

    private var searching: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        let tabs = tabs
        VStack(spacing: 0) {
            searchField
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 8)

            if reacting && !searching {
                QuickBarRow(
                    bar: EmojiPalette.orderedBar(palette.state),
                    editing: editingBar,
                    editSlot: editSlot,
                    onToggleEdit: { editingBar.toggle(); editSlot = nil },
                    onSlot: { slot in if editingBar { editSlot = slot } else { selectEmoji(slot) } }
                )
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }

            Divider()

            if searching {
                searchResults(catalog.results(searchText, tabs: tabs, custom: reacting))
            } else {
                sectionGrid(tabs)
                Divider()
                jumpStrip(tabs)
            }
        }
        #if os(macOS)
        .frame(width: 380, height: 460)
        #endif
        .onAppear { if reacting { EmojiListService.shared.refresh() } }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search emoji", text: $searchText)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                #endif
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.platformTertiaryGroupedBackground, in: RoundedRectangle(cornerRadius: 10))
    }

    /// One scrolling grid, a small header per section.
    private func sectionGrid(_ tabs: [EmojiPickerTabs.Tab]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(Array(tabs.enumerated()), id: \.offset) { index, tab in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(tab.name)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                        grid(tab.picks)
                    }
                    .id(index)
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .scrollPosition(id: $visibleSection, anchor: .top)
    }

    private func searchResults(_ results: [ReactionPick]) -> some View {
        ScrollView {
            if results.isEmpty {
                Text("No emoji found")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                grid(results)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            }
        }
        .scrollDismissesKeyboard(.immediately)
    }

    private func grid(_ picks: [ReactionPick]) -> some View {
        LazyVGrid(columns: columns, spacing: 4) {
            ForEach(Array(picks.enumerated()), id: \.offset) { _, pick in
                Button { selectEmoji(pick) } label: {
                    ReactionGlyph(pick, fontSize: 28)
                        .frame(width: 44, height: 44)
                        // A clear background is not a hit area; the corners were dead on the Mac.
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(pick.shortcode.map { ":\($0):" } ?? catalog.names[pick.content] ?? pick.content)
                #if os(iOS)
                .hoverEffect(.highlight)
                #endif
            }
        }
    }

    /// Section icons; tap to jump, the current one is highlighted as you scroll.
    private func jumpStrip(_ tabs: [EmojiPickerTabs.Tab]) -> some View {
        let current = visibleSection ?? 0
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(Array(tabs.enumerated()), id: \.offset) { index, tab in
                    Button {
                        withAnimation(.easeInOut(duration: 0.25)) { visibleSection = index }
                    } label: {
                        Group {
                            if let symbol = tab.symbol {
                                Image(systemName: symbol).font(.system(size: 16))
                            } else if let icon = tab.icon {
                                ReactionGlyph(icon, fontSize: 16)
                            }
                        }
                        .frame(width: 34, height: 30)
                        .foregroundStyle(index == current ? Color.havenPurple : Color.secondary)
                        .background(index == current ? Color.havenPurple.opacity(0.15) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(tab.name)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }

    private func selectEmoji(_ pick: ReactionPick) {
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        #endif

        // Editing the quick bar: the pick goes in the chosen slot, the sheet stays.
        if editingBar, let slot = editSlot {
            palette.replaceSlot(slot, with: pick)
            editSlot = nil
            return
        }
        onSelect(pick)
        dismiss()
    }
}
