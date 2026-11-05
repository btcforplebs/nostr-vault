import Foundation

/// Setup's "Copy from my other vault" (pairing plan §5a, moved by Logen on
/// 2026-11-04): the third answer on the import choice ("Do you have a Vault
/// backup?"), next to restoring a backup and importing from relays. It runs
/// the two scans with this device as B, then copies the vault from the other
/// device. A link or copy that fails falls back quietly to the relay import.
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

    /// Linked and copied: the vault came over, as a restored backup does,
    /// so the relay import is skipped.
    static func afterCopied(path: Path) -> VaultBackupQuestion.Next {
        VaultBackupQuestion.next(after: .restored, path: path)
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
    static let smallPrint = "Your Mac or another device signed in as you. Scan two codes and it copies over the mesh."
    static let fallbackLine = "Couldn't reach your other device; getting your notes from your relays instead"

    static func copyingLine(_ name: String) -> String {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return "Copying from \(t.isEmpty ? "your other device" : t)…"
    }
}
