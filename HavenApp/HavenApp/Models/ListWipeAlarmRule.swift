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

    /// The alarm the newest version raises, if any. `newestFirst` is one
    /// list's versions; `own` the ids Nostr Vault signed; `dismissed` the
    /// ones the person kept.
    static func alarm(_ newestFirst: [ListVersion], own: Set<String>, dismissed: Set<String>) -> Alarm? {
        guard newestFirst.count >= 2 else { return nil }
        let v = newestFirst
        let v0 = v[0]
        guard !own.contains(v0.id), !dismissed.contains(v0.id) else { return nil }
        let top = min(lookback, v.count - 1)
        var trigger: Int?
        for i in 1...top where clobbered(v[i], v0) {
            if (1..<i).contains(where: { clobbered(v[i], v[$0]) }) { continue }
            trigger = i
            break
        }
        guard let trigger else { return nil }
        // Offered back: the largest version v0 clobbered, never older than the
        // newest one Nostr Vault signed (that one was the owner's choice).
        let stop = (1...top).first { own.contains(v[$0].id) } ?? top
        var best: ListVersion?
        for k in 1...stop where clobbered(v[k], v0) {
            guard let b = best else { best = v[k]; continue }
            let nk = ListShrinkRule.items(v[k]).count, nb = ListShrinkRule.items(b).count
            if nk > nb || (nk == nb && v[k].content.count > b.content.count) { best = v[k] }
        }
        guard let before = best else { return nil }
        let ib = ListShrinkRule.items(before), i0 = ListShrinkRule.items(v0)
        let encrypted = ListShrinkRule.encryptedKinds.contains(before.kind)
        guard ib.count >= minItems || (encrypted && before.content.count >= ListShrinkRule.minContent) else { return nil }
        let kept = ib.intersection(i0).count
        let how: How
        if i0.isEmpty && (!encrypted || v0.content.isEmpty) {
            how = .emptied
        } else if trigger > 1 {
            how = .drained
        } else if ib.count >= ListShrinkRule.minItems && kept * 2 < ib.count && i0.count * 2 >= ib.count {
            how = .swapped
        } else {
            how = .shrank
        }
        let client = v0.tags.first { $0.count >= 2 && $0[0] == "client" && !$0[1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { String($0[1].trimmingCharacters(in: .whitespacesAndNewlines).prefix(60)) }
        return Alarm(before: before, after: v0, how: how, from: ib.count, to: i0.count,
                     lost: ib.subtracting(i0).count, client: client)
    }
}
