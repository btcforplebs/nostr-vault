import Foundation

/// What the copy screen shows once the files are here (Logen's iPad ← Mac
/// run, 2026-11-06): saving has no byte count the engine can move, so the
/// bar slides instead of sitting frozen, with counts under it; the relay
/// catch-up that follows can be skipped. Pure Foundation for MediaLogicTests.
enum CopySaving {
    /// Saving and the relay catch-up: a sliding bar, not a value bar
    /// (restoring notes reports bytes 0/N until it ends).
    static func slides(_ p: MeshCopyV2.Progress) -> Bool {
        p.stage == "restoring" || p.stage == "relays"
    }

    /// The relay catch-up after the copy: Skip stops it and the copy ends.
    static func canSkip(_ p: MeshCopyV2.Progress) -> Bool {
        p.stage == "relays"
    }

    /// The import job the engine runs for the catch-up (haven-go jobSetup).
    static let relayJob = "setup"

    /// "12,345 notes · 340 of 1,200 photos and videos". Notes come from the
    /// vault's own count (nil until the first answer); photos from the
    /// copy's own line while media is saved. Nil when there is nothing yet.
    static func countsLine(notes: Int?, progress: MeshCopyV2.Progress?) -> String? {
        var parts: [String] = []
        if let notes { parts.append("\(grouped(notes)) \(notes == 1 ? "note" : "notes")") }
        if let p = progress, p.stage == "restoring", p.part == "media", p.items.total > 0 {
            parts.append("\(grouped(p.items.done)) of \(grouped(p.items.total)) photos and videos")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// How often the screen asks the vault for its note count while saving.
    static let countEvery: TimeInterval = 3

    private static func grouped(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US")
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}
