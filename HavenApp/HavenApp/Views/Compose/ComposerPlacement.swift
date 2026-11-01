import Foundation

/// Where a photo's link sits in the note being written.
///
/// A photo is anchored at the caret the moment it is picked. Its upload runs
/// while the author keeps typing, so the anchor moves with every edit before
/// it, and the link is written in at the anchor once the upload lands. A link
/// the author deletes from the text, or a photo whose link never landed in it,
/// goes at the end of the note on Post, as every photo did before.
///
/// All offsets are UTF-16 code units, the unit `UITextView` and `NSTextView`
/// report selections in.
enum ComposerPlacement {
    /// The part of `old` that an edit replaced to make `new`: `start` to
    /// `oldEnd` in `old` became `start` to `newEnd` in `new`. Found from the
    /// common prefix and suffix, so one typed character, a paste and a
    /// replaced mention all come out as one range.
    struct Edit: Equatable {
        let start: Int
        let oldEnd: Int
        let newEnd: Int
        var delta: Int { newEnd - oldEnd }
    }

    static func edit(from old: String, to new: String) -> Edit {
        let a = Array(old.utf16), b = Array(new.utf16)
        let maxLen = min(a.count, b.count)
        var prefix = 0
        while prefix < maxLen && a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < maxLen - prefix && a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        return Edit(start: prefix, oldEnd: a.count - suffix, newEnd: b.count - suffix)
    }

    /// A photo's anchor after an edit. Text typed at the anchor goes after the
    /// photo (the author picked it, then kept writing); text inserted before it
    /// pushes it along; an anchor inside deleted text falls to where the
    /// deletion began.
    static func shiftAnchor(_ anchor: Int, old: String, new: String) -> Int {
        let e = edit(from: old, to: new)
        if anchor <= e.start { return anchor }
        if anchor >= e.oldEnd { return anchor + e.delta }
        return e.start
    }

    /// The caret after the app itself changed the text (a mention filled in,
    /// a link written in): a caret at or past the change moves with it, one
    /// inside it lands after what was written.
    static func followCaret(_ caret: Int, old: String, new: String) -> Int {
        let e = edit(from: old, to: new)
        if caret >= e.oldEnd { return caret + e.delta }
        if caret <= e.start { return caret }
        return e.newEnd
    }

    /// `text` with `link` written in at `offset`, on a line of its own so every
    /// reader shows the photo where it was put rather than mid-sentence. The
    /// spaces around the offset give way to the line breaks.
    /// Returns the new text and the UTF-16 offset just past the link.
    static func insert(_ link: String, at offset: Int, in text: String) -> (text: String, end: Int) {
        let units = Array(text.utf16)
        let space: UInt16 = 0x20, newline: UInt16 = 0x0A
        var start = max(0, min(offset, units.count))
        var end = start
        while start > 0 && units[start - 1] == space { start -= 1 }
        while end < units.count && units[end] == space { end += 1 }
        let lead = (start == 0 || units[start - 1] == newline) ? "" : "\n"
        let trail = (end == units.count || units[end] == newline) ? "" : "\n"
        let head = String(decoding: units[..<start], as: UTF16.self)
        let tail = String(decoding: units[end...], as: UTF16.self)
        return (head + lead + link + trail + tail, start + (lead + link).utf16.count)
    }

    /// `text` without `link`, and the line break that set it apart, so taking
    /// a photo out of a note leaves no gap behind.
    static func remove(_ link: String, from text: String) -> String {
        guard !link.isEmpty, let range = text.range(of: link) else { return text }
        var lower = range.lowerBound, upper = range.upperBound
        if upper < text.endIndex, text[upper] == "\n" {
            upper = text.index(after: upper)
        } else if lower > text.startIndex, text[text.index(before: lower)] == "\n" {
            lower = text.index(before: lower)
        }
        var out = text
        out.removeSubrange(lower..<upper)
        return out
    }

    /// The note's text with every hosted link the author did not place
    /// added at the end, one per line, in the order the photos were picked.
    static func withUnplacedLinks(_ text: String, links: [String]) -> String {
        var out = text
        for link in links where !link.isEmpty && !out.contains(link) {
            out += "\n\(link)"
        }
        return out
    }

    /// Items sorted by where their link first appears in `content`, which is
    /// the order NIP-92 `imeta` tags follow. Items whose link is missing keep
    /// their relative order at the end.
    static func contentOrder<T>(_ items: [T], link: (T) -> String, in content: String) -> [T] {
        let positions = items.map { item -> Int in
            guard let r = content.range(of: link(item)) else { return Int.max }
            return content.utf16.distance(from: content.startIndex, to: r.lowerBound)
        }
        return items.indices
            .sorted { (positions[$0], $0) < (positions[$1], $1) }
            .map { items[$0] }
    }
}
