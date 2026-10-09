import Foundation

/// The pure rules behind HomeVaultSender (iOS), kept free of UIKit and app
/// state so MediaLogicTests can check them.

/// The owner's home vault: one of their own kiosk phones on the FIPS mesh.
struct HomeVault: Codable, Equatable {
    /// The account whose notes and media go there (hex).
    var ownerHex: String
    /// The kiosk's mesh npub, from `fipsmesh://<npub>/`.
    var meshNpub: String
}

struct HomeVaultItem: Codable, Equatable, Identifiable {
    enum Kind: String, Codable { case event, blob }
    var kind: Kind
    /// Event id, or the blob's sha256.
    var id: String
    var ownerHex: String
    /// The signed event as JSON (events only).
    var eventJSON: String?
    var contentType: String?
    var added: Date
    var attempts: Int
}

enum HomeVaultSendResult: Equatable {
    case sent
    /// The vault read it and said no: retrying would only say no again.
    case rejected(String)
    /// Never reached the vault, or no answer: try again later.
    case unreachable(String)
}

enum HomeVaultLogic {
    /// `fipsmesh://<npub>/` exactly, or nil — the same strict form readers use.
    static func meshNpub(fromEntry entry: String) -> String? {
        let prefix = "fipsmesh://", suffix = "/"
        guard entry.hasPrefix(prefix), entry.hasSuffix(suffix) else { return nil }
        let npub = String(entry.dropFirst(prefix.count).dropLast(suffix.count))
        let charset = Set("qpzry9x8gf2tvdw0s3jn54khce6mua7l")
        guard npub.count == 63, npub.hasPrefix("npub1"),
              npub.dropFirst(5).allSatisfy({ charset.contains($0) }) else { return nil }
        return npub
    }

    /// The owner's mesh vaults in their server list, minus this phone's own.
    static func meshEntries(serverList: [String], excluding own: String?) -> [String] {
        var seen = Set<String>()
        return serverList.compactMap(meshNpub(fromEntry:)).filter { $0 != own && seen.insert($0).inserted }
    }

    /// Where a new item goes: media ahead of every queued note, so a note
    /// never reaches the vault before the media it points at. nil = append.
    static func insertionIndex(for kind: HomeVaultItem.Kind, in queue: [HomeVaultItem]) -> Int? {
        guard kind == .blob else { return nil }
        return queue.firstIndex(where: { $0.kind == .event })
    }

    /// The mesh's loopback base is `http://127.0.0.1:<port>/<token>`; the outbox
    /// relay is the websocket at the vault's `/`, so it keeps the token path.
    static func websocketURL(base: URL) -> URL? {
        guard var c = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        c.scheme = c.scheme == "https" ? "wss" : "ws"
        return c.url
    }

    /// `["OK", id, accepted, message]` for `id`, as a result; nil for anything else.
    static func okResult(_ text: String, id: String) -> HomeVaultSendResult? {
        guard let data = text.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [Any],
              arr.count >= 3, arr[0] as? String == "OK", arr[1] as? String == id else { return nil }
        let accepted = arr[2] as? Bool ?? false
        let message = arr.count >= 4 ? (arr[3] as? String ?? "") : ""
        // A copy the vault already has is as good as sent.
        if accepted || message.hasPrefix("duplicate:") { return .sent }
        return .rejected(message.isEmpty ? "refused" : message)
    }

    static func uploadResult(status: Int) -> HomeVaultSendResult {
        switch status {
        case 200...299: return .sent
        // Timeout and rate limit are about now, not about the blob. A vault
        // whose mesh door does not take uploads yet (an older kiosk build)
        // answers 404/405: keep the blob for when it does.
        case 404, 405, 408, 429: return .unreachable("HTTP \(status)")
        // The vault answered and said no (auth, size, type).
        case 400...499: return .rejected("HTTP \(status)")
        default: return .unreachable("HTTP \(status)")
        }
    }
}

// MARK: - 10063 merge

extension HomeVaultLogic {
    /// One rule for every phone that publishes the owner's 10063 (Tao, FIPS
    /// thread): merge into the newest list, never replace it. Only the https
    /// servers this phone manages change; every other entry keeps its order.
    ///
    /// - existing: the newest signed 10063 seen for the owner.
    /// - current: this phone's own servers now (config order, https).
    /// - previouslyManaged: what this phone published last time, so a server
    ///   removed here is removed, while another phone's server is kept.
    /// - homeVaultNpub: listed first, if the list still carries it (the kiosk
    ///   withdrew it otherwise, and a stale entry must not come back).
    /// - ownMeshNpub/shareOwnMesh: this phone's mesh entry, listed last while
    ///   it shares (kiosk mode) and dropped otherwise.
    /// Returns nil when the result has no https server: a list only mesh
    /// readers can use must not go out (NIP-F1).
    static func mergeServerList(
        existing: [String],
        current: [String],
        previouslyManaged: Set<String>,
        homeVaultNpub: String?,
        ownMeshNpub: String?,
        shareOwnMesh: Bool
    ) -> [String]? {
        func key(_ url: String) -> String {
            var k = url.trimmingCharacters(in: .whitespaces).lowercased()
            while k.hasSuffix("/") { k.removeLast() }
            return k
        }
        let mine = Set(current.map(key))
        let dropped = Set(previouslyManaged.map(key)).subtracting(mine)
        var out: [String] = []
        var seen = Set<String>()
        func add(_ url: String) {
            if seen.insert(key(url)).inserted { out.append(url) }
        }

        if let home = homeVaultNpub, home != ownMeshNpub,
           existing.contains(where: { meshNpub(fromEntry: $0) == home }) {
            add("fipsmesh://\(home)/")
        }
        current.filter { meshNpub(fromEntry: $0) == nil }.forEach(add)
        for url in existing {
            if let npub = meshNpub(fromEntry: url) {
                if npub != ownMeshNpub { add(url) }
            } else if url.hasPrefix("fipsmesh://") {
                continue  // malformed mesh entry: readers ignore it, so do we
            } else if !dropped.contains(key(url)) {
                add(url)  // another phone's server
            }
        }
        if shareOwnMesh, let own = ownMeshNpub { add("fipsmesh://\(own)/") }

        guard out.contains(where: { meshNpub(fromEntry: $0) == nil }) else { return nil }
        return out
    }
}

// MARK: - Newest 10063 wins

extension HomeVaultLogic {
    /// NIP-01 for replaceable events: the newer created_at wins, and a tie goes
    /// to the lower id. `seen` is the stamp of the list already kept.
    static func isNewer(createdAt: Int64, id: String, than seen: (createdAt: Int64, id: String)?) -> Bool {
        guard let seen else { return true }
        if createdAt != seen.createdAt { return createdAt > seen.createdAt }
        return id < seen.id
    }
}
