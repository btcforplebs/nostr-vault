import Foundation

/// A Media tab item's byte size, from whatever already knows it (A1, plan
/// RESEARCH/NV_MEDIA_LIST_SIZE_2026_11_26.md §2). In order of trust:
/// this device's own file, then the note that carries it (a kind 1063 `size`
/// tag, or the `size` in the post's `imeta` for this link). A row with none of
/// these asks the server (`MediaSizeLookup`, Z1).
///
/// Twin: Android keeps `BlossomMediaItem.size` the same way.
enum MediaItemSize {
    /// The first positive size, in the order given.
    static func first(_ sizes: Int64?...) -> Int64? {
        sizes.first { ($0 ?? 0) > 0 } ?? nil
    }

    /// The size a note's tags give for `url`: a kind 1063 top-level `size`,
    /// else the `size` of the `imeta` entry whose `url` (or `x` hash) is this
    /// file. Another file's imeta never counts.
    static func fromTags(_ tags: [[String]]?, url: URL) -> Int64? {
        guard let tags, !tags.isEmpty else { return nil }
        if let top = tags.first(where: { $0.count >= 2 && $0[0] == "size" }), let n = positive(top[1]) {
            return n
        }
        let link = url.absoluteString
        let hash = blossomHash(in: url)
        for tag in tags where tag.first == "imeta" {
            var fields: [String: String] = [:]
            for entry in tag.dropFirst() {
                let parts = entry.split(separator: " ", maxSplits: 1).map(String.init)
                if parts.count == 2, fields[parts[0]] == nil { fields[parts[0]] = parts[1] }
            }
            let sameLink = fields["url"] == link
            let sameHash = hash != nil && (fields["x"]?.lowercased() == hash || fields["url"].flatMap { URL(string: $0) }.flatMap(blossomHash) == hash)
            if sameLink || sameHash, let n = fields["size"].flatMap(positive) { return n }
        }
        return nil
    }

    /// The 64-hex hash in a Blossom link's last path part, lowercased.
    static func blossomHash(in url: URL) -> String? {
        let name = url.lastPathComponent.split(separator: ".").first.map { String($0).lowercased() } ?? ""
        return MediaSizeCache.isHash(name) ? name : nil
    }

    private static func positive(_ s: String) -> Int64? {
        guard let n = Int64(s.trimmingCharacters(in: .whitespaces)), n > 0 else { return nil }
        return n
    }
}

/// Largest / Smallest first (A2): a file of unknown size goes last either
/// way. Returns nil on a tie, so the caller falls back to its date order.
enum MediaSizeOrder {
    static func before(_ a: Int64?, _ b: Int64?, largestFirst: Bool) -> Bool? {
        let x = (a ?? 0) > 0 ? a : nil, y = (b ?? 0) > 0 ? b : nil
        switch (x, y) {
        case (nil, nil): return nil
        case (nil, _): return false
        case (_, nil): return true
        case let (x?, y?):
            if x == y { return nil }
            return largestFirst ? x > y : x < y
        }
    }

    /// A list row's detail line: "2.4 MB · Video · 3 Nov" ("3 Nov 2024" in
    /// another year), with "—" for an unknown size.
    static func rowLine(size: Int64?, type: String, date: Date, now: Date = Date(),
                        calendar: Calendar = .current, locale: Locale = .current) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        f.setLocalizedDateFormatFromTemplate(sameYear ? "dMMM" : "dMMMy")
        return [label(size), type, f.string(from: date)].joined(separator: " · ")
    }

    /// "2.4 MB" (ByteCountFormatter, .file, as the Vault contents), "—" when unknown.
    static func label(_ size: Int64?) -> String {
        guard let size, size > 0 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}
