import Foundation

/// One emoji the person can react with: Unicode (`custom` nil, `content` the
/// emoji) or a NIP-30 custom emoji (`content` its `:shortcode:`).
/// Android: `data/local/EmojiPalette.kt`.
struct ReactionPick: Codable, Hashable {
    let content: String
    var shortcode: String?
    var url: String?
    var setAddress: String?

    init(_ content: String) { self.content = content }

    init(_ custom: CustomEmoji) {
        content = custom.content
        shortcode = custom.shortcode
        url = custom.url
        setAddress = custom.setAddress
    }

    var custom: CustomEmoji? {
        guard let shortcode, let url else { return nil }
        return CustomEmoji(shortcode: shortcode, url: url, setAddress: setAddress)
    }

    /// Two picks are the same emoji: the same Unicode, or the same shortcode and image.
    var key: String { url.map { "\(content)|\($0)" } ?? content }
}

/// The quick bar and recents, kept on this device only (Logen, 2026-10-27).
/// The bar has `quickSlots` emoji the person can change, and orders itself
/// by how often each one is used. Recents are the last `recentsMax` emoji
/// reacted with, newest first. Pure, so the rules are testable.
enum EmojiPalette {
    static let quickSlots = 6
    static let recentsMax = 24
    /// Use counts kept; the least used go first past this.
    static let countsMax = 200

    static let defaultBar = ["❤️", "🤙", "🔥", "😂", "😮", "😢"].map { ReactionPick($0) }

    struct State: Codable, Equatable {
        var slots: [ReactionPick] = EmojiPalette.defaultBar
        var counts: [String: Int] = [:]
        var recents: [ReactionPick] = []
    }

    /// `pick` was reacted with: newest in recents, one more use.
    static func recordUse(_ state: State, _ pick: ReactionPick) -> State {
        var next = state
        next.recents = Array(([pick] + state.recents.filter { $0.key != pick.key }).prefix(recentsMax))
        next.counts[pick.key, default: 0] += 1
        if next.counts.count > countsMax {
            let keep = Set(state.slots.map(\.key)).union([pick.key])
            let drop = next.counts.filter { !keep.contains($0.key) }
                .sorted { $0.value != $1.value ? $0.value < $1.value : $0.key < $1.key }
                .prefix(next.counts.count - countsMax)
            for (key, _) in drop { next.counts[key] = nil }
        }
        return next
    }

    /// The bar, most used first; equal counts keep the order the person set.
    static func orderedBar(_ state: State) -> [ReactionPick] {
        state.slots.enumerated()
            .sorted { a, b in
                let ca = state.counts[a.element.key] ?? 0, cb = state.counts[b.element.key] ?? 0
                return ca != cb ? ca > cb : a.offset < b.offset
            }
            .map(\.element)
    }

    /// Puts `pick` in the slot `replacing` holds. When `pick` is already on
    /// the bar the two swap places, so the bar never shows one emoji twice.
    static func replaceSlot(_ state: State, replacing: ReactionPick, with pick: ReactionPick) -> State {
        guard replacing.key != pick.key,
              let at = state.slots.firstIndex(where: { $0.key == replacing.key }) else { return state }
        var next = state
        if let existing = state.slots.firstIndex(where: { $0.key == pick.key }) {
            next.slots[existing] = state.slots[at]
        }
        next.slots[at] = pick
        return next
    }

    /// A saved state that is short, long or repeats an emoji is made whole again.
    static func normalized(_ state: State) -> State {
        var seen = Set<String>()
        var slots = state.slots.filter { seen.insert($0.key).inserted }
        slots = Array(slots.prefix(quickSlots))
        for fill in defaultBar where slots.count < quickSlots && !slots.contains(where: { $0.key == fill.key }) {
            slots.append(fill)
        }
        var seenRecent = Set<String>()
        var next = state
        next.slots = slots
        next.recents = Array(state.recents.filter { seenRecent.insert($0.key).inserted }.prefix(recentsMax))
        return next
    }

    /// The hold bar's emoji: `bar` (most used first) with the default
    /// reaction always among them, first if it isn't already there.
    /// `defaultDisplay` is the default reaction as it shows ("+" is ❤️).
    static func tapbackOptions(defaultDisplay: String, bar: [ReactionPick]) -> [ReactionPick] {
        if bar.contains(where: { $0.custom == nil && $0.content == defaultDisplay }) { return bar }
        return [ReactionPick(defaultDisplay)] + bar.dropLast()
    }
}
