import Foundation

/// Factory reset deletes the vault folder. It may only do that once nothing
/// has the databases open: a running import is cancelled first and waited
/// out, and a backup or restore is waited out. Before this, Reset Everything
/// during an import deleted the folder under the writing import, and the
/// import's end then restarted the relay with the old account (Tron,
/// RESEARCH/NV_IMPORT_BACKGROUND_RISKS_2026_11_05.md item 5).
///
/// Pure Foundation so MediaLogicTests can test it; RelayProcessManager
/// (stopForFactoryReset) drives it.
enum FactoryResetGate {
    /// How long the reset waits for an import or backup to let go.
    static let waitLimit: TimeInterval = 30
    static let pollInterval: TimeInterval = 0.2

    static let busyText = "The vault is still busy, so nothing was deleted. Wait for it to finish, then reset again."

    enum Action: Equatable {
        /// Nothing holds the vault: stop the relay and delete.
        case reset
        /// An import is running and hasn't been asked to stop yet.
        case cancelImport
        /// Asked (or a backup/restore is running): check again shortly.
        case wait
        /// Still busy after `waitLimit`: delete nothing.
        case refuse
    }

    /// `importRunning`: an import is running, held or retrying.
    /// `otherJob`: a backup or restore has the databases.
    static func action(importRunning: Bool, otherJob: Bool, cancelSent: Bool, waited: TimeInterval) -> Action {
        if !importRunning && !otherJob { return .reset }
        if waited >= waitLimit { return .refuse }
        if importRunning && !cancelSent { return .cancelImport }
        return .wait
    }

    /// The stop and the delete. StopRelayC returns after about 2 s and the old
    /// run can still be closing its databases: on the 12 mini (2026-11-06) the
    /// folder was deleted under it, its feed database retried writes to the
    /// missing files for about 95 s, and every new start waited that out.
    /// So the folder goes only once the old run has drained
    /// (`RelayDrainWait`); still draining after that wait: nothing deleted.
    @MainActor
    static func stopThenDelete(stop: () async -> Void, drained: () async -> Bool,
                               delete: () -> Void, refuse: () -> Void) async {
        await stop()
        guard await drained() else { return refuse() }
        delete()
    }
}
