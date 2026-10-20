import Foundation

/// What a gated article's lock card says. The app doesn't sell articles, so
/// the card names no price, links nowhere it is sold and asks for no payment.
enum GatedLockCopy {
    static func status(author: String) -> String {
        "Locked by \(author). Only its unlocked readers can open it."
    }
}
