import Foundation

/// `ConfigService.allAccountHexes`, decoded once per account list. Note rows
/// read it on every redraw, and each read decoded every npub's bech32
/// (Vault review 2026-11-27 #2).
enum AccountHexMemo {
    private static let lock = NSLock()
    private static var lastNpubs: [String] = []
    private static var lastHexes: Set<String> = []

    static func hexes(of npubs: [String]) -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        if npubs == lastNpubs { return lastHexes }
        let hexes = Set(npubs.compactMap { Bech32.decode($0)?.hexString.lowercased() })
        lastNpubs = npubs
        lastHexes = hexes
        return hexes
    }
}
