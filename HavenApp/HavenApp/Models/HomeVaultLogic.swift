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
