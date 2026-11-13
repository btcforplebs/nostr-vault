import Foundation

/// Each account's new notifications since its Vault list was last viewed: the
/// number on that account's row in the account switcher.
///
/// The vault serves every account on the device, and each NOTIFY marker names
/// the account it is for (`recipient=<hex>`, haven-go import.go
/// emitInboxNotify), or every one of your accounts it tagged
/// (`recipients=<hex>,<hex>`). The event counts once for each of them, and a
/// marker raised twice counts once. Viewing an account's Vault list empties its count, the same
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

    /// The accounts and event a marker body (the text after `🔔NOTIFY|`) is
    /// for, or nil when it does not count.
    static func parse(_ body: String) -> (recipients: [String], id: String, type: String, author: String)? {
        let fields = fields(of: body)
        let recipients = recipients(in: fields)
        guard let type = fields["type"], countedTypes.contains(type),
              !recipients.isEmpty,
              let id = fields["id"], !id.isEmpty
        else { return nil }
        return (recipients, id, type, fields["author"]?.lowercased() ?? "")
    }

    /// A marker's fields. The preview is last and may hold "|" or "=", so it
    /// is cut off first and can't forge one.
    private static func fields(of body: String) -> [String: String] {
        let head = body.range(of: "|preview=").map { String(body[..<$0.lowerBound]) } ?? body
        var fields: [String: String] = [:]
        for part in head.split(separator: "|") {
            guard let eq = part.firstIndex(of: "=") else { continue }
            fields[String(part[..<eq])] = String(part[part.index(after: eq)...])
        }
        return fields
    }

    /// `recipients=` when the relay names every account it tagged, then
    /// `recipient=`; each once, hex only.
    private static func recipients(in fields: [String: String]) -> [String] {
        let listed = (fields["recipients"] ?? "").split(separator: ",").map { String($0) }
        var seen = Set<String>()
        return (listed + [fields["recipient"] ?? ""])
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { isHex64($0) && seen.insert($0).inserted }
    }

    /// The inbox kinds in a batch that came in only as one of your accounts
    /// tagging another (`isOwnAccountTag(recipient, author)`), so the Vault
    /// tab's red dot can leave them out the way the list does. A kind that
    /// also came from anyone else stays.
    static func ownAccountOnlyKinds(markers: [String], isOwnAccountTag: (String, String) -> Bool) -> Set<Int> {
        var own = Set<Int>(), other = Set<Int>()
        for body in markers {
            let fields = fields(of: body)
            guard let kind = fields["kind"].flatMap(Int.init) else { continue }
            let author = fields["author"]?.lowercased() ?? ""
            // Own-account-only when it is that for every account it tagged.
            let recipients = recipients(in: fields)
            if (recipients.isEmpty ? [""] : recipients).allSatisfy({ isOwnAccountTag($0, author) }) {
                own.insert(kind)
            } else {
                other.insert(kind)
            }
        }
        return own.subtracting(other)
    }

    /// What the Vault list drops before it draws a line, so the count only
    /// counts what that list can show (sweep 11-01 #11): a like in Zaps Only
    /// mode, anything from a blocked person, and a mention, reply or quote
    /// from outside your Web of Trust (VaultActivity.build's `isBlocked` /
    /// `isOutside`, and VaultDataProcessing's Zaps Only filter).
    struct ListRules {
        var zapsOnly = false
        /// (recipient hex, author hex) → blocked by that account.
        var isBlocked: (String, String) -> Bool = { _, _ in false }
        /// (recipient hex, author hex) → outside that account's web.
        var isOutside: (String, String) -> Bool = { _, _ in false }
        /// (recipient hex, author hex) → one of your accounts tagging another
        /// with that switch off (NotificationPolicy.hidesOwnAccountTag).
        var isOwnAccountTag: (String, String) -> Bool = { _, _ in false }

        static let showsAll = ListRules()

        func shows(type: String, author: String, recipient: String) -> Bool {
            if zapsOnly && type == "reaction" { return false }
            guard !author.isEmpty else { return true }
            if isBlocked(recipient, author) { return false }
            if isOwnAccountTag(recipient, author) { return false }
            if Self.webGatedTypes.contains(type) && isOutside(recipient, author) { return false }
            return true
        }

        /// The lines VaultActivity.build checks `isOutside` for: likes and
        /// reposts fold out of the list since 2026-11-13 (`foldsOutsideLikes`).
        /// Zaps and follows on your own notes are not gated.
        static let webGatedTypes: Set<String> = ["reply", "quote", "mention", "reaction", "repost"]
    }

    /// Counts the marker, once for each account it is for whose list shows
    /// it. Returns whether anything changed.
    @discardableResult
    mutating func record(_ body: String, rules: ListRules = .showsAll) -> Bool {
        guard let (recipients, id, type, author) = Self.parse(body) else { return false }
        var changed = false
        for recipient in recipients where rules.shows(type: type, author: author, recipient: recipient) {
            var list = ids[recipient] ?? []
            guard !list.contains(id) else { continue }
            list.append(id)
            if list.count > Self.cap { list.removeFirst(list.count - Self.cap) }
            ids[recipient] = list
            changed = true
        }
        return changed
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
