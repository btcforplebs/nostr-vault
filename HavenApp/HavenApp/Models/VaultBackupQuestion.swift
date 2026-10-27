import Foundation

/// Setup's "Do you have a Vault backup?" question for people who already use
/// Nostr. Yes restores the backup file and skips the relay import, which
/// would only fetch the same notes again. No is the flow as it was: the
/// relay import comes next.
///
/// Pure Foundation so MediaLogicTests can test the routing; the wizard
/// (SetupWizardView) maps its own path onto `Path`.
enum VaultBackupQuestion {
    /// The wizard's step number for the question.
    static let step = 15

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
