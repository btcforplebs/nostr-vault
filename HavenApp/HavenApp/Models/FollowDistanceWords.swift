import Foundation

/// The one place a Follow Distance level becomes words. The stored level is
/// what the relay runs (haven-go pkg/wot/simple_in_memory.go): 1 = only you,
/// 2 = the people you follow, 3 = the people they follow too. A hop is one
/// follow away from you and you are never a hop, so the levels read "Only
/// you", "1 hop" and "2 hops". The stored value, WOT_DEPTH and the mesh's
/// wot_depth keep the level; only the screen converts.
enum FollowDistanceWords {
    /// How many follows away the level reaches. 0 is only you.
    static func hops(_ level: Int) -> Int {
        RelayAccessLimits.clampedFollowDistance(level) - 1
    }

    /// The stepper's value and the Vault settings row: "Only you", "1 hop", "2 hops".
    static func short(_ level: Int) -> String {
        switch hops(level) {
        case 0: return "Only you"
        case 1: return "1 hop"
        case let n: return "\(n) hops"
        }
    }

    /// The Vault tab's "Who can reach you" line.
    static func reachDetail(_ level: Int) -> String {
        hops(level) == 0
            ? "Only you. Everyone else is kept out."
            : "People within \(short(level)) of you. Everyone else is kept out."
    }
}
