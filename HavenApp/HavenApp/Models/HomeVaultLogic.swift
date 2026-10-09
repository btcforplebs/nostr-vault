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
    /// event and blob go to the home vault over the mesh; mirror is the
    /// public upload of a blob the note already links to (kiosk-only blob).
    enum Kind: String, Codable { case event, blob, mirror }
    var kind: Kind
    /// Event id, or the blob's sha256.
    var id: String
    var ownerHex: String
    /// The signed event as JSON (events only).
    var eventJSON: String?
    var contentType: String?
    var added: Date
    var attempts: Int
    /// Not before this (per-item backoff). Optional: older queues lack it.
    var notBefore: Date?
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
        // About now, not about the event (NIP-01 prefixes). The mesh door
        // never asks for AUTH today; if it ever does, posts wait, not vanish.
        for transient in ["rate-limited:", "error:", "auth-required:"] where message.hasPrefix(transient) {
            return .unreachable(message)
        }
        // Includes "restricted:", the door's answer to anyone but the owner.
        return .rejected(message.isEmpty ? "refused" : message)
    }

    static func uploadResult(status: Int) -> HomeVaultSendResult {
        switch status {
        case 200...299: return .sent
        // Timeout and rate limit are about now, not about the blob. A vault
        // whose mesh door does not take uploads yet (an older kiosk build)
        // answers 404/405: keep the blob for when it does.
        case 404, 405, 408, 429: return .unreachable("HTTP \(status)")
        // The vault answered and said no: 403 not the owner, 411 no length,
        // 413 over the door's 256 MB.
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
    /// NIP-F1 order: public servers first, mesh entries after them (Tao's call;
    /// senders pick the home vault from the setting, not from list order).
    ///
    /// - existing: the newest signed 10063 seen for the owner.
    /// - current: this phone's own servers now (config order, https).
    /// - previouslyManaged: what this phone published last time, so a server
    ///   removed here is removed, while another phone's server is kept.
    /// - ownMeshNpub/shareOwnMesh: this phone's mesh entry, listed last while
    ///   it shares (kiosk mode) and dropped otherwise.
    /// Returns nil when the result has no https server: a list only mesh
    /// readers can use must not go out (NIP-F1).
    static func mergeServerList(
        existing: [String],
        current: [String],
        previouslyManaged: Set<String>,
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

        current.filter { !$0.hasPrefix("fipsmesh://") }.forEach(add)
        for url in existing where !url.hasPrefix("fipsmesh://") && !dropped.contains(key(url)) {
            add(url)  // another phone's server
        }
        for url in existing {
            // Malformed mesh entries are dropped: readers ignore them too.
            if let npub = meshNpub(fromEntry: url), npub != ownMeshNpub { add(url) }
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

// MARK: - Retry, give up, and the kiosk-only link

extension HomeVaultLogic {
    static let maxAttempts = 40
    static let maxAge: TimeInterval = 14 * 24 * 3600

    /// 1 min, doubling, up to 6 h: a kiosk that is off for a day costs a
    /// handful of tries, not one a minute (and not a signer prompt a minute).
    static func backoff(afterAttempts attempts: Int) -> TimeInterval {
        let minutes = pow(2.0, Double(max(attempts - 1, 0)))
        return min(60 * minutes, 6 * 3600)
    }

    /// Too old or tried too often: give up on it (logged, not silent).
    static func isExpired(_ item: HomeVaultItem, now: Date) -> Bool {
        item.attempts >= maxAttempts || now.timeIntervalSince(item.added) > maxAge
    }

    /// The link a note carries when only this phone and the kiosk hold the
    /// blob: where it will be once the public upload goes through (BUD-01
    /// `/<sha256>.<ext>`). Never a fipsmesh or loopback address (Tao).
    static func publicBlobURL(server: String, sha256: String, contentType: String) -> URL? {
        guard server.hasPrefix("https://"), !server.contains(".fips") else { return nil }
        var base = server
        while base.hasSuffix("/") { base.removeLast() }
        let ext: String
        switch contentType.lowercased() {
        case "image/jpeg", "image/jpg": ext = ".jpg"
        case "image/png": ext = ".png"
        case "image/gif": ext = ".gif"
        case "image/webp": ext = ".webp"
        case "image/heic": ext = ".heic"
        case "video/mp4": ext = ".mp4"
        case "video/quicktime": ext = ".mov"
        case "video/webm": ext = ".webm"
        case "audio/mpeg": ext = ".mp3"
        default: ext = ""
        }
        return URL(string: "\(base)/\(sha256)\(ext)")
    }
}
