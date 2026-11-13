import Foundation

/// Rules for adding a Genmoji to one of the account's own emoji sets
/// (RESEARCH/NV_GENMOJI_STARTER_SET.md, pick S): the shortcode a Genmoji's
/// description becomes, the `d` tag of a new set, and the merged 30030 tags.
/// Pure, so MediaLogicTests checks it apart from the relays and the sheet.
/// The flow that acts on it is `GenmojiSaver`.
enum GenmojiSets {
    /// The default set: one per account, made by the first Save.
    static let defaultD = "nv-genmoji"
    static let defaultTitle = "My Genmoji"
    /// Shortcodes are cut to this many characters (before any `_2` suffix).
    static let maxShortcode = 32

    /// A set this account can add to: its own 30030s (from its 10030), plus
    /// "My Genmoji" while it doesn't exist yet.
    struct Target: Equatable, Hashable {
        let d: String
        let title: String
        /// False for "My Genmoji" before its first Save.
        let exists: Bool
    }

    /// The account's own sets from the library, "My Genmoji" first (made up
    /// when missing), the rest in list order.
    static func targets(sets: [EmojiLibrary.EmojiSet], me: String) -> [Target] {
        var own: [Target] = []
        var seen = Set<String>()
        for set in sets {
            guard let ref = EmojiListParse.setRef(set.address), ref.pubkey == me.lowercased(),
                  seen.insert(ref.d).inserted else { continue }
            own.append(Target(d: ref.d, title: ref.d == defaultD ? defaultTitle : set.title, exists: true))
        }
        if let i = own.firstIndex(where: { $0.d == defaultD }) {
            own.insert(own.remove(at: i), at: 0)
        } else {
            own.insert(Target(d: defaultD, title: defaultTitle, exists: false), at: 0)
        }
        return own
    }

    /// `30030:<me>:<d>`.
    static func address(me: String, d: String) -> String { "30030:\(me.lowercased()):\(d)" }

    /// Lowercase letters, digits and `_` from `text`; runs of anything else
    /// become one `_`. Accents are dropped (é → e). Empty when nothing is left.
    static func slug(_ text: String, max: Int = maxShortcode) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
        var out = ""
        var gap = false
        for s in folded.unicodeScalars {
            if s.isASCII && (CharacterSet.alphanumerics.contains(s)) {
                if gap && !out.isEmpty { out.append("_") }
                gap = false
                out.unicodeScalars.append(s)
            } else {
                gap = true
            }
        }
        if out.count > max {
            out = String(out.prefix(max))
            while out.hasSuffix("_") { out.removeLast() }
        }
        return out
    }

    /// The shortcode for a Genmoji described as `description`: its slug, or
    /// "genmoji" when the description gives nothing, with `_2`, `_3`… on a
    /// clash with `taken` (every shortcode already in the account's sets).
    static func shortcode(for description: String, taken: Set<String>) -> String {
        let base = slug(description).isEmpty ? "genmoji" : slug(description)
        return unique(base, taken: taken)
    }

    /// `base`, or `base_2`, `base_3`… : the first not in `taken`.
    static func unique(_ base: String, taken: Set<String>) -> String {
        guard taken.contains(base) else { return base }
        var n = 2
        while taken.contains("\(base)_\(n)") { n += 1 }
        return "\(base)_\(n)"
    }

    /// The `d` tag for a new set titled `title`: `nv-genmoji-<slug>`, made
    /// unique against the account's own sets.
    static func newSetD(title: String, taken: Set<String>) -> String {
        let s = slug(title, max: 24)
        return unique(s.isEmpty ? "\(defaultD)-set" : "\(defaultD)-\(s)", taken: taken.union([defaultD]))
    }

    /// Why a shortcode the person typed can't be saved, or nil when it can.
    static func problem(shortcode: String, taken: Set<String>) -> String? {
        if shortcode.isEmpty { return "Give it a short name." }
        guard shortcode.unicodeScalars.allSatisfy({ ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || $0 == "_" }) else {
            return "Only letters, numbers and _."
        }
        if taken.contains(shortcode) { return ":\(shortcode): is already one of your emoji." }
        return nil
    }

    /// The set's tags after adding `emoji`: every tag of `base` (the newest
    /// published copy, nil for a new set) kept as it was, `d` and `title`
    /// added when missing, `image` set to the first emoji when missing, and
    /// the emoji tag appended unless the same (code, url) is already there.
    static func setTags(base: [[String]]?, d: String, title: String, adding emoji: CustomEmoji) -> [[String]] {
        var tags = base ?? []
        func has(_ name: String) -> Bool { tags.contains { $0.count >= 2 && $0[0] == name && !$0[1].isEmpty } }
        if !has("d") { tags.insert(["d", d], at: 0) }
        if !has("title") {
            let at = (tags.firstIndex { $0.first == "d" } ?? -1) + 1
            tags.insert(["title", title], at: at)
        }
        if !has("image") {
            let at = (tags.lastIndex { $0.first == "d" || $0.first == "title" } ?? -1) + 1
            tags.insert(["image", emoji.url], at: at)
        }
        let tag = ["emoji", emoji.shortcode, emoji.url]
        if !tags.contains(where: { $0.count >= 3 && $0[0] == "emoji" && $0[1] == emoji.shortcode && $0[2] == emoji.url }) {
            tags.append(tag)
        }
        return tags
    }

    /// Whether `url` can go in a public set: https on a public host, never
    /// this device, the home vault or a mesh (`.fips`) address.
    static func isPublicURL(_ url: String) -> Bool {
        guard let u = URL(string: url), u.scheme?.lowercased() == "https", let host = u.host?.lowercased(), !host.isEmpty else { return false }
        if host == "localhost" || host.hasSuffix(".local") || host.hasSuffix(".fips") || host.hasSuffix(".onion") { return false }
        if host.hasPrefix("127.") || host.hasPrefix("10.") || host.hasPrefix("192.168.") || host == "::1" || host.hasPrefix("[") { return false }
        return host.contains(".")
    }

    /// Every shortcode in the account's emoji, so a new one never clashes.
    static func takenShortcodes(_ library: EmojiLibrary) -> Set<String> {
        Set(library.single.map(\.shortcode) + library.sets.flatMap { $0.emojis.map(\.shortcode) })
    }

    /// The Save button: it publishes, so it says so.
    static func saveLabel(setTitle: String) -> String { "Save publicly to \(setTitle)" }
    static let publicNote = "Emoji sets are public: anyone on Nostr can see and use this Genmoji."
}
