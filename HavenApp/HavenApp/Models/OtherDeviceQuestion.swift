import Foundation

/// Setup's "Already using Nostr Vault on another device?" (pairing plan §5a),
/// asked of people who already use Nostr, right after they sign in and
/// before today's relay setup. Yes links this device to the other one (it
/// plays B in the two scans) and copies the vault across; No is setup as it
/// was. A link or copy that fails falls back quietly to the relay setup and
/// import. New accounts are never asked: there's no other device yet.
///
/// Pure Foundation so MediaLogicTests can test the routing; the wizard
/// (SetupWizardView) maps its own path onto `VaultBackupQuestion.Path`.
enum OtherDeviceQuestion {
    typealias Path = VaultBackupQuestion.Path

    /// The wizard's step number for the question.
    static let step = 18
    /// "Yes, bring it over": the two scans, then the copy.
    static let bringOverStep = 19

    /// How long the link may take before setup moves on without it.
    static let linkTimeout = 180
    /// A copy with no progress this long has stalled.
    static let stallTimeout = 120

    /// The step right before the question: signing in.
    static func previous(path: Path) -> Int {
        switch path {
        case .useNostr: return 12 // your key
        case .full, .browse: return 2 // identity
        }
    }

    static func isAskedAfter(step: Int, path: Path) -> Bool {
        step == previous(path: path)
    }

    /// No, start fresh: where setup went before the question existed.
    static func afterNo(path: Path) -> Int {
        switch path {
        case .useNostr, .browse: return VaultBackupQuestion.step
        case .full: return 3 // relay config
        }
    }

    /// The link and copy worked: the vault came over, as a restored backup
    /// does, so the relay import is skipped.
    static func afterCopied(path: Path) -> VaultBackupQuestion.Next {
        VaultBackupQuestion.next(after: .restored, path: path)
    }

    /// The link or the copy failed: today's relay setup and import.
    static func afterFallback(path: Path) -> Int {
        switch path {
        case .useNostr: return 14 // relay check, then the import tour
        case .full: return 3      // relay config
        case .browse: return 4    // import
        }
    }

    /// Back from the Vault backup question: to this question where it
    /// came right before it.
    static func backFromBackupQuestion(path: Path) -> Int {
        switch path {
        case .useNostr, .browse: return step
        case .full: return VaultBackupQuestion.previous(path: path)
        }
    }

    /// Where the person sees the copy screen in the dots: on the question's dot.
    static func dotStep(_ step: Int) -> Int {
        step == bringOverStep ? self.step : step
    }

    /// The path's steps with the question added, for the step dots.
    static func steps(_ steps: [Int], path: Path) -> [Int] {
        var out = steps
        let after = previous(path: path)
        out.insert(step, at: out.firstIndex(of: after).map { $0 + 1 } ?? 0)
        return out
    }

    /// The copy has stalled: nothing moved for `stallTimeout`.
    static func isStalled(lastProgressAt: Int, now: Int) -> Bool {
        now - lastProgressAt >= stallTimeout
    }

    /// The link took too long.
    static func linkTimedOut(startedAt: Int, now: Int) -> Bool {
        now - startedAt >= linkTimeout
    }

    // MARK: Words (no mesh, address or role words here: §5a)

    static let title = "Already using Nostr Vault on another device?"
    static let yes = "Yes, bring it over"
    static let yesDetail = "Link this device to it and copy your vault across."
    static let no = "No, start fresh"
    static let fallbackLine = "Couldn't reach your other device; getting your notes from your relays instead"

    static func copyingLine(_ name: String) -> String {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return "Copying from \(t.isEmpty ? "your other device" : t)…"
    }
}
