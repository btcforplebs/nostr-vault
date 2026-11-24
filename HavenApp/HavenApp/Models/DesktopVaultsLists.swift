import Foundation

/// The owner's three public lists that can name desktop Vaults.
enum DesktopVaultList: Int, CaseIterable, Codable {
    /// NIP-65 relays: `["r", "wss://host"]`, plus `["fipsmesh", "fipsmesh://<npub>/", "write"]`.
    case relays = 10002
    /// NIP-17 DM inbox: `["relay", "wss://host/inbox"]`. No mesh entry is offered.
    case inbox = 10050
    /// BUD-03 media servers: `["server", "https://host"]` and `["server", "fipsmesh://<npub>/"]`.
    case media = 10063

    /// The message a refused change shows (§2.5 rule 5).
    var refusal: String {
        switch self {
        case .relays: return "Add another relay first."
        case .inbox: return "Add another DM inbox relay first."
        case .media: return "Add another media server first."
        }
    }
}

/// Which way a Vault is named in a list: its web address or its mesh address.
enum DesktopVaultPath: String, Codable {
    case web
    case mesh
}

/// The outcome of a Vault switch on one or more lists.
enum DesktopVaultListChange: Equatable {
    case tags([[String]])
    /// Nothing may be signed: this list would be left unusable.
    case refused(DesktopVaultList)
}

/// Several Vaults in the public lists (PLANS/NV_DESKTOP_VAULTS_PLAN.md §2.5,
/// rules 1-6). Pure: it works on a list's tags as fetched and returns the
/// tags to sign, so a caller only ever applies one Vault's change to the
/// newest list (rule 7). Fixtures: docs/fixtures/desktop-vaults/lists.json,
/// shared with Android `DesktopVaultsRules` and web `box/public-on-web.js`.
enum DesktopVaultsLists {

    // MARK: Rule 1: which entries are a Vault's

    /// One spelling per web host: scheme, case, path, trailing slash and a
    /// default port (`:443`, `:80`) are folded away. nil for a mesh address
    /// or anything with no host.
    static func hostKey(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.hasPrefix("fipsmesh:") { return nil }
        for scheme in ["wss://", "ws://", "https://", "http://"] where text.hasPrefix(scheme) {
            text.removeFirst(scheme.count)
            break
        }
        if let slash = text.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
            text = String(text[..<slash])
        }
        for port in [":443", ":80"] where text.hasSuffix(port) {
            text.removeLast(port.count)
        }
        return text.isEmpty || text.contains(" ") ? nil : text
    }

    /// The tag name each list uses for its entries.
    static func entryName(_ list: DesktopVaultList) -> String {
        switch list {
        case .relays: return "r"
        case .inbox: return "relay"
        case .media: return "server"
        }
    }

    /// The npub of a mesh entry (a 10002 `fipsmesh` tag or a 10063 mesh
    /// `server`), nil for any other tag.
    static func meshNpub(_ tag: [String], in list: DesktopVaultList) -> String? {
        guard tag.count >= 2 else { return nil }
        switch list {
        case .relays where tag[0] == "fipsmesh", .media where tag[0] == "server":
            guard tag[1].lowercased().hasPrefix("fipsmesh:") else { return nil }
            return HomeVaultLogic.meshNpub(fromInput: tag[1].lowercased())
        default:
            return nil
        }
    }

    /// The host of a web entry, nil for a mesh entry or any other tag.
    static func webHost(_ tag: [String], in list: DesktopVaultList) -> String? {
        guard tag.count >= 2, tag[0] == entryName(list) else { return nil }
        return hostKey(tag[1])
    }

    /// The Vault an entry belongs to, if any. Every other entry is the
    /// user's own and no Vault switch ever touches it.
    static func owner(of tag: [String], in list: DesktopVaultList, vaults: [DesktopVault]) -> DesktopVault? {
        if let npub = meshNpub(tag, in: list) {
            return vaults.first { $0.meshNpub.flatMap(HomeVaultLogic.meshNpub(fromInput:)) == npub }
        }
        if let host = webHost(tag, in: list) {
            return vaults.first { $0.hostKey == host }
        }
        return nil
    }

    /// Whether `vault`'s switch for `path` reads as on in this list.
    static func isListed(_ vault: DesktopVault, path: DesktopVaultPath, in list: DesktopVaultList, tags: [[String]]) -> Bool {
        tags.contains { isEntry($0, of: vault, path: path, in: list) }
    }

    static func isEntry(_ tag: [String], of vault: DesktopVault, path: DesktopVaultPath, in list: DesktopVaultList) -> Bool {
        switch path {
        case .web:
            guard let host = vault.hostKey else { return false }
            return webHost(tag, in: list) == host
        case .mesh:
            guard let npub = vault.meshNpub.flatMap(HomeVaultLogic.meshNpub(fromInput:)) else { return false }
            return meshNpub(tag, in: list) == npub
        }
    }

    /// The entry a switch adds, or nil when this Vault has no such address
    /// or the list takes no such entry (10050 has no mesh entry).
    static func entry(for vault: DesktopVault, path: DesktopVaultPath, in list: DesktopVaultList) -> [String]? {
        switch path {
        case .web:
            guard let host = vault.hostKey else { return nil }
            switch list {
            case .relays: return ["r", "wss://\(host)"]
            case .inbox: return ["relay", "wss://\(host)/inbox"]
            case .media: return ["server", "https://\(host)"]
            }
        case .mesh:
            guard let npub = vault.meshNpub.flatMap(HomeVaultLogic.meshNpub(fromInput:)) else { return nil }
            switch list {
            case .relays: return ["fipsmesh", "fipsmesh://\(npub)/", "write"]
            case .inbox: return nil
            case .media: return ["server", "fipsmesh://\(npub)/"]
            }
        }
    }

    // MARK: Rule 2: order

    private static func before(_ a: DesktopVault, _ b: DesktopVault) -> Bool {
        (a.order, a.id) < (b.order, b.id)
    }

    /// Turns `vault`'s switch on. Its entry goes directly after the other
    /// Vault entries of the same path, in Desktop Vaults order, and in front
    /// of the user's own entries; mesh entries always go last. No existing
    /// entry moves. Already listed: the tags come back unchanged.
    static func turningOn(_ vault: DesktopVault, path: DesktopVaultPath, in list: DesktopVaultList,
                          tags: [[String]], vaults: [DesktopVault]) -> DesktopVaultListChange {
        guard let entry = entry(for: vault, path: path, in: list) else { return .tags(tags) }
        if isListed(vault, path: path, in: list, tags: tags) { return .tags(tags) }
        let isMesh: ([String]) -> Bool = { meshNpub($0, in: list) != nil }
        let firstMesh = tags.firstIndex(where: isMesh) ?? tags.count
        // The other Vaults' entries of this path, with where they sit.
        let placed: [(index: Int, vault: DesktopVault)] = tags.indices.compactMap { i in
            guard isMesh(tags[i]) == (path == .mesh),
                  let other = owner(of: tags[i], in: list, vaults: vaults), other.id != vault.id else { return nil }
            return (i, other)
        }
        var index: Int
        if let later = placed.first(where: { before(vault, $0.vault) }) {
            index = later.index
        } else if let earlier = placed.last {
            index = earlier.index + 1
        } else {
            index = path == .mesh ? tags.count : 0
        }
        // A web entry never lands after a mesh one, even in a list another
        // app left with a Vault entry behind its mesh entries.
        if path == .web { index = min(index, firstMesh) }
        var out = tags
        out.insert(entry, at: index)
        // A mesh entry never makes a list usable on its own (NIP-F1 :94).
        if path == .mesh, !isUsable(out, list: list) { return .refused(list) }
        return .tags(out)
    }

    /// The tags with the Vault entries put in Desktop Vaults order, in the
    /// places Vault entries already hold; the user's own entries stay where
    /// they are. Equal to `tags` when nothing would move, so a drag
    /// republishes only the lists that change.
    static func reordered(_ tags: [[String]], in list: DesktopVaultList, vaults: [DesktopVault]) -> [[String]] {
        var out = tags
        for mesh in [false, true] {
            let slots = tags.indices.filter { i in
                (meshNpub(tags[i], in: list) != nil) == mesh && owner(of: tags[i], in: list, vaults: vaults) != nil
            }
            let sorted = slots.map { tags[$0] }.enumerated().sorted { a, b in
                let va = owner(of: a.element, in: list, vaults: vaults)!
                let vb = owner(of: b.element, in: list, vaults: vaults)!
                if va.id == vb.id { return a.offset < b.offset }
                return before(va, vb)
            }.map(\.element)
            for (slot, tag) in zip(slots, sorted) { out[slot] = tag }
        }
        return out
    }

    // MARK: Rule 5: removal

    /// Whether a list may be signed: 10002 keeps a wss write relay (a mesh
    /// relay doesn't count), 10050 keeps a relay, 10063 keeps an https server.
    static func isUsable(_ tags: [[String]], list: DesktopVaultList) -> Bool {
        switch list {
        case .relays:
            return tags.contains { tag in
                tag.count >= 2 && tag[0] == "r" && tag[1].lowercased().hasPrefix("wss://")
                    && (tag.count < 3 || tag[2] != "read")
            }
        case .inbox:
            return tags.contains { $0.count >= 2 && $0[0] == "relay" && hostKey($0[1]) != nil }
        case .media:
            return tags.contains { $0.count >= 2 && $0[0] == "server" && $0[1].lowercased().hasPrefix("https://") }
        }
    }

    /// Turns `vault`'s switch off: takes its entries of `path` out in every
    /// spelling and nothing else. Taking only mesh entries off is always
    /// allowed; otherwise a list left unusable is refused before signing.
    static func turningOff(_ vault: DesktopVault, path: DesktopVaultPath, in list: DesktopVaultList,
                           tags: [[String]]) -> DesktopVaultListChange {
        let out = tags.filter { !isEntry($0, of: vault, path: path, in: list) }
        guard out.count != tags.count else { return .tags(tags) }
        if path == .web, !isUsable(out, list: list) { return .refused(list) }
        return .tags(out)
    }

    /// Deleting a Vault with "Also take <name> out of your public lists?"
    /// answered yes: every entry of it in every list, checked for all lists
    /// together, so nothing is signed when any one would be left unusable.
    /// Only the lists that change come back.
    static func removingVault(_ vault: DesktopVault, from lists: [DesktopVaultList: [[String]]])
        -> Result<[DesktopVaultList: [[String]]], DesktopVaultListRefusal> {
        var changed: [DesktopVaultList: [[String]]] = [:]
        for list in DesktopVaultList.allCases {
            guard let tags = lists[list] else { continue }
            var current = tags
            for path in [DesktopVaultPath.mesh, .web] {
                switch turningOff(vault, path: path, in: list, tags: current) {
                case .tags(let next): current = next
                case .refused(let list): return .failure(DesktopVaultListRefusal(list: list))
                }
            }
            if current != tags { changed[list] = current }
        }
        return .success(changed)
    }

    // MARK: Rule 4: one host, one Vault

    /// The other Vault that already has `httpsURL`'s host, if any: adding
    /// or changing to that address is refused.
    static func hostTaken(_ httpsURL: String, by vaults: [DesktopVault], except id: String? = nil) -> DesktopVault? {
        guard let host = hostKey(httpsURL) else { return nil }
        return vaults.first { $0.id != id && $0.hostKey == host }
    }

    static func hostTakenMessage(_ vault: DesktopVault) -> String {
        "That address is already your Vault \(vault.displayName)."
    }

    // MARK: Rule 6: size

    /// More entries than other apps are told to use (NIP-65: 4 write relays,
    /// mesh relays not counted; NIP-17: 3 DM relays). No cap, only a note.
    static func overGuidance(_ tags: [[String]], list: DesktopVaultList) -> Bool {
        switch list {
        case .relays:
            return tags.filter { tag in
                tag.count >= 2 && tag[0] == "r" && hostKey(tag[1]) != nil && (tag.count < 3 || tag[2] != "read")
            }.count > 4
        case .inbox:
            return tags.filter { $0.count >= 2 && $0[0] == "relay" }.count > 3
        case .media:
            return false
        }
    }

    static let overGuidanceNote = "Other apps may only use the first few."
}

struct DesktopVaultListRefusal: Error, Equatable {
    let list: DesktopVaultList
    var message: String { list.refusal }
}
