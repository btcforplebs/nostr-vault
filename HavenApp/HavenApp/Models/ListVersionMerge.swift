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
    /// Logen 2026-10-31), not the addressable sets (Lazarus leaves them out).
    static let kinds: [Int] = [3, 10000, 10003, 10063, 10050, 10006, 10007, 10015, 10001, 10004, 10030]

    static func canMerge(_ kind: Int) -> Bool { kinds.contains(kind) }

    /// What one entry is called, for "+340 follows, −2".
    static func noun(_ kind: Int) -> String {
        switch kind {
        case 3: return "follow"
        case 10000: return "muted entry"
        case 10003: return "bookmark"
        case 10063: return "server"
        case 10050, 10006, 10007: return "relay"
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

    private static let urlTags: [Int: String] = [10050: "relay", 10006: "relay", 10007: "relay", 10063: "server"]
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
        func plural(_ c: Int) -> String { c == 1 ? n : n.hasSuffix("y") ? String(n.dropLast()) + "ies" : n + "s" }
        var parts: [String] = []
        if added > 0 { parts.append("+\(added) \(plural(added))") }
        if removed > 0 { parts.append(added > 0 ? "−\(removed)" : "−\(removed) \(plural(removed))") }
        return parts.joined(separator: ", ")
    }

    // MARK: The merge

    enum Status: Equatable { case current, lost, removed, back }

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

    /// Every entry of `current` and of each `picked` version, each once.
    /// `all` is every version found, to tell what happened to an entry after
    /// the newest version that held it: in the list now (ticked); lost to a
    /// wipe (ticked); removed in an ordinary edit (unticked, the person took
    /// it out); no later version known (ticked). A row is private when any
    /// version holds it privately, or a newer unread version might: hiding a
    /// public entry loses nothing, publishing a hidden one can't be undone.
    /// Order: the list now's, then what comes back, newest version first.
    static func build(current: Opened?, picked: [Opened], all: [Opened]) -> [Row] {
        let sources = (current.map { [$0] } ?? []) + picked.filter { $0.id != current?.id }.sorted(by: newerFirst)
        let timeline = all.sorted(by: newerFirst)
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
        for i in rows.indices {
            let key = rows[i].key
            let holder = timeline.firstIndex { $0.entries[key] != nil }
            if all.contains(where: { $0.entries[key]?.isPrivate == true }) {
                rows[i].isPrivate = true
            } else if current?.entries[key] == nil,
                      timeline.prefix(holder ?? timeline.count).contains(where: { $0.version.kind != 3 && $0.unread }) {
                rows[i].isPrivate = true
            }
            if current?.entries[key] != nil {
                rows[i].status = .current
                continue
            }
            guard let h = holder, h > 0 else { rows[i].status = .back; continue }
            let next = timeline[h - 1]
            if ListShrinkRule.shrank(timeline[h].version, next.version) {
                rows[i].status = .lost
                rows[i].at = next.version.createdAt
            } else if next.unread && rows[i].isPrivate {
                rows[i].status = .back // whether it still held it isn't known
            } else {
                rows[i].status = .removed
                rows[i].at = next.version.createdAt
                rows[i].ticked = false
            }
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

    struct Summary: Equatable {
        let total: Int
        let added: Int
        let removed: Int
        let leftOut: Int
        let remutes: Int
    }

    static func summary(kind: Int, rows: [Row]) -> Summary {
        let ticked = rows.filter(\.ticked)
        let added = ticked.filter { $0.status != .current }
        return Summary(total: ticked.count, added: added.count,
                       removed: rows.filter { $0.status == .current && !$0.ticked }.count,
                       leftOut: rows.filter { $0.status == .removed && !$0.ticked }.count,
                       remutes: kind == 10000 ? added.filter { $0.tag.first == "p" }.count : 0)
    }
}
