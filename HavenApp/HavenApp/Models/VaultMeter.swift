import Foundation

/// The "Fill your vault" meter: how far a new account is toward a web of trust.
///
/// It reads the follow list itself, never taps made inside the guide, so a
/// follow from a profile, search or thread counts the same, and an unfollow
/// takes a slot back. 5 follows completes the guide; 10 makes the owner a
/// Vault Master, which is kept once earned (see `VaultMasterStore`).
struct VaultMeter: Equatable {
    /// Follows that complete the guide.
    static let goal = 5
    /// Follows that earn Vault Master.
    static let masterGoal = 10

    enum Stage: Equatable {
        /// Fewer than `goal` follows: the guide is still filling.
        case filling
        /// `goal` or more: the vault is filled; Vault Master is optional.
        case filled
        /// `masterGoal` or more, now or at any point before.
        case master
    }

    /// People followed, not counting the owner.
    let count: Int
    /// The most recent follows, newest last, at most `masterGoal`. Their
    /// photos fill the meter's slots.
    let recent: [String]
    let stage: Stage

    /// - Parameters:
    ///   - follows: the contact list in its stored order (newest last).
    ///   - owner: the account's own hex pubkey, which the app keeps in its
    ///     follow set but which is not a follow.
    ///   - masterEarned: whether this account has reached 10 before.
    init(follows: [String], owner: String, masterEarned: Bool) {
        var seen = Set<String>()
        let people = follows.filter { $0 != owner && !$0.isEmpty && seen.insert($0).inserted }
        count = people.count
        recent = Array(people.suffix(Self.masterGoal))
        if masterEarned || count >= Self.masterGoal {
            stage = .master
        } else if count >= Self.goal {
            stage = .filled
        } else {
            stage = .filling
        }
    }

    /// Filled slots in the row being shown: the first 5 until the vault is
    /// filled, then all 10.
    var slots: Int { stage == .filling ? Self.goal : Self.masterGoal }

    /// "3 of 5", "7 of 10". Capped at the row's size.
    var progressText: String { "\(min(count, slots)) of \(slots)" }

    /// The short form for the largest text sizes: "3/5".
    var compactProgressText: String { "\(min(count, slots))/\(slots)" }

    /// Read by VoiceOver / TalkBack for the whole meter.
    var accessibilityText: String {
        let n = min(count, slots)
        let people = n == 1 ? "person" : "people"
        if stage == .master { return "Vault Master. \(n) of \(slots) \(people) followed." }
        return "\(n) of \(slots) \(people) followed."
    }

    /// An account that already follows this many never sees the guide: it is
    /// marked finished straight away, because page tutorials only start once
    /// "Fill your vault" is finished or skipped.
    static func skipsGuide(followCount: Int) -> Bool { followCount >= goal }
}

/// Remembers, per account, that Vault Master was reached, so the gold meter
/// is a lasting mark: unfollowing someone afterwards does not take it away,
/// and the bolt animation plays exactly once.
struct VaultMasterStore {
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private func key(_ owner: String) -> String { "vaultMaster.earned.\(owner)" }

    func isEarned(owner: String) -> Bool {
        !owner.isEmpty && defaults.bool(forKey: key(owner))
    }

    /// Records the meter's state. Returns true only on the call that first
    /// reaches Vault Master, which is when the celebration plays.
    @discardableResult
    func record(_ meter: VaultMeter, owner: String) -> Bool {
        guard !owner.isEmpty, meter.count >= VaultMeter.masterGoal, !isEarned(owner: owner) else { return false }
        defaults.set(true, forKey: key(owner))
        return true
    }
}

/// When "Fill your vault" starts, finishes or is skipped. No UI here, so the
/// rules are tested on their own; `FillYourVaultCoordinator` applies them.
enum FillYourVaultRule {
    enum Action: Equatable {
        case none
        /// A new account: show the guide.
        case start
        /// Mark it done without showing anything: an account that already
        /// follows enough was never new. Page tutorials wait for this.
        case finishSilently
        /// The guide is showing and the vault just filled.
        case finish
    }

    /// What to do after the follow list changes.
    ///
    /// - Parameters:
    ///   - listKnown: the real follow list has loaded. Before that the count
    ///     reads 0 for everyone, and deciding then would show the guide to
    ///     people who follow hundreds.
    ///   - previousCount: the count before this change, nil for the first
    ///     known list.
    static func onFollowsChanged(listKnown: Bool, previousCount: Int?, count: Int,
                                 status: TutorialStatus, isActive: Bool) -> Action {
        guard listKnown else { return .none }
        if isActive {
            // Only crossing 5 finishes it. A replay opened at 7 stays open so
            // the person can go for Vault Master; closing it is up to them.
            if let previousCount, previousCount < VaultMeter.goal, count >= VaultMeter.goal { return .finish }
            return .none
        }
        guard status == .notStarted else { return .none }
        return VaultMeter.skipsGuide(followCount: count) ? .finishSilently : .start
    }

    /// Closing the guide by hand. Past 5 it counts as done, so a replay closed
    /// at 7 doesn't turn a finished guide into a skipped one.
    static func onClose(count: Int) -> TutorialStatus {
        count >= VaultMeter.goal ? .done : .skipped
    }
}
