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

    /// The app came to the front: check the active account's lists, which
    /// catches a clobber that synced in while it was away (the vault skips
    /// the marker for old versions). Banner for all, notification only for
    /// recent ones. Only the active account: every account on every
    /// foreground was a /lists read each, and with a remote signer each read
    /// cost a login (LogePhone, 2026-11-05). The others are still checked
    /// when a new version of their lists lands (listVersionsArrived).
    func appCameForward() {
        guard ConfigService.shared.config.hasCompletedSetup, task == nil else { return }
        let active = ConfigService.shared.activeAccountHexPubkey.lowercased()
        guard !active.isEmpty else { return }
        pending[active, default: []].formUnion(ListShrinkRule.protectedKinds)
        task = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            let work = pending
            pending = [:]
            task = nil
            for (author, kinds) in work { await check(author: author, kinds: kinds) }
        }
    }

    /// Only a change this recent is announced; older alarms show as the banner.
    static let notifyWithin: TimeInterval = 48 * 3600

    private func check(author: String, kinds: Set<Int>) async {
        // Every version, paged past the vault's cap only when there are
        // more (it used to re-ask once per kind whenever the first answer
        // was full).
        let filter: [String: Any] = ["authors": [author], "kinds": Array(kinds).sorted()]
        guard let found = await VaultSocket.queryAll(path: "/lists", filter: filter) else { return }
        let groups = ListHistory.group(found.map(ListVersion.init), author: author)
        let own = OwnListEdits.ids(), dismissed = ListBackupService.dismissedIDs()
        var notified = Set(UserDefaults.standard.stringArray(forKey: Self.notifiedKey) ?? [])
        var any = false
        for (key, versions) in groups {
            guard let alarm = ListWipeAlarmRule.alarm(versions, own: own, dismissed: dismissed),
                  Date().timeIntervalSince1970 - TimeInterval(alarm.after.createdAt) < Self.notifyWithin,
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
