import Foundation

/// Merging old versions of one list (List backups › Merge,
/// RESEARCH/NV_LIST_MERGE_PLAN.md): the person ticks one or more versions the
/// vault kept, sees one line per version of what it would bring back, and
/// saves one list holding every entry of the ticked versions and the current
/// one, each entry once. Pure rules; nothing here reads the network or signs
/// (NostrService+ListMerge.swift does). Twin of web `net/list-version-merge.js`
/// and Android `ListVersionMerge.kt`. Not `ListMerge` (the safe-save base rule).
enum ListVersionMerge {
    /// The lists that can be merged. Not kind 0 (a profile is fields, not
    /// entries), not the relay list (only Settings › Relays saves a 10002,
    /// Logen 2026-10-31; kept by Tod 2026-11-03), not the addressable sets
    /// (Lazarus leaves them out). Were 10002 added, `build` already keeps the
    /// current version's read/write marker (its key is `r` + the address).
    static let kinds: [Int] = [3, 10000, 10003, 10063, 10050, 10006, 10007, 10015, 10001, 10004, 10030]

    /// Relay and server lists: whatever an old version held comes back ticked
    /// (Hal's review: 3 relays down to 1 is never "deliberate" by count).
    /// Same five on web and Android.
    static let relayKinds: Set<Int> = [10002, 10050, 10006, 10007, 10063]
    /// A list under this many entries brings everything back ticked: by count
    /// alone a small list's edit and its wipe look the same.
    static let shortList = 10
    /// The vault keeps every version among the newest this many
    /// (haven-go listHistoryKeep); older ones only around a wipe, so a step
    /// between two of them may hide versions it let go.
    static let vaultKeep = 20
    /// Versions before a new one it is measured against (haven-go shrinkLookback).
    static let lookback = 5

    static func canMerge(_ kind: Int) -> Bool { kinds.contains(kind) }

    /// True when every version the merge was built from (base and ticked)
    /// belongs to `me`: a sheet left open across an account switch must not
    /// sign one account's entries as another account's list.
    static func authoredBy(_ me: String, authors: Set<String>) -> Bool {
        !me.isEmpty && !authors.isEmpty && authors.allSatisfy { $0 == me }
    }

    /// What one entry is called, for "+340 follows, −2".
    static func noun(_ kind: Int) -> String {
        switch kind {
        case 3: return "follow"
        case 10000: return "muted entry"
        case 10003: return "bookmark"
        case 10063: return "server"
        case 10002, 10050, 10006, 10007: return "relay"
        case 10015: return "interest"
        case 10001: return "pinned note"
        case 10004: return "community"
        case 10030: return "emoji"
        default: return "entry"
        }
    }

    /// Kind 3's content is relay hints, never a private part.
    static func hasPrivate(_ v: ListVersion) -> Bool {
        v.kind != 3 && !v.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// NIP-04 ciphertext carries "?iv="; anything else is NIP-44.
    static func isNip04(_ content: String) -> Bool { content.contains("?iv=") }

    // MARK: Entries

    /// A relay or server address as Lazarus compares them: scheme and host
    /// lowercased, default port dropped, repeated slashes collapsed, trailing
    /// slash dropped. Not an address: the trimmed text.
    static func normURL(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let u = URLComponents(string: s), let scheme = u.scheme?.lowercased(), let host = u.host, !host.isEmpty else {
            return s.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        }
        let defaults = ["wss": 443, "https": 443, "ws": 80, "http": 80]
        let port = u.port.map { $0 == defaults[scheme] ? "" : ":\($0)" } ?? ""
        let path = u.percentEncodedPath
            .replacingOccurrences(of: "/{2,}", with: "/", options: .regularExpression)
            .replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        let query = u.percentEncodedQuery.map { "?\($0)" } ?? ""
        return "\(scheme)://\(host.lowercased())\(port)\(path)\(query)"
    }

    private static let urlTags: [Int: String] = [10002: "r", 10050: "relay", 10006: "relay", 10007: "relay", 10063: "server"]
    private static let lowered: Set<String> = ["p", "e", "t", "word"]

    /// One entry's identity: tag name and value (a rewritten relay hint or
    /// petname is the same entry), hex and words lowercased, addresses
    /// normalized. nil for a tag that isn't an entry.
    static func itemKey(kind: Int, tag: [String]) -> String? {
        guard let name = tag.first, !ListShrinkRule.metadataTags.contains(name), tag.count > 1 else { return nil }
        let raw = tag[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        let value = urlTags[kind] == name ? normURL(raw) : lowered.contains(name) ? raw.lowercased() : raw
        return name + "\u{0}" + value
    }

    struct Entry: Equatable {
        let tag: [String]
        var isPrivate: Bool
    }

    /// A version opened for merging: its entries, public and private, each
    /// once (private wins). `locked`: its private part isn't read yet (it is
    /// read when ticked, so a remote signer isn't asked once per version).
    /// `reason`: why the private part couldn't be read.
    struct Opened: Identifiable {
        let version: ListVersion
        var entries: [String: Entry] = [:]
        var order: [String] = []
        var reason = ""
        var locked = false
        var id: String { version.id }

        /// What it held privately isn't known.
        var unread: Bool { !reason.isEmpty || locked }
        /// No entries and no unread private part: never offered.
        var isEmpty: Bool { entries.isEmpty && !unread }

        mutating func add(_ tag: [String], isPrivate: Bool) {
            guard let key = ListVersionMerge.itemKey(kind: version.kind, tag: tag) else { return }
            if entries[key] == nil {
                entries[key] = Entry(tag: tag, isPrivate: isPrivate)
                order.append(key)
            } else if isPrivate {
                entries[key]?.isPrivate = true
            }
        }
    }

    /// Opens `v`. `decrypt` nil: the private part is left locked.
    static func open(_ v: ListVersion, decrypt: ((String) async throws -> String)?) async -> Opened {
        var o = Opened(version: v)
        for tag in v.tags { o.add(tag, isPrivate: false) }
        guard hasPrivate(v) else { return o }
        guard let decrypt else { o.locked = true; return o }
        do {
            let text = try await decrypt(v.content.trimmingCharacters(in: .whitespacesAndNewlines))
            guard let data = text.data(using: .utf8),
                  let tags = (try JSONSerialization.jsonObject(with: data)) as? [[Any]] else {
                o.reason = "its private part isn't a list"
                return o
            }
            for tag in tags { o.add(tag.map { "\($0)" }, isPrivate: true) }
        } catch {
            o.reason = "its private part couldn't be opened"
        }
        return o
    }

    /// Why a version can't be ticked, or nil.
    static func pickProblem(_ o: Opened) -> String? {
        if o.isEmpty { return "Empty: nothing to bring back." }
        if !o.reason.isEmpty { return "Can't be merged: \(o.reason)." }
        return nil
    }

    /// What one version would bring back (+) and drop (−) against now.
    static func delta(_ o: Opened, current: Opened?) -> (added: Int, removed: Int) {
        let now = current?.entries ?? [:]
        return (o.entries.keys.filter { now[$0] == nil }.count, now.keys.filter { o.entries[$0] == nil }.count)
    }

    /// "+340 follows, −2", "Same as now".
    static func deltaLine(kind: Int, added: Int, removed: Int) -> String {
        if added == 0 && removed == 0 { return "Same as now" }
        let n = noun(kind)
        func plural(_ c: Int) -> String { c == 1 ? n : n.range(of: "[^aeiou]y$", options: .regularExpression) != nil ? String(n.dropLast()) + "ies" : n + "s" }
        var parts: [String] = []
        if added > 0 { parts.append("+\(added) \(plural(added))") }
        if removed > 0 { parts.append(added > 0 ? "−\(removed)" : "−\(removed) \(plural(removed))") }
        return parts.joined(separator: ", ")
    }

    // MARK: The merge

    /// `unsure`: whether the person took it out can't be told (a gap in the
    /// vault's history, or a newer version whose private part wasn't read);
    /// it stays out unless ticked in Review (Logen 2026-11-03, as Lazarus).
    enum Status: Equatable { case current, lost, removed, back, unsure }

    struct Row: Identifiable, Equatable {
        let key: String
        let tag: [String]
        var isPrivate: Bool
        var status: Status = .back
        var at: Int64 = 0
        var ticked = true
        var id: String { key }
    }

    static func newerFirst(_ a: Opened, _ b: Opened) -> Bool { ListHistory.newerFirst(a.version, b.version) }

    /// Before a merge: read the private parts still locked in every version
    /// as new as the oldest ticked one or newer. Those may have removed or
    /// hidden a ticked entry (Tron, PR 1570). Only after the Merge tap.
    static func openForMerge(_ all: [Opened], picked: [Opened], decrypt: ((String) async throws -> String)?) async -> [Opened] {
        guard let oldest = picked.map(\.version.createdAt).min() else { return all }
        var out: [Opened] = []
        for o in all {
            out.append(o.locked && o.version.createdAt >= oldest ? await open(o.version, decrypt: decrypt) : o)
        }
        return out
    }

    // MARK: Judging a step

    /// Whether `b`, a version after `a`, looks like a wipe of it, by which
    /// entries went rather than by size (Hal's review: a stale copy of the
    /// same size is a clobber too): it empties `a`, or keeps fewer than half
    /// of a list of `ListShrinkRule.minItems` or more. An encrypted part
    /// either side couldn't read still counts by length, as the vault does.
    static func shrank(_ a: Opened, _ b: Opened) -> Bool {
        let n = a.entries.count
        let kept = a.entries.keys.filter { b.entries[$0] != nil }.count
        if n > 0 && b.entries.isEmpty && !b.unread { return true }
        if n >= ListShrinkRule.minItems && kept * 2 < n { return true }
        if (a.unread || b.unread) && ListShrinkRule.encryptedKinds.contains(a.version.kind) {
            let oldLen = a.version.content.count, newLen = b.version.content.count
            if oldLen > 0 && newLen == 0 { return true }
            if oldLen >= ListShrinkRule.minContent && newLen * 2 < oldLen { return true }
        }
        return false
    }

    /// Whether the entry `key`, held by `timeline[i]` (newest first) and gone
    /// from `timeline[i - 1]` on, went in a wipe: some version O at or up to
    /// `lookback` before i that held it was shrunk by some version V from
    /// i - 1 on, O and V at most `lookback` apart, with no version between
    /// them already shrinking O (that one was the wipe; edits after it are
    /// the person's). A list drained 40 -> 20 -> 10 -> 5 loses P(30), P(15)
    /// and P(8). Only over `ok` versions: a gap or an unread part stops the
    /// window. Same as web `wipeOf` and Android. -> the wipe, or nil.
    static func wipeOf(_ timeline: [Opened], _ i: Int, key: String, ok: (Opened) -> Bool) -> Opened? {
        var memo: [Int: Bool] = [:]
        func wiped(_ o: Int, _ w: Int) -> Bool {
            let k = o * timeline.count + w
            if let hit = memo[k] { return hit }
            let r = shrank(timeline[o], timeline[w]); memo[k] = r; return r
        }
        var o = i
        while o < timeline.count, o - i < lookback, ok(timeline[o]) {
            defer { o += 1 }
            guard timeline[o].entries[key] != nil else { continue }
            var w = i - 1
            while w >= 0, o - w <= lookback, ok(timeline[w]) {
                defer { w -= 1 }
                guard wiped(o, w) else { continue }
                if !((w + 1)..<o).contains(where: { wiped(o, $0) }) { return timeline[w] }
            }
        }
        return nil
    }

    // MARK: The merge

    /// Every entry of `current` and of each `picked` version, each once.
    /// `all` is every version found; `vault` the ids of the ones the vault
    /// keeps, newest first (nil: all of them). For an entry not in the list
    /// now, with H the newest version holding it and N the one after:
    ///  - no N, a relay list, or H read and under `shortList`: back, ticked;
    ///  - H or a newer version with its private part unread: can't tell
    ///    (it may hold the entry privately), left out;
    ///  - H or N not among the vault's newest `vaultKeep`: the vault may
    ///    have let versions between them go; lost if N shrank H (the vault
    ///    pins a wipe with the version before it), else can't tell;
    ///  - a wipe took it (`wipeOf`, step drains too): lost, ticked;
    ///  - else removed in an edit: left out, the person took it out.
    /// A row is private when any version holds it privately, or a newer
    /// unread version might: hiding a public entry loses nothing, publishing
    /// a hidden one can't be undone. Order: the list now's, then what comes
    /// back, newest version first.
    static func build(current: Opened?, picked: [Opened], all: [Opened], vault: [String]? = nil) -> [Row] {
        let sources = (current.map { [$0] } ?? []) + picked.filter { $0.id != current?.id }.sorted(by: newerFirst)
        let timeline = all.sorted(by: newerFirst)
        let vaultOrder = vault ?? timeline.map(\.id)
        let recent = Set(vaultOrder.prefix(vaultKeep))
        var rows: [Row] = []
        var index: [String: Int] = [:]
        for o in sources {
            for key in o.order {
                guard let e = o.entries[key] else { continue }
                if let i = index[key] {
                    if e.isPrivate { rows[i].isPrivate = true }
                } else {
                    index[key] = rows.count
                    rows.append(Row(key: key, tag: e.tag, isPrivate: e.isPrivate))
                }
            }
        }
        let kind = current?.version.kind ?? picked.first?.version.kind ?? 0
        for i in rows.indices {
            let key = rows[i].key
            let holder = timeline.firstIndex { $0.entries[key] != nil }
            let newerUnread = timeline.prefix(holder ?? timeline.count).contains { $0.version.kind != 3 && $0.unread }
            if all.contains(where: { $0.entries[key]?.isPrivate == true }) {
                rows[i].isPrivate = true
            } else if current?.entries[key] == nil, newerUnread {
                rows[i].isPrivate = true
            }
            if current?.entries[key] != nil {
                rows[i].status = .current
                continue
            }
            guard let h = holder, h > 0 else { rows[i].status = .back; continue }
            let held = timeline[h], next = timeline[h - 1]
            rows[i].at = next.version.createdAt
            if relayKinds.contains(kind) || (held.entries.count < shortList && !held.unread) {
                rows[i].status = .back
            } else if newerUnread || held.unread {
                rows[i].status = .unsure
                rows[i].ticked = false
            } else if !recent.contains(held.id) || !recent.contains(next.id) {
                if shrank(held, next) {
                    rows[i].status = .lost
                } else {
                    rows[i].status = .unsure
                    rows[i].ticked = false
                }
            } else if let wipe = wipeOf(timeline, h, key: key, ok: { recent.contains($0.id) && !$0.unread }) {
                rows[i].status = .lost
                rows[i].at = wipe.version.createdAt
            } else {
                rows[i].status = .removed
                rows[i].ticked = false
            }
            if rows[i].status == .back { rows[i].at = 0 }
        }
        return rows
    }

    /// The new list's tags: the current version's own tags (d, title, …)
    /// first, then each ticked public row; ticked private rows go in
    /// `privateTags`.
    static func tags(_ rows: [Row], current: Opened?) -> (tags: [[String]], privateTags: [[String]]) {
        var tags = (current?.version.tags ?? []).filter { $0.first.map(ListShrinkRule.metadataTags.contains) ?? false }
        var privateTags: [[String]] = []
        for r in rows where r.ticked {
            if r.isPrivate { privateTags.append(r.tag) } else { tags.append(r.tag) }
        }
        return (tags, privateTags)
    }

    /// What a mute list mutes again, by what it is.
    struct Remutes: Equatable {
        var people = 0, words = 0, hashtags = 0, threads = 0
        var isEmpty: Bool { people + words + hashtags + threads == 0 }

        /// "3 people, 2 words, 1 hashtag, 1 thread".
        var line: String {
            func part(_ n: Int, _ one: String, _ many: String) -> String? { n == 0 ? nil : "\(n) \(n == 1 ? one : many)" }
            return [part(people, "person", "people"), part(words, "word", "words"),
                    part(hashtags, "hashtag", "hashtags"), part(threads, "thread", "threads")]
                .compactMap { $0 }.joined(separator: ", ")
        }
    }

    struct Summary: Equatable {
        let total: Int
        let added: Int
        let removed: Int
        let leftOut: Int
        /// Left out because it can't be told whether the person took them out.
        let unsure: Int
        let remutes: Remutes
    }

    static func summary(kind: Int, rows: [Row]) -> Summary {
        let ticked = rows.filter(\.ticked)
        let added = ticked.filter { $0.status != .current }
        var remutes = Remutes()
        if kind == 10000 {
            for r in added {
                switch r.tag.first {
                case "p": remutes.people += 1
                case "word": remutes.words += 1
                case "t": remutes.hashtags += 1
                case "e": remutes.threads += 1
                default: break
                }
            }
        }
        return Summary(total: ticked.count, added: added.count,
                       removed: rows.filter { $0.status == .current && !$0.ticked }.count,
                       leftOut: rows.filter { $0.status == .removed && !$0.ticked }.count,
                       unsure: rows.filter { $0.status == .unsure && !$0.ticked }.count,
                       remutes: remutes)
    }
}
