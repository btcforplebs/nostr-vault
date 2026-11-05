import Foundation

/// Setup's second question, for people who already use Nostr: "New to Nostr
/// Vault?" (Logen 2026-11-05, PLANS/NV_FIRST_RUN_ENTRY_PLAN_2026_11_05.md).
/// Yes brings their notes from their relays. No copies from their other
/// vault (OtherVaultCopy); when it can't be reached, the relays again. A
/// backup zip is not offered here any more: it is restored from the Vault
/// tab.
///
/// Pure Foundation so MediaLogicTests can test the routing; the wizard
/// (SetupWizardView) maps its own path onto `Path`.
enum NewToVaultQuestion {
    /// The wizard's step number for the question. (15 is "Who showed you
    /// this app?", ReferrerStep, asked only of people new to Nostr.)
    static let step = 16

    enum Path {
        /// iPhone/iPad "I use Nostr": your key, then the question.
        case useNostr
        /// Mac full setup: identity, relay config, then the question.
        case full
        /// Mac browse: identity, then the question.
        case browse
    }

    /// Yes, new to Nostr Vault: the relay import for this path.
    static func relayImportStep(path: Path) -> Int {
        switch path {
        case .useNostr: return 14           // relay check, then the import tour
        case .full, .browse: return 4       // Import step
        }
    }

    /// The step that leads to the question, for Back.
    static func previous(path: Path) -> Int {
        switch path {
        case .useNostr: return 12 // your key
        case .full: return 3      // relay config
        case .browse: return 2    // identity
        }
    }

    /// The step a path shows right before its relay import, which now goes to
    /// the question instead.
    static func isAskedAfter(step: Int, path: Path) -> Bool {
        step == previous(path: path)
    }

    /// The steps a path shows, for the step dots. No "Who showed you this
    /// app?" (15): that is only for people new to Nostr (Logen 2026-11-05).
    static func steps(path: Path, isIOS: Bool) -> [Int] {
        switch path {
        case .useNostr: return [12, step, 14, 13]
        case .browse: return [2, step, 4, 8]
        case .full: return isIOS ? [2, 3, step, 4, 5, 6, 7, 8] : [2, 3, step, 4, 5, 6, 8]
        }
    }

    // MARK: Words

    static let title = "New to Nostr Vault?"
    static let subtitle = "Your notes are already on Nostr. Bring them in from your relays, or copy them from your other vault."
    static let yes = "Yes, bring my notes from my relays"
}
