import Foundation

// MARK: - On this day, read for the widget
//
// The app half of the On this day widget: the user's own notes from today's
// date 1 and 2 years ago, read from their own vault (VaultSocket, never a
// relay) with Your space's rules (OnThisDay), kept for the day and handed to
// NVWidgetBridge. Read once per owner per day; a read that fails (the vault
// is not up yet) is tried again on the next publish, and an empty one after
// `emptyRetry` (the first import may still be filling the vault).

@MainActor
enum NVOnThisDayLoader {
    private static var current: (key: String, snapshot: NVOnThisDaySnapshot, readAt: Date)?
    static let emptyRetry: TimeInterval = 15 * 60
    private static var loadingKey: String?

    private static func key(owner: String, day: Date) -> String {
        "\(owner)|\(Int(day.timeIntervalSince1970))"
    }

    /// What the snapshot carries for `owner` today, or nil until it has been read.
    static func snapshot(owner: String, now: Date = Date()) -> NVOnThisDaySnapshot? {
        guard let current, current.key == key(owner: owner, day: Calendar.current.startOfDay(for: now)) else { return nil }
        return current.snapshot
    }

    /// Reads today's notes when they have not been read yet, then calls `done`
    /// (a forced widget publish) so the widget gets them.
    static func refreshIfNeeded(owner: String, done: @escaping @MainActor () -> Void) {
        let day = Calendar.current.startOfDay(for: Date())
        let k = key(owner: owner, day: day)
        guard !owner.isEmpty, loadingKey != k else { return }
        if let current, current.key == k {
            let empty = current.snapshot.years.allSatisfy { $0.notes.isEmpty }
            guard empty, Date().timeIntervalSince(current.readAt) >= emptyRetry else { return }
        }
        loadingKey = k
        Task { @MainActor in
            defer { if loadingKey == k { loadingKey = nil } }
            guard let read = await read(owner: owner, day: day) else { return }
            let changed = current?.key != k || current?.snapshot != read
            current = (k, read, Date())
            if changed { done() }
        }
    }

    private static func read(owner: String, day: Date) async -> NVOnThisDaySnapshot? {
        var years: [NVOnThisDaySnapshot.Year] = []
        for w in OnThisDay.windows(now: day) {
            guard let events = await VaultSocket.query(path: "", filter: OnThisDay.filter(owner: owner, w)) else { return nil }
            let notes = OnThisDay.notes(events.map {
                OnThisDay.Note(id: $0.id, pubkey: $0.pubkey, kind: $0.kind, createdAt: $0.created_at,
                               content: $0.content, tags: $0.tags)
            }, owner: owner, in: w)
            years.append(.init(years: w.years, notes: notes.map {
                .init(id: $0.id, text: OnThisDay.lineText($0.content),
                      createdAt: Date(timeIntervalSince1970: TimeInterval($0.createdAt)))
            }))
        }
        return NVOnThisDaySnapshot(dayStart: day, years: years)
    }
}
