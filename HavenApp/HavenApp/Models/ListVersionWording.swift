import Foundation

/// How a list's versions and their Restore / Merge previews read on screen
/// (Logen 2026-11-02: say which app saved a version, how big it was and what
/// it changed, flag the wipe, and say "Will follow again" / "Will unfollow"
/// instead of "Comes back" / "Goes"). Words only; no rule lives here. The web
/// (`RecoverListPage.jsx`) and Android (`ListVersionsPage.kt`) say the same.
enum ListVersionWording {
    /// The app that saved a version: its first `client` tag, else "An unknown app".
    static func app(_ v: ListVersion) -> String {
        let name = v.tags.first { $0.count >= 2 && $0[0] == "client" }?[1]
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "An unknown app" : name
    }

    /// "saved by Primal", "saved by an unknown app", for mid-sentence use.
    static func savedBy(_ v: ListVersion) -> String {
        let a = app(v)
        return "saved by " + (a == "An unknown app" ? "an unknown app" : a)
    }

    /// What one version changed against the one just older than it, in public
    /// items (ListShrinkRule.items, the same items the restore diff uses).
    static func change(_ v: ListVersion, older: ListVersion?) -> (added: Int, removed: Int)? {
        guard let older else { return nil }
        let now = ListShrinkRule.items(v), was = ListShrinkRule.items(older)
        return (now.subtracting(was).count, was.subtracting(now).count)
    }

    /// "300 follows", "12 muted", "4 relays", "1 field".
    static func count(_ v: ListVersion) -> String {
        let n = ListShrinkRule.itemCount(v)
        let base: String
        switch v.kind {
        case 0: base = n == 1 ? "1 field" : "\(n) fields"
        case 10000: base = "\(n) muted"
        default:
            let noun = ListVersionMerge.canMerge(v.kind) ? ListVersionMerge.noun(v.kind) : "item"
            base = "\(n) " + (n == 1 ? noun : plural(noun))
        }
        return ListShrinkRule.encryptedKinds.contains(v.kind) && !v.content.isEmpty ? base + " + private" : base
    }

    /// The row's second line: "300 follows, +3, −709"; "300 follows, no
    /// change"; the oldest kept version: "300 follows".
    static func detail(_ v: ListVersion, older: ListVersion?) -> String {
        guard let c = change(v, older: older) else { return count(v) }
        if c.added == 0 && c.removed == 0 { return count(v) + ", no change" }
        var parts = [count(v)]
        if c.added > 0 { parts.append("+\(c.added)") }
        if c.removed > 0 { parts.append("−\(c.removed)") }
        return parts.joined(separator: ", ")
    }

    /// The flag on a version the shrink rule calls a wipe of the one before it.
    static let wipedFlag = "This one wiped your list"

    /// Section titles: what a Restore or Merge brings back, what it takes
    /// out, and (Merge) what is in the list now and stays.
    struct Titles: Equatable {
        let back: String
        let out: String
        let stays: String
    }

    static func titles(_ kind: Int) -> Titles {
        switch kind {
        case 3: return Titles(back: "Will follow again", out: "Will unfollow", stays: "Still following")
        case 10000: return Titles(back: "Will mute again", out: "Will unmute", stays: "Still muted")
        default: return Titles(back: "Will add back", out: "Will remove", stays: "Already in your list")
        }
    }

    /// The Merge entry's explanation on the versions page.
    static func mergeExplainer(_ kind: Int) -> String {
        kind == 3 ? "Keeps everyone you follow now and adds back people older versions had."
            : "Keeps everything in your list now and adds back what older versions had."
    }

    static let restoreExplainer = "Restore: tap a version below. Your list becomes exactly that version."

    /// Kind 3's merge confirm line: "Saves your follows: you follow 709
    /// again, 2 unfollowed." Nil for other kinds (they keep the entries line).
    static func followMergeLine(added: Int, removed: Int) -> String {
        "Saves your follows: you follow \(added) again" + (removed > 0 ? ", \(removed) unfollowed." : ".")
    }

    /// The hex pubkey of a person entry ("p\0<64 hex>"), else nil: the
    /// screens show these as picture + name, never as hex.
    static func person(_ key: String) -> String? {
        guard key.hasPrefix("p\u{0}") else { return nil }
        let hex = key.dropFirst(2).lowercased()
        return hex.count == 64 && hex.allSatisfy(\.isHexDigit) ? hex : nil
    }

    private static func plural(_ noun: String) -> String {
        // "community" → "communities", but "relay" → "relays".
        guard noun.hasSuffix("y"), let before = noun.dropLast().last, !"aeiou".contains(before) else { return noun + "s" }
        return String(noun.dropLast()) + "ies"
    }
}
