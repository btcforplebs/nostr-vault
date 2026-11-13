import Foundation

/// The Vault list's fold for strangers' likes and reposts (Logen 2026-11-13
/// "go all", option A): All leaves them out (`build(foldsOutsideLikes:)`) and
/// shows one "N from outside your web" line instead, which opens the
/// "Outside your web" filter where they are listed. Web twin:
/// web-vault/src/net/outside-fold.js.
extension VaultActivity {
    /// The kinds that fold when they come from outside your web. Zaps cost the
    /// sender sats and follows are about you, so both keep their lines.
    static let foldedKinds: Set<Kind> = [.reaction, .repost]

    /// The line's N: each person once per line, as the faces count them.
    /// In Zaps Only mode likes don't show anywhere, so they don't count.
    static func outsideLikeCount(_ outsideLines: [VaultActivity], zapsOnly: Bool = false) -> Int {
        outsideLines
            .filter { foldedKinds.contains($0.kind) && !(zapsOnly && $0.kind == .reaction) }
            .reduce(0) { $0 + $1.actors.count }
    }

    /// "3 from outside your web".
    static func outsideLabel(_ count: Int) -> String {
        "\(count) from outside your web"
    }
}
