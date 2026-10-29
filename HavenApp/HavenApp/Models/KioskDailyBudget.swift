import Foundation

/// What strangers may pull from an iPhone kiosk in one day, all sharing
/// sessions together.
///
/// The engine caps one sharing session, and a session starts again after the
/// cool-down and every time the owner comes back to the app. At the strangers'
/// 1 MB/s that was about 1 GB every 20 minutes on a phone's data plan. Now the
/// bytes sent to strangers are counted across sessions and saved, each session
/// gets only what is left of today, and at the limit strangers wait until
/// tomorrow. My Devices are not counted and never wait. Kept free of UIKit so
/// MediaLogicTests can check it.
struct KioskDailyBudget: Codable, Equatable {
    static let daily: Int64 = MeshDevicesLogic.kioskStrangersTotal

    /// Local day, `yyyy-MM-dd`.
    var day: String
    var usedBytes: Int64 = 0
    /// The engine's strangers `tx` at the last poll; nil until the first poll
    /// of a newly started engine.
    var lastEngineTx: UInt64?

    var remaining: Int64 { max(0, Self.daily - usedBytes) }
    var spent: Bool { remaining == 0 }

    /// The limit sent to the engine for a new session. Never 0: the engine
    /// reads 0 as its 1 GB default.
    var sessionLimit: Int64 { max(1, remaining) }

    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// The start of the day after `date`: when a spent budget fills again.
    static func nextDay(after date: Date, calendar: Calendar = .current) -> Date {
        let start = calendar.startOfDay(for: date)
        return calendar.date(byAdding: .day, value: 1, to: start) ?? date.addingTimeInterval(24 * 60 * 60)
    }

    /// A new day starts from nothing used.
    mutating func roll(to now: Date, calendar: Calendar = .current) {
        let today = Self.dayKey(now, calendar: calendar)
        guard day != today else { return }
        day = today
        usedBytes = 0
    }

    /// A new engine counts from zero.
    mutating func engineStarted() {
        lastEngineTx = nil
    }

    /// The engine reported its session limit. Returns when strangers may be
    /// served again. A session started today was given what was left of
    /// today, so today is spent (the 5 s poll may not have counted the last
    /// bytes yet) and they wait until tomorrow. A session started on an
    /// earlier day ran out on yesterday's numbers: share again now.
    mutating func capReached(sessionDay: String, now: Date, calendar: Calendar = .current) -> Date {
        roll(to: now, calendar: calendar)
        guard sessionDay == day else { return now }
        usedBytes = Self.daily
        return Self.nextDay(after: now, calendar: calendar)
    }

    /// Adds what the engine sent to strangers since the last poll. A count
    /// lower than the last one means the engine started counting again (a
    /// new session), so all of it is new.
    mutating func record(engineTx tx: UInt64, now: Date, calendar: Calendar = .current) {
        roll(to: now, calendar: calendar)
        let delta: UInt64
        if let last = lastEngineTx, tx >= last { delta = tx - last } else { delta = tx }
        lastEngineTx = tx
        usedBytes = min(Self.daily, usedBytes + Int64(clamping: delta))
    }
}
