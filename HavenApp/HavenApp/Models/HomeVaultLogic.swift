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
    /// For a public copy: the server the published note names. Only that
    /// server having the blob clears the item. For a blob: the public server
    /// the vault passes it on to (photos through the Mac). Optional: older
    /// queues lack it.
    var server: String? = nil
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

    /// A kiosk's mesh address as pasted or scanned: `npub1…`, `nostr:npub1…`
    /// or `fipsmesh://npub1…/`. Nil for anything else.
    static func meshNpub(fromInput input: String) -> String? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("nostr:") { text = String(text.dropFirst(6)) }
        if !text.hasPrefix("fipsmesh://") { text = "fipsmesh://\(text)/" }
        if !text.hasSuffix("/") { text += "/" }
        return meshNpub(fromEntry: text)
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
        // 409: the vault already spent this auth (#475 takes each id once);
        // a fresh one may succeed, so it is not a no to the blob.
        // 400: the door could not read this try (a cut body, a bad token),
        // or Go's answer to plain HTTP on a TLS port (a kiosk build without
        // the own-devices port): about this attempt, not about the blob.
        case 400, 404, 405, 408, 409, 429: return .unreachable("HTTP \(status)")
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
    /// - current: this phone's own servers now (config order, https), plus
    ///   its home vault's `fipsmesh://` entry, listed after the others.
    /// - previouslyManaged: what this phone published last time, so a server
    ///   removed here is removed, while another phone's server is kept.
    /// - ownMeshNpub: this device's own (main) mesh npub. Never listed, and
    ///   dropped if an older list carried it: the main node is for the owner's
    ///   own devices only, so naming it in public is never right (Logen, FIPS
    ///   photos, 2026-10-21).
    /// - photoNpub: the photo node's npub (the Mac's blob node, which serves
    ///   photos by hash to anyone), listed last. Nil lists nothing: there is no
    ///   fallback to the main npub.
    /// Returns nil when the result has no https server: a list only mesh
    /// readers can use must not go out (NIP-F1).
    static func mergeServerList(
        existing: [String],
        current: [String],
        previouslyManaged: Set<String>,
        ownMeshNpub: String?,
        photoNpub: String? = nil
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
        for url in existing where !dropped.contains(key(url)) {
            // Malformed mesh entries are dropped: readers ignore them too.
            if let npub = meshNpub(fromEntry: url), npub != ownMeshNpub { add(url) }
        }
        for url in current {
            // This phone's home vault: the sender lists it, the kiosk needs no key.
            if let npub = meshNpub(fromEntry: url), npub != ownMeshNpub { add(url) }
        }
        if let photo = photoNpub.flatMap({ meshNpub(fromInput: $0) }), photo != ownMeshNpub { add("fipsmesh://\(photo)/") }

        // A list naming only home-network servers must not go out either: no
        // reader outside could open one, and it would publish the home address.
        guard out.contains(where: isPublicServer) else { return nil }
        return out
    }

    /// The mesh entries a phone lists in its owner's 10063: the home vault it
    /// sends to, and the Mac it is linked to by mesh npub. A phone with the
    /// owner's key lists the Mac, so a Mac with no key is still named (Logen,
    /// 2026-10-21). Only the active account's own devices.
    static func phoneMeshEntries(homeVault: HomeVault?, macMeshNpub: String?, ownerHex: String) -> [String] {
        guard !ownerHex.isEmpty else { return [] }
        var out: [String] = []
        if let vault = homeVault, vault.ownerHex == ownerHex { out.append("fipsmesh://\(vault.meshNpub)/") }
        if let mac = macMeshNpub.flatMap({ meshNpub(fromInput: $0) }) { out.append("fipsmesh://\(mac)/") }
        return out
    }

    /// The mesh entries this phone listed last time that are still in My
    /// Devices. Switching the home vault must not unlist the old one while it
    /// is still the owner's device (2026-10-22: Mac to Moto dropped the Mac),
    /// so the phone keeps managing it; removing it from My Devices unlists it.
    static func stillOwnedMeshEntries(previouslyManaged: [String], myDevices: [String]) -> [String] {
        let devices = Set(myDevices.compactMap { meshNpub(fromInput: $0) })
        return previouslyManaged.filter { meshNpub(fromEntry: $0).map(devices.contains) ?? false }
    }

    /// The photo node the Mac lists: its mesh npub only while its engine runs.
    /// The engine starts only with a device in My Devices, so the switch on
    /// with none added (or a start that failed) lists nothing: an entry
    /// there would point readers at a node nobody can reach.
    static func macPhotoNpub(_ npub: String?, engineRunning: Bool) -> String? {
        engineRunning ? npub : nil
    }

    /// Whether the owner's kept 10063 still lacks the photo node, so the Mac
    /// should republish. Nil list (none seen yet) or no photo node: no.
    static func photoNodeMissing(from kept: [String]?, photoNpub: String?) -> Bool {
        guard let kept, let photo = photoNpub.flatMap({ meshNpub(fromInput: $0) }) else { return false }
        return !kept.contains { meshNpub(fromEntry: $0) == photo }
    }

    /// A server a reader without FIPS can reach: not a `fipsmesh://` entry, and
    /// not an `http(s)://….fips` host either, which only resolves on the mesh
    /// (Tara's NIP-F1 check). isPublicServer builds on it.
    static func isReachableWithoutMesh(_ url: String) -> Bool {
        guard meshNpub(fromEntry: url) == nil, !url.lowercased().hasPrefix("fipsmesh:") else { return false }
        guard let host = URLComponents(string: url.trimmingCharacters(in: .whitespaces))?.host?.lowercased(), !host.isEmpty else {
            return false
        }
        var h = host
        while h.hasSuffix(".") { h.removeLast() }
        return !(h == "fips" || h.hasSuffix(".fips"))
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

    /// Whether a 10063 may replace the list kept for its author, and so pick
    /// the mesh node a photo is read from: only one its author signed (a relay
    /// can serve any event under any pubkey), and only if it is newer than the
    /// one kept. An unsigned one never even moves the stamp, so a forged "newer"
    /// list cannot shut the real one out (Tara's NIP-F1 check).
    static func keepsServerList(signedByAuthor: Bool, createdAt: Int64, id: String, than seen: (createdAt: Int64, id: String)?) -> Bool {
        signedByAuthor && isNewer(createdAt: createdAt, id: id, than: seen)
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

    /// Too old or tried too often: give up on it (logged, not silent). Age
    /// only counts once it has been tried: a clock that jumps forward must
    /// not delete what was queued a minute ago and never sent (Tron, #472).
    static func isExpired(_ item: HomeVaultItem, now: Date) -> Bool {
        item.attempts >= maxAttempts || (item.attempts > 0 && now.timeIntervalSince(item.added) > maxAge)
    }

    /// How long the vault may keep retrying a public upload for the phone.
    static let forwardAuthLifetime: TimeInterval = 6 * 3600

    /// When the phone first checks the public server itself after asking the
    /// vault to pass a photo on, and uploads it only if it is still missing.
    static let forwardFallbackDelay: TimeInterval = 15 * 60

    /// Signer prompts one Send now tap may cause with a bunker signer.
    static let maxPromptsPerTap = 10

    /// The link a note carries when only this phone and the kiosk hold the
    /// blob: where it will be once the public upload goes through (BUD-01
    /// `/<sha256>.<ext>`). Never a fipsmesh or loopback address (Tao).
    static func publicBlobURL(server: String, sha256: String, contentType: String) -> URL? {
        guard isPublicServer(server) else { return nil }
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

extension HomeVaultLogic {
    /// Public means reachable by any reader: not a mesh name, not a home
    /// network or Tailscale host, which would also tell readers about it.
    static func isPublicServer(_ server: String) -> Bool {
        guard server.hasPrefix("https://"), !server.contains(".fips"), isReachableWithoutMesh(server),
              let host = URL(string: server)?.host else { return false }
        return !HavenConfig.isPrivateNetworkHost(host)
    }

    /// Where media goes over the mesh: the kiosk picked as home vault, else
    /// the owner's Mac when it is set by its mesh npub (photos through the
    /// Mac, Logen 2026-10-21). Notes never use the Mac this way: the relay
    /// already sends them to the Mac relay.
    static func mediaVault(homeVault: HomeVault?, macMeshNpub: String?, ownerHex: String) -> HomeVault? {
        if let homeVault { return homeVault }
        guard let macMeshNpub, !ownerHex.isEmpty else { return nil }
        return HomeVault(ownerHex: ownerHex, meshNpub: macMeshNpub)
    }

    /// The public server the vault passes a photo on to, when this phone has
    /// none of its own: the first public entry of the owner's media server
    /// list (10063). nil while the phone has servers (it uploads itself).
    static func forwardServer(phoneMirrors: [String], ownerServerList: [String]) -> String? {
        guard phoneMirrors.isEmpty else { return nil }
        return ownerServerList.first(where: isPublicServer)
    }

    /// The first configured server a public note may name, if any.
    static func linkServer(mirrors: [String], sha256: String, contentType: String) -> String? {
        mirrors.first { publicBlobURL(server: $0, sha256: sha256, contentType: contentType) != nil }
    }
}

extension HomeVaultLogic {
    /// How long the owner's signed check of one blob is good for.
    static let vaultCheckAuthLifetime: TimeInterval = 300

    /// Tags of the owner's kind 24242 "get" for `sha256`. The mesh door
    /// serves an unposted blob only to such a request (haven-go
    /// mesh_safety.go); unsigned, the check answers 404 and the phone sends
    /// a photo the vault already has.
    static func vaultCheckAuthTags(sha256: String, now: Date = Date()) -> [[String]] {
        [["t", "get"], ["x", sha256],
         ["expiration", String(Int(now.timeIntervalSince1970 + vaultCheckAuthLifetime))]]
    }

    /// Only a key on this phone signs the check. A remote signer would ask
    /// the owner to approve a "get" for every photo they post.
    static func signsVaultCheck(signingMode: String) -> Bool {
        signingMode != "nip46"
    }

    /// HEAD /<sha256> on the vault, signed when `authBase64` is given.
    static func vaultCheckRequest(sha256: String, base: URL, authBase64: String?) -> URLRequest {
        var request = URLRequest(url: base.appendingPathComponent(sha256))
        request.httpMethod = "HEAD"
        request.timeoutInterval = 20
        if let authBase64 {
            request.setValue("Nostr \(authBase64)", forHTTPHeaderField: "Authorization")
        }
        return request
    }
}

/// The owner's signed "get" per blob, kept while it is still good, so a blob
/// is signed for once rather than on every check of it.
struct VaultCheckAuths {
    /// Signed again this long before expiry, so a check never carries an
    /// auth that runs out on its way to the vault.
    static let renewMargin: TimeInterval = 60

    private var byBlob: [String: (auth: String, expires: Date)] = [:]

    func auth(for sha256: String, now: Date = Date()) -> String? {
        guard let kept = byBlob[sha256], kept.expires.timeIntervalSince(now) > Self.renewMargin else { return nil }
        return kept.auth
    }

    mutating func remember(_ auth: String, for sha256: String, now: Date = Date()) {
        byBlob = byBlob.filter { $0.value.expires > now }
        byBlob[sha256] = (auth, now.addingTimeInterval(HomeVaultLogic.vaultCheckAuthLifetime))
    }
}
