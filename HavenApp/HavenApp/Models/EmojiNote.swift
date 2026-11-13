import Foundation

/// The emoji part of a `/files` file note (RESEARCH/NV_CUSTOM_EMOJI_PLAN.md
/// §4.1, fixture `docs/fixtures/emoji-notes/`). A saved custom emoji image is
/// a normal vault blob with a 1063 that also says `["t","nv-emoji"]`, one
/// `["emoji", code, url]` per shortcode using the image and one
/// `["a","30030:<pk>:<d>"]` per set. Same tags on every platform; don't change
/// them without telling Tod. Pure, so MediaLogicTests checks it. Android:
/// `fips/FileNotes.kt`; web: `net/file-notes.js`.
struct EmojiNote: Equatable, Codable {
    static let marker = "nv-emoji"

    /// Shortcodes using this image, each with the link its set gives.
    var emoji: [CustomEmoji]
    /// The 30030 sets (`30030:<pk>:<d>`) it belongs to.
    var sets: [String]

    /// The tags a note adds for `emoji` (each carries its set in
    /// `setAddress`): the marker, one `emoji` tag per (code, url), one `a`
    /// per set. Bad codes, links and addresses are left out.
    static func tags(for emoji: [CustomEmoji]) -> [[String]] {
        var out: [[String]] = [["t", marker]]
        var seenCodes = Set<String>()
        var sets: [String] = []
        for e in emoji where CustomEmoji.isValidShortcode(e.shortcode) && CustomEmoji.isValidURL(e.url) {
            if seenCodes.insert(e.shortcode + "\u{0}" + e.url).inserted { out.append(["emoji", e.shortcode, e.url]) }
            if let a = e.setAddress, EmojiListParse.setRef(a) != nil, !sets.contains(a) { sets.append(a) }
        }
        return out + sets.map { ["a", $0] }
    }

    /// The emoji part of a file note's tags, or nil when it has no
    /// `["t","nv-emoji"]`. A tag of the wrong shape is skipped; the note is
    /// still an emoji note (fixture README).
    static func read(_ tags: [[String]]) -> EmojiNote? {
        guard tags.contains(where: { $0.count >= 2 && $0[0] == "t" && $0[1] == marker }) else { return nil }
        var emoji: [CustomEmoji] = []
        var seen = Set<String>()
        for tag in tags where tag.count >= 3 && tag[0] == "emoji" {
            let code = tag[1], url = tag[2].trimmingCharacters(in: .whitespaces)
            guard CustomEmoji.isValidShortcode(code), CustomEmoji.isValidURL(url),
                  seen.insert(code + "\u{0}" + url).inserted else { continue }
            emoji.append(CustomEmoji(shortcode: code, url: url))
        }
        var sets: [String] = []
        for tag in tags where tag.count >= 2 && tag[0] == "a" {
            if EmojiListParse.setRef(tag[1]) != nil, !sets.contains(tag[1]) { sets.append(tag[1]) }
        }
        return EmojiNote(emoji: emoji, sets: sets)
    }

    /// Two notes' emoji parts as one (same hash from two devices).
    func merged(with other: EmojiNote) -> EmojiNote {
        var out = self
        for e in other.emoji where !out.emoji.contains(e) { out.emoji.append(e) }
        for s in other.sets where !out.sets.contains(s) { out.sets.append(s) }
        return out
    }
}

/// One saved emoji image: a vault blob some emoji note names.
struct EmojiCopy: Equatable, Codable {
    let sha256: String
    var mime: String
    var size: Int64
    var note: EmojiNote
}

extension FileNotesState {
    /// Every hash an emoji note names, its emoji parts merged.
    var emojiCopies: [String: EmojiCopy] {
        var out: [String: EmojiCopy] = [:]
        for note in notes.values.sorted(by: { $0.createdAt != $1.createdAt ? $0.createdAt < $1.createdAt : $0.id < $1.id }) {
            guard let emoji = note.emoji else { continue }
            if var have = out[note.sha256] {
                have.note = have.note.merged(with: emoji)
                out[note.sha256] = have
            } else {
                out[note.sha256] = EmojiCopy(sha256: note.sha256, mime: note.mime, size: note.size, note: emoji)
            }
        }
        return out
    }

    /// Hashes whose every live note is an emoji note: kept out of Media. One
    /// plain note keeps the image in Media (fixture `photo-and-emoji.json`).
    var emojiOnlyHashes: Set<String> {
        var emoji = Set<String>(), plain = Set<String>()
        for note in notes.values {
            if note.emoji != nil { emoji.insert(note.sha256) } else { plain.insert(note.sha256) }
        }
        return emoji.subtracting(plain)
    }

    /// Hashes some plain (non-emoji) note names.
    var plainHashes: Set<String> {
        Set(notes.values.filter { $0.emoji == nil }.map(\.sha256))
    }
}
