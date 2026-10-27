import Foundation
import Combine

/// `EmojiPalette.State` saved on this device (UserDefaults). Never published.
/// Android: `data/local/EmojiPaletteStore.kt`.
@MainActor
final class EmojiPaletteStore: ObservableObject {
    static let shared = EmojiPaletteStore()

    @Published private(set) var state: EmojiPalette.State

    private static let key = "emojiPalette.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode(EmojiPalette.State.self, from: data) {
            state = EmojiPalette.normalized(saved)
        } else {
            state = EmojiPalette.State()
        }
    }

    /// `pick` was chosen to react with: recents and the bar's order learn from it.
    func recordUse(_ pick: ReactionPick) { save(EmojiPalette.recordUse(state, pick)) }

    /// Puts `pick` on the quick bar where `replacing` was.
    func replaceSlot(_ replacing: ReactionPick, with pick: ReactionPick) {
        save(EmojiPalette.replaceSlot(state, replacing: replacing, with: pick))
    }

    /// The image for a `:shortcode:` the account reacted with, when it knows one.
    func custom(forContent content: String) -> CustomEmoji? {
        guard let shortcode = CustomEmoji.loneShortcode(content) else { return nil }
        if let known = (state.recents + state.slots).first(where: { $0.shortcode == shortcode })?.custom { return known }
        let library = EmojiListService.shared.library
        return (library.single + library.sets.flatMap(\.emojis)).first { $0.shortcode == shortcode }
    }

    private func save(_ next: EmojiPalette.State) {
        state = next
        if let data = try? JSONEncoder().encode(next) { defaults.set(data, forKey: Self.key) }
    }
}
