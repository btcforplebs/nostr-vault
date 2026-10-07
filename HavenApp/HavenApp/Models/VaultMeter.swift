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

    /// An account that already follows this many never sees the guide.
    static func skipsGuide(followCount: Int) -> Bool { followCount >= masterGoal }
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
