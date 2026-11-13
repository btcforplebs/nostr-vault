import Foundation

/// The line a Global view wears while the Everyone shield is on (Logen
/// 2026-11-13 "go all", option C), so a shield flipped once and kept can't go
/// unnoticed. Web twin: web-vault/src/net/global-trust.js EVERYONE_BANNER.
enum EveryoneBanner {
    static let text = "Everyone is on: these posts come from outside your web too, unfiltered."
    static let back = "Back to your web"

    /// Shown on the views the shield filters (Global, and Media, Articles and
    /// Polls on Global) while it is on.
    static func shows(everyone: Bool, globalLike: Bool) -> Bool {
        everyone && globalLike
    }
}
