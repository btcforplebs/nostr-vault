import Foundation

/// What a gated article's lock card says. The app doesn't sell articles, so
/// the card names no price and asks for no payment. A Fanfares article points
/// to Fanfares, where it is sold, and offers to re-check an unlock made there.
enum GatedLockCopy {
    static func status(author: String) -> String {
        "Locked by \(author). Only its unlocked readers can open it."
    }

    static func fanfaresStatus(author: String, failure: String?) -> String {
        if let failure { return failure }
        return "Locked by \(author). Unlock it on Fanfares, then tap Already unlocked? to read it here."
    }
}
