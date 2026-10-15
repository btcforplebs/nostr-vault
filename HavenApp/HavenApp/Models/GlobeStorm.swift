import Foundation

/// The storm: every arrival on the globe at once, in real time (Logen,
/// 10/15). What lets hundreds of lines fly without the phone choking: how
/// busy counts as busy, how many get faces, how lines are drawn in a few
/// batches, and how the globe's REQs share the feed's open connections.
extension GlobeArcs {
    /// From this many lines in flight the globe draws at full frame rate;
    /// below it, the slow rate that keeps the phone cool.
    static let busyLines = 12
    /// People pictured at the ends of lines. The rest stay stars: hundreds
    /// of faces would cost more than all the lines together.
    static let maxArcFaces = 24
    /// In a storm the faces change at most this often: each change redraws
    /// every picture, which cost more than the lines themselves.
    static let faceRefresh: TimeInterval = 0.5

    // MARK: Batched drawing

    /// Opacity steps lines are drawn in. Lines at the same step share one
    /// path and one fill, so the draw count stays flat however many fly.
    static let alphaBands = 12

    /// The step an opacity is drawn at; 0 for nothing to draw.
    static func band(_ alpha: Double) -> Int {
        guard alpha > 0.01 else { return 0 }
        return max(1, min(alphaBands, Int((alpha * Double(alphaBands)).rounded())))
    }

    /// The opacity a step is drawn with.
    static func bandAlpha(_ band: Int) -> Double { Double(band) / Double(alphaBands) }

    /// Points along a drawn trail: smooth for a few lines, fewer in a storm.
    static func arcSamples(lines: Int) -> Int { lines > 60 ? 16 : 40 }

    // MARK: Sharing the feed's connections

    /// Every globe subscription id starts with this. The feed skips
    /// messages under it on the connections they share, so a Global star
    /// never lands in the feed or in your relay.
    static let subscriptionPrefix = "arcs-"

    /// True for a relay message (`EVENT`, `EOSE`, `CLOSED`) that answers one
    /// of the globe's subscriptions. Parsed as JSON, not matched on its head:
    /// a relay may put any whitespace between the tokens, or escape the sub
    /// id, and a globe EVENT missed here goes into the feed and your relay
    /// (Tron, 10/15).
    static func isGlobeMessage(_ message: String) -> Bool {
        guard let array = try? JSONSerialization.jsonObject(with: Data(message.utf8)) as? [Any],
              array.count >= 2, let type = array[0] as? String, ["EVENT", "EOSE", "CLOSED"].contains(type),
              let id = array[1] as? String else { return false }
        return id.hasPrefix(subscriptionPrefix)
    }

    /// The `CLOSE` messages that end `requests`' subscriptions: only the
    /// globe's own, never one of the feed's on the same connection.
    static func closes(for requests: [String]) -> [String] {
        requests.compactMap { request in
            guard let data = request.data(using: .utf8),
                  let array = try? JSONSerialization.jsonObject(with: data) as? [Any],
                  array.first as? String == "REQ", let id = array.dropFirst().first as? String,
                  id.hasPrefix(subscriptionPrefix),
                  let close = try? JSONSerialization.data(withJSONObject: ["CLOSE", id]) else { return nil }
            return String(data: close, encoding: .utf8)
        }
    }

    /// The globe's filters on one read relay. Discover and Global are one
    /// filter with no authors, the relay's whole live stream: every note
    /// is sorted to its feed by its author here, so the whole of your wider
    /// web is in it (not just the first 1,500) and it costs one
    /// subscription however big the web is. Your follows alone keep to
    /// their authors, a filter of up to 500 each.
    static func storm(rings: Set<Ring>, show: Show, follows: [String], since: Int,
                      authorsPerFilter: Int = 500) -> [[String: Any]] {
        var kinds = show.wideKinds
        if show.zaps { kinds.append(zapKind) }
        guard !kinds.isEmpty, !rings.isEmpty else { return [] }
        if rings.contains(.discover) || rings.contains(.global) {
            return [["kinds": kinds, "since": since]]
        }
        // Following only: zap receipts carry the LNURL server's key, so they
        // stay one authorless filter of their own.
        let noteKinds = show.wideKinds
        var filters: [[String: Any]] = noteKinds.isEmpty ? [] : stride(from: 0, to: follows.count, by: authorsPerFilter).map {
            ["kinds": noteKinds, "since": since,
             "authors": Array(follows[$0..<min($0 + authorsPerFilter, follows.count)])]
        }
        if show.zaps { filters.append(["kinds": [zapKind], "since": since]) }
        return filters
    }

    // MARK: Debug counters

    /// Arrivals per minute, over the last minute: how wild the real network
    /// gets. Counts each note once, however many relays send it.
    struct RateMeter {
        private var times: [TimeInterval] = []
        private var ids: Set<String> = []
        private var order: [(String, TimeInterval)] = []
        static let window: TimeInterval = 60

        mutating func record(_ id: String, at now: TimeInterval) {
            trim(now)
            guard ids.insert(id).inserted else { return }
            order.append((id, now))
            times.append(now)
        }

        /// Notes in the last minute.
        mutating func perMinute(at now: TimeInterval) -> Int {
            trim(now)
            return times.count
        }

        private mutating func trim(_ now: TimeInterval) {
            let cutoff = now - Self.window
            let stale = order.prefix { $0.1 < cutoff }.count
            guard stale > 0 else { return }
            for (id, _) in order.prefix(stale) { ids.remove(id) }
            order.removeFirst(stale)
            times.removeFirst(stale)
        }
    }

    /// Frame times under load, for the debug readout and the stress run:
    /// how long a frame's work took and how far apart frames landed.
    struct FrameStats {
        private(set) var work: [Double] = []
        private(set) var gaps: [Double] = []
        static let keep = 300

        mutating func record(work: Double, gap: Double?) {
            self.work.append(work)
            if let gap { gaps.append(gap) }
            if self.work.count > Self.keep { self.work.removeFirst(self.work.count - Self.keep) }
            if gaps.count > Self.keep { gaps.removeFirst(gaps.count - Self.keep) }
        }

        static func percentile(_ values: [Double], _ p: Double) -> Double {
            guard !values.isEmpty else { return 0 }
            let sorted = values.sorted()
            return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
        }

        /// "work avg/p95, gap avg/p95" in milliseconds.
        var summary: String {
            func ms(_ v: Double) -> String { String(format: "%.1f", v * 1000) }
            let avgWork = work.isEmpty ? 0 : work.reduce(0, +) / Double(work.count)
            let avgGap = gaps.isEmpty ? 0 : gaps.reduce(0, +) / Double(gaps.count)
            return "work \(ms(avgWork))/\(ms(Self.percentile(work, 0.95))) ms, "
                + "gap \(ms(avgGap))/\(ms(Self.percentile(gaps, 0.95))) ms"
        }
    }
}
