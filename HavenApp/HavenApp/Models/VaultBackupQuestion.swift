import Foundation

/// Setup's "Do you have a Vault backup?" question for people who already use
/// Nostr. Yes restores the backup file and skips the relay import, which
/// would only fetch the same notes again. No is the flow as it was: the
/// relay import comes next.
///
/// Pure Foundation so MediaLogicTests can test the routing; the wizard
/// (SetupWizardView) maps its own path onto `Path`.
enum VaultBackupQuestion {
    /// The wizard's step number for the question. (15 is "Who told you about
    /// Nostr Vault?", ReferrerStep.)
    static let step = 16

    enum Path {
        /// iPhone/iPad "I use Nostr": your key, then the question.
        case useNostr
        /// Mac full setup: identity, relay config, then the question.
        case full
        /// Mac browse: identity, then the question.
        case browse
    }

    enum Answer {
        /// The backup was restored.
        case restored
        /// No backup: import from relays as before.
        case no
    }

    enum Next: Equatable {
        case step(Int)
        /// Setup is done: nothing left to import.
        case finish
    }

    /// Where the wizard goes after the question.
    static func next(after answer: Answer, path: Path) -> Next {
        switch (answer, path) {
        case (.no, .useNostr): return .step(14)     // relay check, then the import tour
        case (.no, .full), (.no, .browse): return .step(4) // Import step
        case (.restored, .useNostr): return .finish
        case (.restored, .full): return .step(5)    // past Import, to media
        case (.restored, .browse): return .step(8)  // done
        }
    }

    /// What setup's restore tells the person, from the relay's restore code
    /// (RestoreOwnBackupC): nil on success. Setup only restores a backup that
    /// holds notes signed by the key signing in, so someone else's backup is
    /// never merged into a new vault.
    static func restoreError(code: Int32) -> String? {
        switch code {
        case 0: return nil
        case 2: return "This backup isn't yours. It holds no notes signed by the key you signed in with."
        default: return "Failed to restore backup. Check logs for details."
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

    /// The steps a path shows, for the step dots.
    static func steps(path: Path, isIOS: Bool) -> [Int] {
        switch path {
        case .useNostr: return [12, step, 14, 13]
        case .browse: return [2, step, 4, 8]
        case .full: return isIOS ? [2, 3, step, 4, 5, 6, 7, 8] : [2, 3, step, 4, 5, 6, 8]
        }
    }
}
