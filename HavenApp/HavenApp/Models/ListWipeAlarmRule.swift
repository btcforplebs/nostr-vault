import Foundation

/// When a new version of a list looks like another app clobbered it: a
/// wipe, a same-size swap for other entries, or a drain in steps. The rule
/// is docs/LIST_WIPE_ALARM.md, shared with Android (ListWipeAlarmRule.kt) and
/// the web app (net/list-wipe-alarm.js) through
/// Fixtures/ListAlarm/alarm-cases.json. Pure.
enum ListWipeAlarmRule {
    enum How: String, Equatable { case emptied, swapped, drained, shrank }

    struct Alarm: Equatable {
        let before: ListVersion
        let after: ListVersion
        let how: How
        let from: Int
        let to: Int
        let lost: Int
        let client: String?
        /// The client name says Nostr Vault, but this device didn't sign it.
        let claimsNostrVault: Bool
    }

    static let lookback = 5
    /// The smallest list an alarm is raised for (ListHistory.bannerMinItems).
    static let minItems = 3

    /// `b` is a clobber of `a`, judged by which entries survive.
    static func clobbered(_ a: ListVersion, _ b: ListVersion) -> Bool {
        let ia = ListShrinkRule.items(a), ib = ListShrinkRule.items(b)
        let n = ia.count, kept = ia.intersection(ib).count
        if n > 0 && ib.isEmpty { return true }
        if n >= ListShrinkRule.minItems && kept * 2 < n { return true }
        if ListShrinkRule.encryptedKinds.contains(a.kind) {
            let la = a.content.count, lb = b.content.count
            if la > 0 && lb == 0 { return true }
            if la >= ListShrinkRule.minContent && lb * 2 < la { return true }
        }
        return false
    }

    /// How many of the newest versions are judged (haven-go listHistoryKeep).
    static let history = 20

    /// The list's alarm: the newest clobber among the newest `history`
    /// versions, skipping versions Nostr Vault signed (`own`). It sticks
    /// through later saves (Tron, #1635) until it is dismissed, or a newer
    /// version holds the list from before again (a Recover, or a rebuild).
    static func alarm(_ newestFirst: [ListVersion], own: Set<String>, dismissed: Set<String>) -> Alarm? {
        let v = newestFirst
        for k in 0..<min(history, v.count) where !own.contains(v[k].id) {
            guard let a = judge(v, k, own: own) else { continue }
            if dismissed.contains(v[k].id) { return nil }
            if v[0..<k].contains(where: { ListShrinkRule.holds($0, a.before) }) { return nil }
            return a
        }
        return nil
    }

    /// The versions among the newest `history` that this rule calls a
    /// clobber (a wipe, a swap or a step of a drain), skipping the ones Nostr
    /// Vault signed (`own`). List backups flags these, so a list drained in
    /// halves (40 -> 20 -> 10 -> 5), where no single step halves it, is
    /// flagged where the banner says it was (ListShrinkRule.shrank alone
    /// flagged none).
    static func flagged(_ newestFirst: [ListVersion], own: Set<String>) -> Set<String> {
        var ids = Set<String>()
        for k in 0..<min(history, newestFirst.count) where !own.contains(newestFirst[k].id) {
            if judge(newestFirst, k, own: own) != nil { ids.insert(newestFirst[k].id) }
        }
        return ids
    }

    /// The alarm `newestFirst[k]` raises against the versions before it.
    static func judge(_ v: [ListVersion], _ k: Int, own: Set<String>) -> Alarm? {
        guard k + 1 < v.count else { return nil }
        let vk = v[k]
        let top = min(k + lookback, v.count - 1)
        var trigger: Int?
        for i in (k + 1)...top where clobbered(v[i], vk) {
            if ((k + 1)..<i).contains(where: { clobbered(v[i], v[$0]) }) { continue }
            trigger = i
            break
        }
        guard let trigger else { return nil }
        // Offered back: the largest version vk clobbered, never older than the
        // newest one Nostr Vault signed (that one was the owner's choice).
        let stop = ((k + 1)...top).first { own.contains(v[$0].id) } ?? top
        var best: ListVersion?
        for m in (k + 1)...stop where clobbered(v[m], vk) {
            guard let b = best else { best = v[m]; continue }
            let nm = ListShrinkRule.items(v[m]).count, nb = ListShrinkRule.items(b).count
            if nm > nb || (nm == nb && v[m].content.count > b.content.count) { best = v[m] }
        }
        guard let before = best else { return nil }
        let ib = ListShrinkRule.items(before), i0 = ListShrinkRule.items(vk)
        let encrypted = ListShrinkRule.encryptedKinds.contains(before.kind)
        guard ib.count >= minItems || (encrypted && before.content.count >= ListShrinkRule.minContent) else { return nil }
        let kept = ib.intersection(i0).count
        let how: How
        if i0.isEmpty && (!encrypted || vk.content.isEmpty) {
            how = .emptied
        } else if trigger > k + 1 {
            how = .drained
        } else if ib.count >= ListShrinkRule.minItems && kept * 2 < ib.count && i0.count * 2 >= ib.count {
            how = .swapped
        } else {
            how = .shrank
        }
        let client = vk.tags.lazy.filter { $0.count >= 2 && $0[0] == "client" }.compactMap { cleanClient($0[1]) }.first
        return Alarm(before: before, after: vk, how: how, from: ib.count, to: i0.count,
                     lost: ib.subtracting(i0).count, client: client,
                     claimsNostrVault: client?.lowercased().contains("nostr vault") ?? false)
    }

    /// A `client` name fit to show: control and format characters (bidi
    /// overrides included) removed, trimmed, at most 60 code points.
    static func cleanClient(_ raw: String) -> String? {
        var scalars = String.UnicodeScalarView()
        for u in raw.unicodeScalars {
            switch u.properties.generalCategory {
            case .control, .format: continue
            default: scalars.append(u)
            }
        }
        let trimmed = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var cut = String.UnicodeScalarView()
        cut.append(contentsOf: trimmed.unicodeScalars.prefix(60))
        return String(cut)
    }
}
