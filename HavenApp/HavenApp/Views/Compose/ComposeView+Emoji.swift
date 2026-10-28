import SwiftUI

/// Custom emoji (NIP-30) in the composer: `:name` suggestions and the
/// post's `emoji` tags. Android: `ComposeNoteViewModelEmoji.kt`.
extension ComposeView {
    /// One strip of custom emoji for the `:name` being typed, like `mentionPopup`.
    var emojiPopup: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(emojiSuggestions, id: \.shortcode) { emoji in
                    Button { insertEmojiSuggestion(emoji) } label: {
                        HStack(spacing: 8) {
                            CustomEmojiImage(emoji: emoji, size: 28)
                            Text(emoji.content)
                                .font(.appSystem(size: 14, weight: .semibold))
                                .foregroundColor(.primary)
                                .lineLimit(1)
                                .frame(maxWidth: 160, alignment: .leading)
                        }
                        .padding(.leading, 6)
                        .padding(.trailing, 12)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.havenPurple.opacity(0.1)))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Insert \(emoji.content)")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
        .background(Color.platformSecondaryGroupedBackground)
        .overlay(alignment: .top) { Divider() }
        .transition(.opacity)
    }

    /// Every custom emoji the account can use: recents first, then its own emoji and sets.
    func knownCustomEmoji() -> [CustomEmoji] {
        let state = EmojiPaletteStore.shared.state
        let library = EmojiListService.shared.library
        return (state.recents + state.slots).compactMap(\.custom) + library.single + library.sets.flatMap(\.emojis)
    }

    /// Finds the `:name` at the caret after an edit and fills `emojiSuggestions`.
    func updateEmojiQuery(old: String, new text: String) {
        let caret = text.distance(from: text.startIndex, to: caretIndex(old: old, new: text))
        let query = ComposeEmoji.query(in: text, caret: caret)
        emojiQuery = query
        emojiSuggestions = query.map { ComposeEmoji.suggestions($0.text, known: knownCustomEmoji()) } ?? []
    }

    /// Replaces the active `:name` with `emoji`.
    func insertEmojiSuggestion(_ emoji: CustomEmoji) {
        guard let query = emojiQuery else { return }
        let out = ComposeEmoji.insert(emoji, replacing: query, in: content)
        EmojiPaletteStore.shared.recordUse(ReactionPick(emoji))
        emojiQuery = nil
        emojiSuggestions = []
        content = out.text
    }

    /// The `emoji` tags for the custom emoji `text` uses (images the account knows).
    @MainActor
    func customEmojiTags(for text: String) -> [[String]] {
        var known: [String: CustomEmoji] = [:]
        for emoji in knownCustomEmoji() where known[emoji.shortcode] == nil { known[emoji.shortcode] = emoji }
        return ComposeEmoji.tags(for: text, known: known)
    }
}
