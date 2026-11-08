import Foundation

/// The vault reads only the owner's own relay list (Logen 2026-11-08): their
/// read relays, their write relays, and any extra importing relays they
/// picked themselves. There is no hidden seed list any more. Builds before
/// this filled `importSeedRelays` with a fixed four or five public relays
/// the owner never chose. Twin of Android's VaultSeedRelays.kt.
///
/// Pure Foundation so MediaLogicTests can test it.
enum VaultSeedRelays {
    /// The import seed lists earlier builds shipped as defaults (iOS and
    /// Android, every version since 2026-10). A saved list holding only these
    /// was never the owner's choice.
    static let legacyImportDefaults: Set<String> = [
        "wss://relay.primal.net",
        "wss://relay.damus.io",
        "wss://relay.btcforplebs.com",
        "wss://nostr-pub.wellorder.net",
        "wss://nos.lol",
        "wss://nostr.mom",
        "wss://relay.snort.social",
    ]

    /// What the vault reads from: read relays, then write relays, then the
    /// owner's own extra picks, de-duplicated (trailing slash and case
    /// ignored), in that order.
    static func vaultSeeds(read: [String], write: [String], chosen: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in read + write + chosen {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(key(trimmed)).inserted else { continue }
            out.append(trimmed)
        }
        return out
    }

    /// The importing relays the owner picked, from a saved list: their own
    /// read and write relays and the Mac relay are left out (the vault reads
    /// those anyway), and a remainder made only of old defaults is dropped.
    static func chosenImportRelays(_ saved: [String], own: [String], mac: String) -> [String] {
        let ownKeys = Set(own.map(key))
        let macKey = mac.isEmpty ? nil : key(mac)
        let rest = saved.filter { url in
            let k = key(url)
            return !k.isEmpty && !ownKeys.contains(k) && k != macKey
        }
        let legacy = Set(legacyImportDefaults.map(key))
        if rest.allSatisfy({ legacy.contains(key($0)) }) { return [] }
        return rest
    }

    private static func key(_ url: String) -> String {
        var k = url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while k.hasSuffix("/") { k.removeLast() }
        return k
    }
}
