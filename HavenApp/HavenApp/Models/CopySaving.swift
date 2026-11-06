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

    /// Saving or the relay catch-up: Skip goes in now and both carry on in
    /// the background (Logen, 2026-11-06 15:28Z). Shown whenever the bar
    /// slides, so it is there for as long as this screen is.
    static func canSkip(_ p: MeshCopyV2.Progress) -> Bool {
        slides(p)
    }

    /// The copy itself is finished at the relay catch-up: notes and media are
    /// saved and the accounts offered. Setup goes in then, without waiting for
    /// the catch-up's `done` line (it can take minutes and sends no lines).
    static func copyFinished(_ p: MeshCopyV2.Progress) -> Bool {
        p.stage == "relays" || p.stage == "done"
    }

    /// Saving runs on this device and sends no lines until it ends (33k
    /// notes took minutes on the iPad), so it is never a stall.
    static func mayStall(_ p: MeshCopyV2.Progress?) -> Bool {
        !(p.map(slides) ?? false)
    }

    /// The vault's stores the saved total adds up ("" is the public root),
    /// as StatsService counts them.
    static let storePaths = ["", "inbox", "private", "chat"]

    /// "12,345 notes · 340 of 1,200 photos and videos". Notes come from the
    /// vault's own count of everything saved (nil until the first answer); photos from the
    /// copy's own line while media is saved. Nil when there is nothing yet.
    static func countsLine(notes: Int?, progress: MeshCopyV2.Progress?) -> String? {
        var parts: [String] = []
        if let notes { parts.append("\(grouped(notes)) \(notes == 1 ? "note" : "notes")") }
        if let p = progress, p.stage == "restoring", p.part == "media", p.items.total > 0 {
            parts.append("\(grouped(p.items.done)) of \(grouped(p.items.total)) photos and videos")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// How often the screen asks the vault for its saved total while saving.
    static let countEvery: TimeInterval = 3

    private static func grouped(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US")
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}
