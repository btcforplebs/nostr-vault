import Foundation

/// One chip over the Vault list when the device holds more than one account:
/// every account's notifications together, or one account's.
/// Android: VaultAccountChips.kt.
enum VaultAccountChip: Hashable {
    case all
    /// One account, by hex pubkey (lowercase).
    case account(String)
}

/// A Vault line and the account it is for. Two accounts can each have a line
/// with the same id (a day's follows, a like on a post both were tagged in),
/// so the id carries the account.
struct VaultAccountLine: Identifiable, Equatable {
    let account: String
    let line: VaultActivity
    var id: String { account + ":" + line.id }
}

/// The rules behind the chips: which ones show, which accounts a chip's list
/// holds, and how their lines interleave. Nothing changes for one account:
/// no chips, and the list stays the active account's.
enum VaultAccountChips {

    /// "All", the active account, then the others in switcher order. Empty
    /// when there is only one account.
    static func chips(accounts: [String], active: String) -> [VaultAccountChip] {
        let list = unique(accounts)
        guard list.count > 1 else { return [] }
        let me = active.lowercased()
        let ordered = list.contains(me) ? [me] + list.filter { $0 != me } : list
        return [.all] + ordered.map { .account($0) }
    }

    /// The picked chip, or the active account's when none is picked or the
    /// picked account is gone (removed, or the device is down to one).
    static func resolve(_ picked: VaultAccountChip?, accounts: [String], active: String) -> VaultAccountChip {
        let me = VaultAccountChip.account(active.lowercased())
        guard let picked, chips(accounts: accounts, active: active).contains(picked) else { return me }
        return picked
    }

    /// The accounts whose lines the chip's list shows.
    static func accounts(for chip: VaultAccountChip, accounts: [String]) -> [String] {
        switch chip {
        case .all: return unique(accounts)
        case .account(let hex): return [hex.lowercased()]
        }
    }

    /// The active account's own list, exactly as with one account.
    static func isDefault(_ chip: VaultAccountChip, active: String) -> Bool {
        chip == .account(active.lowercased())
    }

    /// Each account's lines in one list, newest first, each marked with its
    /// account. Ties go to the account first in `order`, then by id, so the
    /// list never shuffles between rebuilds.
    static func merge(_ perAccount: [String: [VaultActivity]], order: [String], limit: Int) -> [VaultAccountLine] {
        let rank = Dictionary(unique(order).enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let all = perAccount.flatMap { account, lines in
            lines.map { VaultAccountLine(account: account.lowercased(), line: $0) }
        }
        let sorted = all.sorted { a, b in
            if a.line.createdAt != b.line.createdAt { return a.line.createdAt > b.line.createdAt }
            let ra = rank[a.account] ?? .max, rb = rank[b.account] ?? .max
            if ra != rb { return ra < rb }
            return a.line.id < b.line.id
        }
        return Array(sorted.prefix(max(0, limit)))
    }

    /// Each filter's `limit` for reading another account's lines from the
    /// device's relay: the first read, and each "load more" after it.
    static let otherAccountPage = 300
    /// The relay's MaxLimit (Badger 1000). A bigger limit is not clamped: the
    /// relay answers MaxLimit/4, so the list would shrink.
    static let otherAccountMaxLimit = 1000

    /// The limit for the next "load more" of other accounts' lines, or nil
    /// when there is nothing older to read: no filter came back full, or the
    /// limit is at the relay's cap.
    static func nextOtherAccountLimit(current: Int, readFull: Bool) -> Int? {
        guard readFull, current < otherAccountMaxLimit else { return nil }
        return min(otherAccountMaxLimit, current + otherAccountPage)
    }

    /// The npub to switch to before opening a line that is for another
    /// account, so a reply or like signs as that account (the same switch a
    /// tapped notification makes). Nil for the active account's own lines or
    /// an account the device no longer holds.
    static func switchTarget(lineAccount: String?, active: String, npubByHex: [String: String]) -> String? {
        guard let hex = lineAccount?.lowercased(), !hex.isEmpty, hex != active.lowercased() else { return nil }
        return npubByHex[hex]
    }

    private static func unique(_ list: [String]) -> [String] {
        var seen = Set<String>()
        return list.map { $0.lowercased() }.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
