import Foundation

/// What a gated article's lock card may say. Where the app can't pay
/// (iOS: buying digital content is App Store 3.1.1), it also must not point
/// to where the article is sold: no price, no link out, no "pay on the web".
/// It only offers to re-check an unlock made elsewhere.
struct GatedLockCopy {
    let paysHere: Bool

    var showsPrice: Bool { paysHere }

    /// The author's own unlock link, only where the app could pay anyway.
    func webLink(authorLink: URL?) -> URL? {
        paysHere ? authorLink : nil
    }

    func status(author: String, priceSats: Int, paid: Bool, fullyPaid: Bool,
                failure: String?, waiting: Bool) -> String {
        if let failure { return failure }
        if waiting { return "Paid. Waiting for the author's server to see your zap. This can take a minute or two." }
        if fullyPaid { return "You've zapped for this article. If it hasn't opened, the receipt is still on its way." }
        if paid {
            return paysHere
                ? "Part of the price went through. Zap the rest to unlock."
                : "This article isn't fully unlocked yet. Tap Already paid? to check again."
        }
        return paysHere
            ? "Zap \(author) \(priceSats) sats to read the full article here."
            : "Locked by \(author). Already unlocked it? Tap Already paid? to read it here."
    }
}
