import Foundation

/// What the media delete confirmation says, word for word the same as
/// Android's `DeleteBlobConfirmDialog` (one wording on both platforms, Logen
/// 2026-11-05). "This device" fits a phone and a Mac alike.
/// `MediaDeleteWordingTests` fails when the two apps drift apart.
enum MediaDeleteWording {
    static let mirrors = "Removes this file from your media servers. This device and your home vault keep their copies."
    static let everywhere = "Permanently removes this file from this device, your home vault and your media servers. This cannot be undone."

    static let noMirrors = "No mirrors to delete from"

    /// What a Delete from mirrors says, and whether it is a success. A server
    /// left alone because the owner runs it (NIP-11 pubkey) is named, so a
    /// delete that skipped one never reads as plain "Deleted from mirrors".
    /// Same words as Android `mirrorsDeleteMessage` and the web vault's.
    static func mirrorsReport(deleted: [String], failedHosts: [String], skippedHosts: [String]) -> (text: String, ok: Bool) {
        let skipped = skippedLine(skippedHosts)
        func withSkipped(_ text: String) -> String { skipped.isEmpty ? text : "\(text). \(skipped)" }
        if !failedHosts.isEmpty { return (withSkipped("Still on " + joined(failedHosts)), false) }
        if !deleted.isEmpty { return (withSkipped("Deleted from mirrors"), true) }
        return (withSkipped(noMirrors), false)
    }

    /// "Skipped: a (your own vault)", "Skipped: a and b (your own vaults)", or "" for none.
    static func skippedLine(_ hosts: [String]) -> String {
        switch hosts.count {
        case 0: return ""
        case 1: return "Skipped: \(hosts[0]) (your own vault)"
        default: return "Skipped: \(joined(hosts)) (your own vaults)"
        }
    }

    /// "a", "a and b", "a, b and c": the same on every platform and locale.
    static func joined(_ places: [String]) -> String {
        guard places.count > 1 else { return places.first ?? "" }
        return places.dropLast().joined(separator: ", ") + " and " + places[places.count - 1]
    }
}
