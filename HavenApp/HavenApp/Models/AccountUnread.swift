import Foundation

/// Each account's new notifications since its Vault list was last viewed: the
/// number on that account's row in the account switcher.
///
/// The vault serves every account on the device, and each NOTIFY marker names
/// the account it is for (`recipient=<hex>`, haven-go import.go
/// emitInboxNotify). Markers are counted by event id, so a marker raised twice
/// counts once. Viewing an account's Vault list empties its count, the same
/// moment that list moves its own "seen" mark (`vaultActivitySeenAt.<hex>`).
/// Android: AccountUnread.kt.
struct AccountUnread: Equatable {
    /// Ids kept per account. The badge reads "99+" long before this.
    static let cap = 200

    /// The marker types that become lines in the Vault list. DMs are read and
    /// cleared in Messages, and the catch-up summary names no account.
    static let countedTypes: Set<String> = ["reply", "quote", "mention", "reaction", "repost", "zap", "follow"]

    /// Account hex → unseen event ids, oldest first.
    private(set) var ids: [String: [String]]

    init(ids: [String: [String]] = [:]) {
        self.ids = ids
    }

    /// The account and event a marker body (the text after `🔔NOTIFY|`) is
    /// for, or nil when it does not count.
    static func parse(_ body: String) -> (recipient: String, id: String)? {
        // The preview is last and may hold "|" or "=": cut it off first.
        let head = body.range(of: "|preview=").map { String(body[..<$0.lowerBound]) } ?? body
        var fields: [String: String] = [:]
        for part in head.split(separator: "|") {
            guard let eq = part.firstIndex(of: "=") else { continue }
            fields[String(part[..<eq])] = String(part[part.index(after: eq)...])
        }
        guard let type = fields["type"], countedTypes.contains(type),
              let recipient = fields["recipient"]?.lowercased(), isHex64(recipient),
              let id = fields["id"], !id.isEmpty
        else { return nil }
        return (recipient, id)
    }

    /// Counts the marker. Returns whether anything changed.
    @discardableResult
    mutating func record(_ body: String) -> Bool {
        guard let (recipient, id) = Self.parse(body) else { return false }
        var list = ids[recipient] ?? []
        guard !list.contains(id) else { return false }
        list.append(id)
        if list.count > Self.cap { list.removeFirst(list.count - Self.cap) }
        ids[recipient] = list
        return true
    }

    /// The account's Vault list was viewed. Returns whether anything changed.
    @discardableResult
    mutating func markSeen(_ hex: String) -> Bool {
        ids.removeValue(forKey: hex.lowercased()) != nil
    }

    func count(for hex: String) -> Int {
        ids[hex.lowercased()]?.count ?? 0
    }

    /// Whether an account other than the active one has news: the dot on the
    /// tab-bar / sidebar avatar. Only `accounts` (the hex keys still signed
    /// in) are asked, so a removed account's leftover ids can't hold the dot
    /// up with no row left to clear them.
    func othersHaveUnread(accounts: [String], active: String) -> Bool {
        let active = active.lowercased()
        return accounts.contains { $0.lowercased() != active && count(for: $0) > 0 }
    }

    /// Where an account's Vault list keeps the time it was last viewed (unix
    /// seconds); lines newer than it draw as unread.
    static func vaultSeenKey(_ hex: String) -> String { "vaultActivitySeenAt.\(hex)" }

    /// The badge text: nothing at zero, "99+" past 99.
    static func badge(_ count: Int) -> String? {
        count <= 0 ? nil : count > 99 ? "99+" : String(count)
    }

    private static func isHex64(_ s: String) -> Bool {
        s.count == 64 && s.allSatisfy { $0.isHexDigit }
    }
}
