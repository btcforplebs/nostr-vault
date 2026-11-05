import Foundation

/// Setup's "Copy from my other vault" (pairing plan §5a, moved by Logen on
/// 2026-11-04): the third answer on the import choice ("Do you have a Vault
/// backup?"), next to restoring a backup and importing from relays. It runs
/// the two scans with this device as B, then imports from the other device
/// (one more relay, read over the link) since `startDate`. The normal relay
/// import always runs after it: the copy reads only the other vault's public
/// notes, so it is not a restored backup. A link or copy that fails falls
/// back quietly to the relay import.
///
/// Pure Foundation so MediaLogicTests can test the routing; the wizard
/// (SetupWizardView) maps its own path onto `VaultBackupQuestion.Path`.
enum OtherVaultCopy {
    typealias Path = VaultBackupQuestion.Path

    /// The wizard's step number for the scans and the copy.
    static let step = 19

    /// How long the link may take before setup moves on without it.
    static let linkTimeout = 180
    /// A copy with no progress this long has stalled.
    static let stallTimeout = 120

    /// How far back the copy reads: the Mac backfill's epoch (macsync.go),
    /// not setup's 2023 relay-import start, so older notes and lists come over.
    static let startDate = "2020-11-01"

    /// Linked and copied: the normal relay import still runs after it, as
    /// for "import from my relays" (the copy is not a full backup).
    static func afterCopied(path: Path) -> VaultBackupQuestion.Next {
        VaultBackupQuestion.next(after: .no, path: path)
    }

    /// The link or the copy failed: the relay import, as if "import from my
    /// relays" had been picked.
    static func afterFallback(path: Path) -> Int {
        switch VaultBackupQuestion.next(after: .no, path: path) {
        case .step(let next): return next
        case .finish: return VaultBackupQuestion.step
        }
    }

    /// Back from the copy: to the import choice.
    static let backStep = VaultBackupQuestion.step

    /// The copy screen sits on the import choice's dot.
    static func dotStep(_ step: Int) -> Int {
        step == self.step ? VaultBackupQuestion.step : step
    }

    static func isStalled(lastProgressAt: Int, now: Int) -> Bool {
        now - lastProgressAt >= stallTimeout
    }

    static func linkTimedOut(startedAt: Int, now: Int) -> Bool {
        now - startedAt >= linkTimeout
    }

    // MARK: Words (Logen-approved; no other mesh words on these screens)

    static let button = "Copy from my other vault"
    static let smallPrint = "Links your devices, then brings your notes from your relays"
    static let fallbackLine = "Your other vault was not reached; getting your notes from your relays instead"

    static func copyingLine(_ name: String) -> String {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return "Copying from \(t.isEmpty ? "your other device" : t)…"
    }
}
