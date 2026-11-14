import Foundation

/// One chip over the Vault list when the device holds more than one account:
/// every account's notifications together, or one account's.
/// Android: VaultAccountChips.kt.
enum VaultAccountChip: Hashable {
    case all
    /// One account, by hex pubkey (lowercase).
    case account(String)
}

/// The Vault pages, as the account row sees them (the app's ViewMode, kept
/// free of app types for MediaLogicTests).
enum VaultAccountPage {
    case activity, notes, media, likes, zaps, bookmarks, followers, messages
}

/// A Vault line and the accounts it is for. One event that tags several of
/// your accounts (a reply, mention, quote or zap with words) is one line for
/// all of them, its id the event's (Logen 2026-11-05). Folded lines (a day's
/// follows, likes or reposts on a post) are different events per account, so
/// each account keeps its own and the id carries the account.
struct VaultAccountLine: Identifiable, Equatable {
    /// In switcher order; never empty.
    let accounts: [String]
    let line: VaultActivity

    init(account: String, line: VaultActivity) {
        self.init(accounts: [account], line: line)
    }

    init(accounts: [String], line: VaultActivity) {
        self.accounts = accounts
        self.line = line
    }

    /// The first account, the one the line opens as unless another is picked.
    var account: String { accounts.first ?? "" }

    var id: String { VaultAccountChips.isOneEvent(line) ? line.id : account + ":" + line.id }
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

    /// Whether a page shows the chips (Logen 11-02): the Vault list and
    /// Notes, Likes, Zaps and Followers, each filtering what it shows. Media
    /// shows none, nor Bookmarks or Messages: each is the active account's only.
    static func pageShowsChips(_ page: VaultAccountPage) -> Bool {
        page != .media && page != .bookmarks && page != .messages
    }

    /// The posts `account` liked or zapped (kind 7 it signed, zap receipts
    /// whose sender tag `P` is it): My Likes and My Zaps list those, so they
    /// are read with the account's other events.
    static func givenTargets(_ events: [(pubkey: String, kind: Int, tags: [[String]])], account: String) -> Set<String> {
        let me = account.lowercased()
        var out = Set<String>()
        for e in events {
            let given = (e.kind == 7 && e.pubkey.lowercased() == me)
                || (e.kind == 9735 && e.tags.contains { $0.count >= 2 && $0[0] == "P" && $0[1].lowercased() == me })
            guard given, let target = e.tags.first(where: { $0.count >= 2 && $0[0] == "e" })?[1] else { continue }
            out.insert(target)
        }
        return out
    }

    /// Several accounts' followers in one list, as one ledger orders them:
    /// follows we watched happen (newest first), then earlier ones (newest
    /// list first). Someone following two of them is listed once.
    static func mergeFollowers<T>(_ lists: [[T]], id: (T) -> String, isNews: (T) -> Bool,
                                  followedAt: (T) -> Int64, listAt: (T) -> Int64) -> [T] {
        var seen = Set<String>()
        let all = lists.joined().filter { seen.insert(id($0)).inserted }
        let watched = all.filter(isNews).sorted { followedAt($0) > followedAt($1) }
        let earlier = all.filter { !isNews($0) }.sorted { listAt($0) > listAt($1) }
        return watched + earlier
    }

    /// Whose a listed post is, among the accounts the chip shows: its author,
    /// else the first one it tags, else whoever of them liked or zapped it
    /// (`giver`). Nil when that is the active account (it opens as is).
    static func pageAccount(author: String, tags: [[String]], giver: String?, owners: Set<String>, active: String) -> String? {
        let me = active.lowercased()
        let who: String?
        if owners.contains(author.lowercased()) {
            who = author.lowercased()
        } else if let tagged = tags.first(where: { $0.count >= 2 && $0[0] == "p" && owners.contains($0[1].lowercased()) })?[1] {
            who = tagged.lowercased()
        } else {
            who = giver?.lowercased()
        }
        return who == me ? nil : who
    }

    /// Whether picking `chip` must wait for a read: it shows another account
    /// whose lines aren't read yet. Until then the list on screen stays and
    /// only the ring moves, so a pick never flashes a spinner or an empty list.
    static func needsRead(_ chip: VaultAccountChip, accounts: [String], active: String, loaded: Set<String>) -> Bool {
        let me = active.lowercased()
        return Self.accounts(for: chip, accounts: accounts).contains { $0 != me && !loaded.contains($0) }
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

    /// Whether the line is one event, the same event for every account it
    /// tagged: a reply, mention, quote, article, highlight, or a zap with its
    /// own line. Folded lines ("reaction-", "repost-", "zap-", "follow-")
    /// gather different events per account.
    static func isOneEvent(_ line: VaultActivity) -> Bool {
        switch line.kind {
        case .reply, .mention, .quote, .article, .highlight: return true
        case .zap: return !line.id.hasPrefix("zap-")
        case .reaction, .repost, .follow: return false
        }
    }

    /// Each account's lines in one list, newest first, each marked with its
    /// accounts: one event that tagged several of them is one line. Ties go
    /// to the account first in `order`, then by id, so the list never
    /// shuffles between rebuilds.
    static func merge(_ perAccount: [String: [VaultActivity]], order: [String], limit: Int) -> [VaultAccountLine] {
        let rank = Dictionary(unique(order).enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        // Accounts in switcher order, so a shared line's first account is the
        // one first in the switcher.
        let accounts = perAccount.keys.map { $0.lowercased() }.sorted {
            let ra = rank[$0] ?? .max, rb = rank[$1] ?? .max
            return ra != rb ? ra < rb : $0 < $1
        }
        var lines: [String: [VaultActivity]] = [:]
        for (account, list) in perAccount { lines[account.lowercased(), default: []] += list }
        var all: [VaultAccountLine] = []
        var shared: [String: Int] = [:]
        for account in accounts {
            for line in lines[account] ?? [] {
                guard isOneEvent(line) else {
                    all.append(VaultAccountLine(account: account, line: line))
                    continue
                }
                if let i = shared[line.id] {
                    if !all[i].accounts.contains(account) {
                        all[i] = VaultAccountLine(accounts: all[i].accounts + [account], line: all[i].line)
                    }
                } else {
                    shared[line.id] = all.count
                    all.append(VaultAccountLine(account: account, line: line))
                }
            }
        }
        let sorted = all.sorted { a, b in
            if a.line.createdAt != b.line.createdAt { return a.line.createdAt > b.line.createdAt }
            let ra = rank[a.account] ?? .max, rb = rank[b.account] ?? .max
            if ra != rb { return ra < rb }
            return a.line.id < b.line.id
        }
        return Array(sorted.prefix(max(0, limit)))
    }

    // MARK: Steady switch (Logen 2026-11-14: switching accounts should be instant)

    /// A re-read folded into what is held: what it read wins by id, what it
    /// didn't read stays, newest first (ties by id, as `VaultActivity.build`
    /// sorts). A re-read only adds and updates, so the list never reshuffles
    /// under the finger, and a read that came back empty (the relay's port
    /// closed after a return) takes nothing away.
    static func topUp<T>(held: [T], read: [T], id: (T) -> String, at: (T) -> Int64) -> [T] {
        let readIds = Set(read.map(id))
        let kept = held.filter { !readIds.contains(id($0)) }
        return (read + kept).sorted { at($0) != at($1) ? at($0) > at($1) : id($0) < id($1) }
    }

    /// Whether a badge change is news for the accounts on show: a count went
    /// up. A chip tap marks its accounts seen, which drops their counts; that
    /// is not a reason to read again.
    static func countRose(among accounts: [String], before: (String) -> Int, after: (String) -> Int) -> Bool {
        accounts.contains { after($0) > before($0) }
    }

    /// The people the first screen of lines names and pictures: the first
    /// `rows` lines' leading actors. Their profiles are asked for, and briefly
    /// waited on, before a picked chip's list shows, so names don't pop in.
    static func firstScreenActors(_ lines: [VaultActivity], rows: Int = firstScreenRows) -> [String] {
        var seen = Set<String>()
        return lines.prefix(rows).flatMap { $0.actors.prefix(3) }.filter { seen.insert($0).inserted }
    }

    static let firstScreenRows = 20
    /// The longest a pick waits for those profiles; past it the list shows
    /// and the rest fill in.
    static let profileWait: TimeInterval = 0.8

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
