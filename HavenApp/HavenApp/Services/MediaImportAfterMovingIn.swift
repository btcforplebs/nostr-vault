import Foundation

/// Starts one Import media when the first Moving in finishes
/// (`MediaImportAfterMovingInRule`). Called from the import's end; waits for
/// the relay to serve again, since the import stops it.
@MainActor
enum MediaImportAfterMovingIn {
    private static let startedKey = "haven.vault.mediaImportAfterMovingInStarted"

    static func movingInCompleted() {
        Task { @MainActor in
            // The relay restarts about a second after the import ends.
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard await RelayProcessManager.shared.ensureRelayServing(timeout: 60) else { return }
            MediaImportAfterMovingInRule(
                started: { UserDefaults.standard.bool(forKey: startedKey) },
                markStarted: { UserDefaults.standard.set(true, forKey: startedKey) },
                mediaImportedAt: { VaultHistory.lastMediaImport },
                runImport: {
                    let mirror = MirrorService.shared
                    guard mirror.state != .mirroring else { return false }
                    mirror.runMirror(configService: .shared, nostrService: .shared)
                    return true
                }
            ).movingInDone()
        }
    }
}
