import Foundation

/// The Vault's Emoji page rules (RESEARCH/NV_CUSTOM_EMOJI_PLAN.md §4): what
/// a set's emoji show as, what Save copies fetches, where a dead image is
/// looked for, and how a zip's files are matched. Pure, so MediaLogicTests
/// checks it apart from the network. The store that acts on it is
/// `EmojiVaultStore`; Android `service/EmojiVaultStore.kt`, web `net/emoji-vault.js`.
enum EmojiVaultLogic {
    // MARK: Caps (§4.1, same on every platform)

    static let maxImageBytes: Int64 = 2 * 1024 * 1024
    static let maxFiles = 3_000
    static let maxTotalBytes: Int64 = 200 * 1024 * 1024
    /// A zip bigger than this is refused before it is opened.
    static let maxZipBytes: Int64 = 256 * 1024 * 1024
    static let imageTypes: Set<String> = ["image/png", "image/jpeg", "image/gif", "image/webp", "image/avif"]

    static func isAllowedImage(mime: String) -> Bool {
        imageTypes.contains(mime.lowercased().split(separator: ";").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? "")
    }

    // MARK: Page

    /// How one emoji of a set stands in the vault.
    enum Status: Equatable {
        /// A copy is in the vault: the image never depends on its link again.
        case saved(sha256: String)
        /// No copy yet; the link still worked last time it was tried (or was never tried).
        case notSaved
        /// No copy, and the link and every other server failed on the last Save copies.
        case dead
    }

    struct Row: Equatable, Identifiable {
        var id: String { emoji.shortcode + "\u{0}" + emoji.url }
        let emoji: CustomEmoji
        let status: Status
    }

    struct SetPage: Equatable, Identifiable {
        var id: String { address }
        let address: String
        let title: String
        let author: String
        let rows: [Row]
        var saved: Int { rows.filter { if case .saved = $0.status { return true }; return false }.count }
        var dead: Int { rows.filter { $0.status == .dead }.count }
    }

    /// Each set the 10030 names, in its order, every emoji with its status.
    /// An emoji counts as saved when a copy's note names its link, or when
    /// its link carries the hash of a copy (the same image under another
    /// address). Loose emoji (no set) are not listed (pick 6).
    static func pages(sets: [EmojiLibrary.EmojiSet], copies: [String: EmojiCopy], dead: Set<String>) -> [SetPage] {
        let byURL = copiesByURL(copies)
        return sets.map { set in
            let rows = set.emojis.map { emoji -> Row in
                if let sha = savedHash(for: emoji.url, byURL: byURL, copies: copies) {
                    return Row(emoji: emoji, status: .saved(sha256: sha))
                }
                return Row(emoji: emoji, status: dead.contains(emoji.url) ? .dead : .notSaved)
            }
            return SetPage(address: set.address, title: set.title,
                           author: EmojiListParse.setRef(set.address)?.pubkey ?? "", rows: rows)
        }
    }

    /// Every emoji with a dead link and no copy, once per link, across sets.
    static func deadLinks(_ pages: [SetPage]) -> [Row] {
        var seen = Set<String>()
        return pages.flatMap(\.rows).filter { $0.status == .dead && seen.insert($0.emoji.url).inserted }
    }

    /// Link → hash, from every copy's note.
    static func copiesByURL(_ copies: [String: EmojiCopy]) -> [String: String] {
        var out: [String: String] = [:]
        for (sha, copy) in copies {
            for e in copy.note.emoji where out[e.url] == nil { out[e.url] = sha }
        }
        return out
    }

    static func savedHash(for url: String, byURL: [String: String], copies: [String: EmojiCopy]) -> String? {
        if let sha = byURL[url] { return sha }
        if let sha = hashInURL(url), copies[sha] != nil { return sha }
        return nil
    }

    // MARK: Save copies

    /// One image to fetch: its link and every set emoji that uses it.
    struct Job: Equatable {
        let url: String
        let emoji: [CustomEmoji]
    }

    /// The links Save copies fetches: one per link, in set order, skipping
    /// links already saved. `emoji` carry their set (`setAddress`), so the
    /// note names every shortcode and set the image is for.
    static func jobs(sets: [EmojiLibrary.EmojiSet], copies: [String: EmojiCopy]) -> [Job] {
        let byURL = copiesByURL(copies)
        var order: [String] = []
        var users: [String: [CustomEmoji]] = [:]
        for set in sets {
            for e in set.emojis {
                let tagged = CustomEmoji(shortcode: e.shortcode, url: e.url, setAddress: e.setAddress ?? set.address)
                if users[e.url] == nil { order.append(e.url) }
                if !(users[e.url]?.contains(tagged) ?? false) { users[e.url, default: []].append(tagged) }
            }
        }
        return order.filter { savedHash(for: $0, byURL: byURL, copies: copies) == nil }
            .map { Job(url: $0, emoji: users[$0] ?? []) }
    }

    /// Every emoji of `sets` whose image hashes to `sha256` or whose link is
    /// `url`: a hash fetched once fills every link that serves the same file.
    static func users(of url: String, in jobs: [Job]) -> [CustomEmoji] {
        jobs.first { $0.url == url }?.emoji ?? []
    }

    /// The tally Save copies shows: "Saved 203 · 9 dead · 4 too big".
    struct Tally: Equatable {
        var saved = 0
        var already = 0
        var dead = 0
        var tooBig = 0
        var notImage = 0
        var overCap = 0

        var summary: String {
            var parts = ["Saved \(saved)"]
            if already > 0 { parts.append("\(already) already saved") }
            if dead > 0 { parts.append("\(dead) dead") }
            if tooBig > 0 { parts.append("\(tooBig) too big") }
            if notImage > 0 { parts.append("\(notImage) not an image") }
            if overCap > 0 { parts.append("\(overCap) over the limit") }
            return parts.joined(separator: " · ")
        }
    }

    // MARK: Dead links

    /// The 64-hex hash a Blossom-style link carries in its last path part
    /// (`…/<sha256>` or `…/<sha256>.png`), or nil.
    static func hashInURL(_ url: String) -> String? {
        guard let last = URL(string: url)?.lastPathComponent, !last.isEmpty else { return nil }
        let stem = last.split(separator: ".", maxSplits: 1).first.map(String.init) ?? last
        let lower = stem.lowercased()
        guard lower.count == 64, lower.allSatisfy({ $0.isHexDigit }) else { return nil }
        return lower
    }

    /// Well-known public Blossom servers a dead link's hash is also asked of,
    /// after the account's own servers.
    static let publicServers = [
        "https://blossom.primal.net",
        "https://nostr.download",
        "https://cdn.satellite.earth",
        "https://blossom.band",
        "https://blossom.nostr.build",
    ]

    /// Where to look for a dead link's file: `<server>/<sha256>` on each of
    /// `own` then `publicServers`, https only, the dead link's own host left
    /// out, each server once. Empty when the link carries no hash (then
    /// nothing else can prove it is the same image).
    static func otherServerURLs(for deadURL: String, own: [String]) -> [URL] {
        guard let sha = hashInURL(deadURL) else { return [] }
        let deadHost = URL(string: deadURL)?.host?.lowercased()
        var seen = Set<String>()
        var out: [URL] = []
        for server in own + publicServers {
            let base = server.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard base.lowercased().hasPrefix("https://"), let host = URL(string: base)?.host?.lowercased(),
                  host != deadHost, !host.hasSuffix(".fips"), seen.insert(host).inserted,
                  let url = URL(string: base + "/" + sha) else { continue }
            out.append(url)
        }
        return out
    }

    // MARK: Zip import (§4.1, Tod 13:25Z)

    struct ZipFile: Equatable {
        /// The file's name in the zip, without folders.
        let name: String
        let sha256: String
    }

    struct ZipMatch: Equatable {
        let file: ZipFile
        /// The set emoji it fills.
        let emoji: [CustomEmoji]
    }

    /// Each zip image matched to the saved sets' emoji: by file name =
    /// shortcode (case as written, extension dropped), or by the same hash
    /// as the link carries or a copy already has. A file that matches
    /// nothing is listed in `unmatched` and skipped: making sets from a zip
    /// belongs to My sets later.
    static func matchZip(_ files: [ZipFile], sets: [EmojiLibrary.EmojiSet],
                         copies: [String: EmojiCopy]) -> (matched: [ZipMatch], unmatched: [String]) {
        var byCode: [String: [CustomEmoji]] = [:]
        var byHash: [String: [CustomEmoji]] = [:]
        let byURL = copiesByURL(copies)
        for set in sets {
            for e in set.emojis {
                let tagged = CustomEmoji(shortcode: e.shortcode, url: e.url, setAddress: e.setAddress ?? set.address)
                byCode[e.shortcode, default: []].append(tagged)
                if let sha = hashInURL(e.url) ?? byURL[e.url] { byHash[sha, default: []].append(tagged) }
            }
        }
        var matched: [ZipMatch] = []
        var unmatched: [String] = []
        for file in files {
            let stem = (file.name as NSString).deletingPathExtension
            var hits: [CustomEmoji] = []
            for e in (byHash[file.sha256] ?? []) + (byCode[stem] ?? []) where !hits.contains(e) { hits.append(e) }
            if hits.isEmpty { unmatched.append(file.name) } else { matched.append(ZipMatch(file: file, emoji: hits)) }
        }
        return (matched, unmatched)
    }

    // MARK: 10030 (pick 5)

    /// A 10030's tags with the set `address` added or removed: every other
    /// tag kept as it was (loose emoji too, pick 6).
    static func listTags(base: [[String]], add: String? = nil, remove: String? = nil) -> [[String]] {
        // Exact match: a set's `d` is case-sensitive, so ListMerge.edit's
        // lowercased keys could take out the wrong set.
        var out = base.filter { !($0.count >= 2 && $0[0] == "a" && $0[1] == remove) }
        if let add, !out.contains(where: { $0.count >= 2 && $0[0] == "a" && $0[1] == add }) { out.append(["a", add]) }
        return out
    }

    /// A pasted set: `naddr1…` (kind 30030), `nostr:naddr1…`, or a
    /// `30030:<pk>:<d>` address. Nil for anything else.
    static func setAddress(fromPaste raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("nostr:") { text = String(text.dropFirst(6)) }
        if EmojiListParse.setRef(text) != nil { return text }
        guard text.lowercased().hasPrefix("naddr1"), let decoded = Bech32.decode(text), decoded.hrp == "naddr",
              let parts = QuoteReference.naddrParts(fromTLV: decoded.data), parts.kind == 30030 else { return nil }
        let address = "30030:\(parts.pubkey.lowercased()):\(parts.dTag)"
        return EmojiListParse.setRef(address) != nil ? address : nil
    }
}
