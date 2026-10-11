import SwiftUI

/// The relay's report on a web-of-trust rebuild (`WotRefreshProgressC`).
struct WotRefresh: Decodable {
    let running: Bool
    let phase: String
    let batches: Int
    let batchesDone: Int
    let lists: Int
    let size: Int
    /// People this rebuild has found so far, and how many of them weren't on
    /// the old map. Missing from a relay older than the live fill.
    let found: Int?
    let new: Int?

    static func progress() -> WotRefresh? {
        guard let pointer = WotRefreshProgressC() else { return nil }
        defer { free(pointer) }
        return try? JSONDecoder().decode(WotRefresh.self, from: Data(String(cString: pointer).utf8))
    }

    /// The running (or last) rebuild's newcomers from index `from` on, and
    /// how many there are in all (`WotNewcomersC`). Pass the last total back
    /// in to get only the people found since.
    static func newcomers(from: Int) -> Newcomers? {
        guard let pointer = WotNewcomersC(Int32(clamping: from)) else { return nil }
        defer { free(pointer) }
        return try? JSONDecoder().decode(Newcomers.self, from: Data(String(cString: pointer).utf8))
    }

    struct Newcomers: Decodable {
        let total: Int
        let pubkeys: [String]
    }

    /// How far through the rebuild, 0 to 1. A relay can take a minute to
    /// answer, so inside a phase the bar creeps toward the next one with
    /// time and never reaches it until the relay says so.
    func fraction(phaseSeconds: TimeInterval) -> Double {
        let creep = 1 - exp(-phaseSeconds / 25)
        switch phase {
        case "follows": return 0.02 + 0.2 * creep
        case "lists":
            let done = batches == 0 ? 0 : Double(batchesDone) / Double(batches)
            let next = batches == 0 ? 1 : Double(batchesDone + 1) / Double(batches)
            return 0.25 + 0.7 * (done + (min(1, next) - done) * creep)
        case "counting": return 0.97
        default: return 1
        }
    }

    var caption: String {
        switch phase {
        case "follows": return "Reading your follow list…"
        // The relay counts lists per batch, so a running count sat still.
        case "lists":
            return batches > 1 ? "Reading your follows' lists… part \(min(batchesDone + 1, batches)) of \(batches)"
                : "Reading your follows' lists…"
        case "counting": return "Counting who your web trusts…"
        case "saved": return "Your web: \(size.formatted()) people"
        default: return "Rebuild stopped. Showing your last saved web."
        }
    }
}
