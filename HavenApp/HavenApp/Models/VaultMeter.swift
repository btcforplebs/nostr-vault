import Foundation

/// The "Fill your vault" meter: how far a new account is toward a web of trust.
///
/// It reads the follow list itself, never taps made inside the guide, so a
/// follow from a profile, search or thread counts the same, and an unfollow
/// takes a slot back. 5 follows builds the web of trust and completes the
/// guide (Logen, nostr-vault Tutorial thread 2026-10-08: no second goal at
/// 10). Once built it is kept (see `VaultMasterStore`).
struct VaultMeter: Equatable {
    /// Follows that build the web of trust and complete the guide.
    static let goal = 5

    enum Stage: Equatable {
        /// Fewer than `goal` follows: the guide is still filling.
        case filling
        /// `goal` or more, now or at any point before: the web of trust is built.
        case master
    }

    /// People followed, not counting the owner.
    let count: Int
    /// The most recent follows, newest last, at most `goal`. Their photos
    /// fill the meter's slots.
    let recent: [String]
    let stage: Stage

    /// - Parameters:
    ///   - follows: the contact list in its stored order (newest last).
    ///   - owner: the account's own hex pubkey, which the app keeps in its
    ///     follow set but which is not a follow.
    ///   - masterEarned: whether this account has built its web of trust before.
    init(follows: [String], owner: String, masterEarned: Bool) {
        var seen = Set<String>()
        let people = follows.filter { $0 != owner && !$0.isEmpty && seen.insert($0).inserted }
        count = people.count
        recent = Array(people.suffix(Self.goal))
        stage = masterEarned || count >= Self.goal ? .master : .filling
    }

    /// Slots in the meter's row.
    var slots: Int { Self.goal }

    /// "3 of 5". Capped at the row's size.
    var progressText: String { "\(min(count, slots)) of \(slots)" }

    /// The short form for the largest text sizes: "3/5".
    var compactProgressText: String { "\(min(count, slots))/\(slots)" }

    /// Read by VoiceOver / TalkBack for the whole meter.
    var accessibilityText: String {
        let n = min(count, slots)
        let people = n == 1 ? "person" : "people"
        if stage == .master { return "Web of trust built. \(n) of \(slots) \(people) followed." }
        return "\(n) of \(slots) \(people) followed."
    }

    /// An account that already follows this many never sees the guide: it is
    /// marked finished straight away, because page tutorials only start once
    /// "Fill your vault" is finished or skipped.
    static func skipsGuide(followCount: Int) -> Bool { followCount >= goal }
}

/// Remembers, per account, that the web of trust (5 follows) was built, so the gold meter
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
    /// builds the web of trust, which is when the celebration plays.
    @discardableResult
    func record(_ meter: VaultMeter, owner: String) -> Bool {
        guard !owner.isEmpty, meter.count >= VaultMeter.goal, !isEarned(owner: owner) else { return false }
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
            // Only crossing 5 finishes it. A replay opened at 7 stays open
            // until the person closes it.
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
