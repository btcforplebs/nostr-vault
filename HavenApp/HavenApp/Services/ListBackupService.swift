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

    /// Reads every kept version for the active account from the vault.
    func load() async {
        let config = ConfigService.shared.config
        let npub = config.activeAccountNpub.isEmpty ? config.ownerNpub : config.activeAccountNpub
        guard let hex = Bech32.decode(npub)?.hexString else { state = .unavailable; return }
        if author != hex { groups = [:]; events = [:] }
        author = hex
        state = .loading
        let filter: [String: Any] = ["authors": [hex], "kinds": ListShrinkRule.protectedKinds, "limit": 1000]
        guard let found = await VaultSocket.query(path: "/lists", filter: filter), author == hex else {
            if author == hex { state = .unavailable }
            return
        }
        events = Dictionary(found.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        groups = ListHistory.group(found.map(ListVersion.init), author: hex)
        state = .loaded
    }

    /// Lists in a fixed order: by kind, then name.
    var keys: [ListHistory.Key] { groups.keys.sorted() }

    /// Wipes the newest version of a list made that the person hasn't
    /// dismissed, newest first.
    var wipes: [(key: ListHistory.Key, wipe: ListHistory.Wipe)] {
        groups.compactMap { key, versions in
            guard let wipe = ListHistory.latestWipe(versions), !dismissed.contains(wipe.after.id) else { return nil }
            return (key, wipe)
        }
        .sorted { $0.wipe.after.createdAt > $1.wipe.after.createdAt }
    }

    /// "Keep the new list": this wipe is not shown again.
    func dismiss(_ wipe: ListHistory.Wipe) {
        dismissed.insert(wipe.after.id)
        UserDefaults.standard.set(Array(dismissed), forKey: Self.dismissedKey)
    }

    private func vaultEvents(for v: ListVersion) -> [NostrEvent] {
        (groups[ListHistory.Key(kind: v.kind, d: v.d)] ?? []).compactMap { events[$0.id] }
    }

    /// What restoring `old` would bring back and take away, against the
    /// newest list as fetched now.
    func preview(_ old: ListVersion) async -> Result<NostrService.ListRestorePreview, NostrService.ListRestoreError> {
        switch await NostrService.shared.currentList(like: old, vaultNewest: vaultEvents(for: old).first) {
        case .failure(let error): return .failure(error)
        case .success(let current):
            let diff = ListHistory.diff(restoring: old, over: current.map(ListVersion.init))
            return .success(.init(current: current, comeBack: diff.comeBack, go: diff.go))
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
