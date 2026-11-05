import Foundation

/// The active account's list versions kept by the vault (its /lists relay),
/// for the List backups screens and the wipe banner. Following Backup keeps
/// its own on-device follow snapshots; this is the vault's copy of every
/// list. Twin of Android `ListBackupService.kt`.
@MainActor
final class ListBackupService: ObservableObject {
    static let shared = ListBackupService()

    enum State: Equatable { case idle, loading, loaded, unavailable }

    @Published private(set) var state: State = .idle
    /// Every kept version per list, newest first.
    @Published private(set) var groups: [ListHistory.Key: [ListVersion]] = [:]
    @Published private(set) var dismissed: Set<String>
    private var events: [String: NostrEvent] = [:]
    private(set) var author = ""

    private static let dismissedKey = "listWipeDismissed"

    private init() {
        dismissed = Set(UserDefaults.standard.stringArray(forKey: Self.dismissedKey) ?? [])
    }

    /// Reads every kept version for the active account from the vault: its
    /// own, then the ones a moving-in import filed (`ListHistoryScan`).
    func load() async {
        let config = ConfigService.shared.config
        let npub = config.activeAccountNpub.isEmpty ? config.ownerNpub : config.activeAccountNpub
        guard let hex = Bech32.decode(npub)?.hexString else { state = .unavailable; return }
        if author != hex { groups = [:]; events = [:]; importedIDs = [] }
        author = hex
        state = .loading
        guard let own = await read(hex, imported: false), author == hex else {
            if author == hex { state = .unavailable }
            return
        }
        // No answer for the imported ones (an older vault): only the own.
        let imported = await read(hex, imported: true) ?? []
        guard author == hex else { return }
        let ownIDs = Set(own.map(\.id))
        importedIDs = Set(imported.map(\.id)).subtracting(ownIDs)
        let found = own + imported.filter { importedIDs.contains($0.id) }
        events = Dictionary(found.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        groups = ListHistory.group(found.map(ListVersion.init), author: hex)
        state = .loaded
    }

    /// The ids of the versions an import filed: shown in the List backups
    /// screens, never judged by the wipe alarm (Tron, PR 1637/1639).
    private(set) var importedIDs: Set<String> = []

    /// One /lists read: the vault's own versions, or (`imported`) the ones an
    /// import filed (haven-go wantsImported). nil when the vault didn't answer.
    private func read(_ hex: String, imported: Bool) async -> [NostrEvent]? {
        await VaultSocket.query(path: "/lists", filters: Self.perKindFilters(
            author: hex, kinds: ListShrinkRule.protectedKinds, imported: imported))
    }

    /// One filter per kind, each limit 1,000, for one REQ: the vault applies
    /// a limit per filter, so a kind with 1,000+ versions can't cut another
    /// kind's oldest, which may be a pinned list from before a wipe (Tron,
    /// PR 1568). It replaces a combined read that, at the limit, was asked
    /// again one kind at a time: 17 reads (Logen 2026-11-05).
    static func perKindFilters<S: Sequence>(author: String, kinds: S, imported: Bool) -> [[String: Any]] where S.Element == Int {
        kinds.sorted().map { kind in
            var f: [String: Any] = ["authors": [author], "kinds": [kind], "limit": 1000]
            if imported { f["#v"] = [ListHistoryScan.importedFilterValue] }
            return f
        }
    }

    /// Lists in a fixed order: by kind, then name.
    var keys: [ListHistory.Key] { groups.keys.sorted() }

    /// Wipe alarms the newest version of each list the vault filed itself raises
    /// (ListWipeAlarmRule: a wipe, a swap or a drain, not by Nostr Vault on
    /// this device) that the person hasn't dismissed, newest first.
    var alarms: [(key: ListHistory.Key, alarm: ListWipeAlarmRule.Alarm)] {
        let own = OwnListEdits.ids()
        let imported = importedIDs
        return groups.compactMap { key, versions in
            ListWipeAlarmRule.alarm(ListHistoryScan.alarmInput(versions, imported: imported), own: own, dismissed: dismissed).map { (key, $0) }
        }
        .sorted { $0.alarm.after.createdAt > $1.alarm.after.createdAt }
    }

    /// "Keep the new list": this alarm is not shown again.
    func dismiss(afterID id: String) {
        dismissed.insert(id)
        UserDefaults.standard.set(Array(dismissed), forKey: Self.dismissedKey)
    }

    /// The ids whose alarm the person dismissed, for the watcher.
    static func dismissedIDs() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: dismissedKey) ?? [])
    }

    /// The versions of `v`'s list the vault filed itself, newest first: what
    /// a restore or merge counts as held (an imported copy is not the vault's
    /// undo copy; web keepUndoCopy reads the same way).
    func vaultEvents(for v: ListVersion) -> [NostrEvent] {
        (groups[ListHistory.Key(kind: v.kind, d: v.d)] ?? []).filter { !importedIDs.contains($0.id) }.compactMap { events[$0.id] }
    }

    /// What restoring `old` would bring back and take away, against the
    /// newest list as fetched now.
    func preview(_ old: ListVersion) async -> Result<NostrService.ListRestorePreview, NostrService.ListRestoreError> {
        switch await NostrService.shared.currentList(like: old, vaultNewest: vaultEvents(for: old).first) {
        case .failure(let error): return .failure(error)
        case .success(let current):
            let now = current.map(ListVersion.init)
            let diff = ListHistory.diff(restoring: old, over: now)
            return .success(.init(current: current, comeBack: diff.comeBack, go: diff.go,
                                  replacesPrivate: ListHistory.replacesPrivatePart(old, current: now)))
        }
    }

    /// Restores `old` after the person confirmed `preview`; nil when done,
    /// else what to tell them. The versions are read again afterwards.
    func restore(_ old: ListVersion, preview: NostrService.ListRestorePreview) async -> String? {
        let error = await NostrService.shared.restoreList(old, shown: preview, vaultVersions: vaultEvents(for: old))
        await load()
        return error?.message
    }
}
