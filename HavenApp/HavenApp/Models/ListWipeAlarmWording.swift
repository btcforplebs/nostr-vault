import Foundation

/// What the wipe alarm says, in the banner and the notification
/// (docs/LIST_WIPE_ALARM.md, "What the person sees"). Pure.
enum ListWipeAlarmWording {
    static func listName(_ key: ListHistory.Key) -> String {
        let name = ListShrinkRule.name(key.kind)
        return key.d.isEmpty ? name : "\(name) “\(key.d)”"
    }

    /// "changed by Amethyst" / "changed by an app that didn't name itself".
    static func byLine(_ alarm: ListWipeAlarmRule.Alarm) -> String {
        // A name claiming to be us on a version this device didn't sign must
        // not read like your own edit (Tron, #1635).
        if alarm.claimsNostrVault { return "changed by an app calling itself Nostr Vault. This device didn't make that change" }
        if let client = alarm.client { return "changed by \(client)" }
        return "changed by an app that didn't name itself"
    }

    /// The banner's first line.
    static func headline(_ alarm: ListWipeAlarmRule.Alarm, key: ListHistory.Key, day: String) -> String {
        let name = listName(key)
        switch alarm.how {
        case .emptied:
            return "Your \(name) went from \(alarm.from) to \(alarm.to) on \(day), \(byLine(alarm))."
        case .swapped:
            return "Your \(name) lost \(alarm.lost) of \(alarm.from) on \(day), swapped for other entries, \(byLine(alarm))."
        case .drained:
            return "Your \(name) went from \(alarm.from) to \(alarm.to) in steps, last on \(day), \(byLine(alarm))."
        case .shrank:
            if alarm.from == 0 && alarm.to == 0 {
                return "The private part of your \(name) was cut on \(day), \(byLine(alarm))."
            }
            return "Your \(name) went from \(alarm.from) to \(alarm.to) on \(day), \(byLine(alarm))."
        }
    }

    static func notificationTitle(_ alarm: ListWipeAlarmRule.Alarm, key: ListHistory.Key, account: String?) -> String {
        let whose = account.map { "\($0)'s" } ?? "Your"
        let name = listName(key)
        switch alarm.how {
        case .emptied: return "\(whose) \(name) was emptied"
        default: return alarm.lost > 0 ? "\(whose) \(name) lost \(alarm.lost) \(alarm.lost == 1 ? "entry" : "entries")" : "\(whose) \(name) was cut"
        }
    }

    static func notificationBody(_ alarm: ListWipeAlarmRule.Alarm) -> String {
        let by = byLine(alarm)
        return by.prefix(1).uppercased() + by.dropFirst() + ". Your vault kept the list from before. Tap to recover it."
    }
}
