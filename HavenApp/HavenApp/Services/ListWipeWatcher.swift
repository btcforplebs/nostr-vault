import Foundation
import UserNotifications

/// Watches for a list clobbered by another app (docs/LIST_WIPE_ALARM.md).
/// The vault logs a `type=listversion` marker when it files a new version of
/// one of your lists; this re-reads that list's history from the vault's
/// /lists, runs ListWipeAlarmRule and, once per new version, posts a
/// notification. Tapping it opens the Vault, where ListWipeBanner offers
/// Recover or Merge. Nothing is ever restored or published from here.
@MainActor
final class ListWipeWatcher {
    static let shared = ListWipeWatcher()

    private static let notifiedKey = "listWipeNotifiedIds"
    private var pending: [String: Set<Int>] = [:]
    private var task: Task<Void, Never>?

    /// Bodies of `🔔NOTIFY|type=listversion|…` markers.
    func listVersionsArrived(_ markers: [String]) {
        let accounts = ConfigService.shared.allAccountHexes
        for marker in markers {
            let fields = Self.fields(marker)
            guard let author = fields["author"]?.lowercased(), accounts.contains(author),
                  let kind = fields["kind"].flatMap(Int.init), ListShrinkRule.isProtected(kind) else { continue }
            pending[author, default: []].insert(kind)
        }
        guard !pending.isEmpty, task == nil else { return }
        // A save often lands as several copies a moment apart: look once.
        task = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            let work = pending
            pending = [:]
            task = nil
            for (author, kinds) in work { await check(author: author, kinds: kinds) }
        }
    }

    static func fields(_ marker: String) -> [String: String] {
        var out: [String: String] = [:]
        for part in marker.split(separator: "|") {
            let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { out[kv[0]] = kv[1] }
        }
        return out
    }

    private func check(author: String, kinds: Set<Int>) async {
        let filter: [String: Any] = ["authors": [author], "kinds": Array(kinds).sorted(), "limit": 1000]
        guard let found = await VaultSocket.query(path: "/lists", filter: filter) else { return }
        let groups = ListHistory.group(found.map(ListVersion.init), author: author)
        let own = OwnListEdits.ids(), dismissed = ListBackupService.dismissedIDs()
        var notified = Set(UserDefaults.standard.stringArray(forKey: Self.notifiedKey) ?? [])
        var any = false
        for (key, versions) in groups {
            guard let alarm = ListWipeAlarmRule.alarm(versions, own: own, dismissed: dismissed),
                  notified.insert(alarm.after.id).inserted else { continue }
            any = true
            await notify(alarm, key: key, author: author)
        }
        if any {
            UserDefaults.standard.set(Array(notified.suffix(500)), forKey: Self.notifiedKey)
        }
        // The banner reads the active account's lists.
        if author == ConfigService.shared.activeAccountHexPubkey.lowercased() {
            await ListBackupService.shared.load()
        }
    }

    private func notify(_ alarm: ListWipeAlarmRule.Alarm, key: ListHistory.Key, author: String) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        let content = UNMutableNotificationContent()
        content.title = ListWipeAlarmWording.notificationTitle(alarm, key: key, account: accountName(author))
        content.body = ListWipeAlarmWording.notificationBody(alarm)
        content.sound = .default
        content.userInfo = ["nv_deeplink": "nostrvault://relay"]
        let request = UNNotificationRequest(identifier: "nv.listwipe.\(alarm.after.id)", content: content, trigger: nil)
        try? await center.add(request)
    }

    /// The account's name, only when there is more than one on the device.
    private func accountName(_ hex: String) -> String? {
        guard ConfigService.shared.allAccountNpubs.count > 1 else { return nil }
        return NostrService.shared.profiles[hex]?.bestName
    }
}
