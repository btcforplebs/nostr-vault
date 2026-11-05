import Foundation

/// Setup's "Copy from my other vault" (pairing plan §5a, moved by Logen on
/// 2026-11-04): the No answer to "New to Nostr Vault?" (NewToVaultQuestion,
/// 2026-11-05). It runs
/// the two scans with this device as B, then imports from the other device
/// (one more relay, read over the link) since `startDate`. The normal relay
/// import always runs after it: the copy reads only the other vault's public
/// notes, so it is not a full copy. A link or copy that fails falls back
/// quietly to the relay import.
///
/// Pure Foundation so MediaLogicTests can test the routing; the wizard
/// (SetupWizardView) maps its own path onto `NewToVaultQuestion.Path`.
enum OtherVaultCopy {
    typealias Path = NewToVaultQuestion.Path

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
    /// for "bring my notes from my relays" (the copy is not a full copy).
    static func afterCopied(path: Path) -> Int {
        NewToVaultQuestion.relayImportStep(path: path)
    }

    /// The link or the copy failed: the relay import, as if Yes had been picked.
    static func afterFallback(path: Path) -> Int {
        NewToVaultQuestion.relayImportStep(path: path)
    }

    /// Back from the copy: to the question.
    static let backStep = NewToVaultQuestion.step

    /// The copy screen sits on the question's dot.
    static func dotStep(_ step: Int) -> Int {
        step == self.step ? NewToVaultQuestion.step : step
    }

    // MARK: Reaching the other vault (Logen 2026-11-05)

    /// B keeps dialing the other vault this long before it falls back to
    /// relays: A's engine takes seconds to start and be found.
    static let dialWindow = 60
    /// Between two dials.
    static let dialRetryEvery = 10

    /// Whether B dials again after a dial that reached nothing.
    static func dialsAgain(startedAt: Int, now: Int) -> Bool {
        now - startedAt + dialRetryEvery < dialWindow
    }

    /// How long an iPhone that was A in a link shares its vault with its own
    /// devices (kiosk mode, My Devices only), so the device it just linked
    /// can copy from it. An iPhone shares only in kiosk mode, which nothing
    /// else turns on.
    static let shareWindow = 15 * 60

    /// Whether A starts sharing for the copy: the mesh is on and the vault
    /// isn't shared already (kiosk on, or starting). B never does: it reads.
    static func sharesAfterLink(wasA: Bool, meshOn: Bool, alreadySharing: Bool) -> Bool {
        wasA && meshOn && !alreadySharing
    }

    /// On A's "Linked" screen while it shares for the copy.
    static let keepOpenLine = "Keep Nostr Vault open on this device while your other device copies from it."

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
    /// Under the scans, before the copy starts (Logen's plan, 2026-11-05).
    static let lostDevice = "Lost your other device? We'll bring your notes from relays"

    static func copyingLine(_ name: String) -> String {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return "Copying from \(t.isEmpty ? "your other device" : t)…"
    }
}
