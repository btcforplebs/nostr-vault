import Foundation

/// NIP-94 file notes (kind 1063) on the home vault's `/files` room
/// (RESEARCH/NV_MEDIA_LIVE_FILE_NOTES_PLAN.md §1-§2, haven-go files_relay.go).
/// One note per (signing device, blob), signed with the device's mesh key
/// only, never the account key or its signer (Logen, 2026-11-05). Pure, so
/// MediaLogicTests checks it.
struct FileNote: Equatable {
    static let kind = 1063

    let id: String
    /// The device mesh key (or the vault's own key) that signed it.
    let signer: String
    let createdAt: Int64
    let sha256: String
    let mime: String
    let size: Int64
    /// Whose media this is (one `p`, the vault owner).
    let owner: String
    /// `url` then each `fallback`, https only.
    let urls: [String]

    /// The tags of a device's note for one blob, or nil when the blob, type,
    /// size or owner would make the vault refuse it. `servers`: the media
    /// servers that have it; mesh and home-network ones are left out (the
    /// note never names a place only this home can open), and none at all
    /// means the vault itself holds it.
    static func tags(sha256: String, mime: String, size: Int64, owner: String, servers: [String]) -> [[String]]? {
        let x = sha256.lowercased()
        let m = mime.trimmingCharacters(in: .whitespaces)
        guard isHex64(x), !m.isEmpty, size >= 0, isHex64(owner) else { return nil }
        var tags: [[String]] = [["x", x], ["m", m], ["size", String(size)], ["p", owner]]
        let links = servers.compactMap { HomeVaultLogic.publicBlobURL(server: $0, sha256: x, contentType: m)?.absoluteString }
        var seen = Set<String>()
        for (i, link) in links.enumerated() where seen.insert(link).inserted {
            tags.append([i == 0 ? "url" : "fallback", link])
        }
        tags.append(["client", "nostr-vault"])
        return tags
    }

    /// A note as the vault serves it, or nil for anything it should never
    /// have taken (a reader does not trust the room blindly).
    static func parse(_ event: [String: Any]) -> FileNote? {
        guard event["kind"] as? Int == kind,
              let id = event["id"] as? String, !id.isEmpty,
              let signer = event["pubkey"] as? String, !signer.isEmpty,
              let tags = event["tags"] as? [[Any]] else { return nil }
        let t = StringTags(tags)
        guard let x = t.first("x"), isHex64(x),
              let m = t.first("m"), !m.isEmpty,
              let sizeText = t.first("size"), let size = Int64(sizeText), size >= 0 else { return nil }
        let ps = t.all("p")
        guard ps.count == 1, isHex64(ps[0]) else { return nil }
        let urls = (t.all("url") + t.all("fallback")).filter { $0.lowercased().hasPrefix("https://") && URL(string: $0) != nil }
        return FileNote(id: id, signer: signer, createdAt: createdAt(event), sha256: x, mime: m, size: size,
                        owner: ps[0], urls: urls)
    }

    /// The live REQ every open Media tab keeps on `/files`.
    static func liveFilter(owner: String, since: Int64?) -> [String: Any] {
        var f: [String: Any] = ["kinds": [kind, 5], "#p": [owner]]
        if let since { f["since"] = since }
        return f
    }

    /// The websocket for `/files` on a vault: the mesh ingress base keeps its
    /// token path; a vault's own relay address gets `/files`.
    static func filesURL(base: URL) -> URL? {
        guard var c = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        switch c.scheme {
        case "https", "wss": c.scheme = "wss"
        default: c.scheme = "ws"
        }
        var path = c.path
        while path.hasSuffix("/") { path.removeLast() }
        c.path = path + "/files"
        return c.url
    }

    /// The `relay` tag of the NIP-42 AUTH. Over the mesh the vault pins it to
    /// its own mesh address (haven-go meshAuthURL); on the vault's own relay
    /// it is the address dialled.
    static func authRelayURL(vaultNpub: String?, connected: URL) -> String {
        if let vaultNpub, !vaultNpub.isEmpty { return "ws://\(vaultNpub).fips/files" }
        return connected.absoluteString
    }

    static func authTags(relayURL: String, challenge: String) -> [[String]] {
        [["relay", relayURL], ["challenge", challenge]]
    }

    // MARK: Tile check (plan gap 3)

    enum TileState: Equatable { case visible, dimmed, hidden }

    /// A note-only tile (not in this device's folder). `serverStatuses`: the
    /// HEAD answer of each server the notes name (nil = no answer).
    /// `vaultHas`: the home vault's answer, nil when not asked or no answer.
    /// It hides only when every server said 404 and the vault lacks it:
    /// a server that didn't answer is not proof the file is gone.
    static func tileState(serverStatuses: [Int?], vaultHas: Bool?) -> TileState {
        if vaultHas == true || serverStatuses.contains(where: { $0.map { (200...299).contains($0) } ?? false }) {
            return .visible
        }
        if vaultHas == false, serverStatuses.allSatisfy({ $0 == 404 }) { return .hidden }
        return .dimmed
    }

    // MARK: What the mesh key may sign

    static let deletionKind = 5
    static let authKind = 22242

    /// Only `/files` events: a 1063, a kind 5 that says `k` 1063 and nothing
    /// else, and an AUTH whose relay is a `/files` room. Kept narrow so the
    /// mesh key still signs no posts (as Android's fileNotesAllowed): the
    /// vault refuses the account key for all three (files_relay.go).
    static func meshKeyMaySign(kind: Int, tags: [[String]]) -> Bool {
        switch kind {
        case Self.kind:
            return true
        case deletionKind:
            let ks = tags.compactMap { $0.count >= 2 && $0[0] == "k" ? $0[1] : nil }
            return !ks.isEmpty && ks.allSatisfy { $0 == String(Self.kind) }
        case authKind:
            return tags.contains { tag in
                guard tag.count >= 2, tag[0] == "relay" else { return false }
                var relay = String(tag[1].split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
                while relay.hasSuffix("/") { relay.removeLast() }
                return relay.hasSuffix("/files")
            }
        default:
            return false
        }
    }

    static func isHex64(_ s: String) -> Bool {
        s.count == 64 && s.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    static func createdAt(_ event: [String: Any]) -> Int64 {
        if let n = event["created_at"] as? Int64 { return n }
        if let n = event["created_at"] as? Int { return Int64(n) }
        if let n = event["created_at"] as? Double { return Int64(n) }
        return 0
    }
}

/// A kind 5 on `/files`: it names the notes it deletes, says `k` 1063, and
/// the hash it is about.
struct FileNoteDeletion: Equatable {
    let id: String
    let signer: String
    let createdAt: Int64
    let noteIDs: Set<String>
    let hashes: Set<String>

    /// Tags for deleting every note `noteIDs` (from a REQ `#x` on `/files`)
    /// for one blob; nil with no note to name (the vault would refuse it).
    static func tags(noteIDs: [String], sha256: String, owner: String) -> [[String]]? {
        let ids = Array(Set(noteIDs.filter { !$0.isEmpty })).sorted()
        let x = sha256.lowercased()
        guard !ids.isEmpty, FileNote.isHex64(x), FileNote.isHex64(owner) else { return nil }
        return ids.map { ["e", $0] } + [["k", String(FileNote.kind)], ["x", x], ["p", owner]]
    }

    static func parse(_ event: [String: Any]) -> FileNoteDeletion? {
        guard event["kind"] as? Int == 5,
              let id = event["id"] as? String, !id.isEmpty,
              let signer = event["pubkey"] as? String,
              let tags = event["tags"] as? [[Any]] else { return nil }
        let t = StringTags(tags)
        guard t.all("k").contains(String(FileNote.kind)) else { return nil }
        let ids = Set(t.all("e"))
        guard !ids.isEmpty else { return nil }
        return FileNoteDeletion(id: id, signer: signer, createdAt: FileNote.createdAt(event),
                                noteIDs: ids, hashes: Set(t.all("x").filter(FileNote.isHex64)))
    }
}

/// One Media tab tile from the notes: a hash some live note names.
struct FileNoteTile: Equatable {
    let sha256: String
    let mime: String
    let size: Int64
    /// The newest note's time.
    let createdAt: Int64
    /// Every live note's links, newest note first, each once.
    let urls: [String]
}

/// What the live notes say, merged by hash. Deletions are kept so a note
/// replayed after its deletion never comes back.
struct FileNotesState: Equatable {
    /// Back this far on a resubscribe, for notes stamped a little late.
    static let resubscribeOverlap: Int64 = 600

    enum Change: Equatable {
        case none
        case added(String)
        case removed(String)
    }

    /// Only this owner's notes count; nil takes the room's word.
    var owner: String?
    private(set) var notes: [String: FileNote] = [:]
    private(set) var deleted: Set<String> = []
    private(set) var newestSeen: Int64?

    init(owner: String? = nil) {
        self.owner = owner
    }

    /// Apply one event from the room: what that does to the tiles.
    mutating func apply(_ event: [String: Any]) -> Change {
        let at = FileNote.createdAt(event)
        if let note = FileNote.parse(event) {
            guard owner.map({ $0 == note.owner }) ?? true else { return .none }
            seen(at)
            guard !deleted.contains(note.id), notes[note.id] == nil else { return .none }
            let had = hasLiveNote(note.sha256)
            notes[note.id] = note
            return had ? .none : .added(note.sha256)
        }
        if let deletion = FileNoteDeletion.parse(event) {
            seen(at)
            var touched = Set<String>()
            for id in deletion.noteIDs {
                deleted.insert(id)
                if let note = notes.removeValue(forKey: id) { touched.insert(note.sha256) }
            }
            // One hash per deletion here (the vault's and the apps' form).
            if let gone = touched.sorted().first(where: { !hasLiveNote($0) }) { return .removed(gone) }
        }
        return .none
    }

    /// Since when to ask again after a drop: the newest seen, less the overlap.
    var since: Int64? {
        newestSeen.map { max(0, $0 - Self.resubscribeOverlap) }
    }

    func hasLiveNote(_ sha256: String) -> Bool {
        notes.values.contains { $0.sha256 == sha256 }
    }

    func noteIDs(for sha256: String) -> [String] {
        notes.values.filter { $0.sha256 == sha256 }.map(\.id).sorted()
    }

    /// One tile per hash, newest first.
    var tiles: [FileNoteTile] {
        let byHash = Dictionary(grouping: notes.values, by: \.sha256)
        return byHash.map { sha, group in
            let ordered = group.sorted { $0.createdAt != $1.createdAt ? $0.createdAt > $1.createdAt : $0.id < $1.id }
            var seen = Set<String>()
            let urls = ordered.flatMap(\.urls).filter { seen.insert($0).inserted }
            return FileNoteTile(sha256: sha, mime: ordered[0].mime, size: ordered[0].size,
                                createdAt: ordered[0].createdAt, urls: urls)
        }
        .sorted { $0.createdAt != $1.createdAt ? $0.createdAt > $1.createdAt : $0.sha256 < $1.sha256 }
    }

    private mutating func seen(_ at: Int64) {
        if at > (newestSeen ?? .min) { newestSeen = at }
    }
}

/// Tag values by name, from an event's raw tags.
private struct StringTags {
    let tags: [[String]]

    init(_ raw: [[Any]]) {
        tags = raw.map { $0.compactMap { $0 as? String } }
    }

    func first(_ name: String) -> String? { all(name).first }

    func all(_ name: String) -> [String] {
        tags.compactMap { $0.count >= 2 && $0[0] == name ? $0[1] : nil }
    }
}
