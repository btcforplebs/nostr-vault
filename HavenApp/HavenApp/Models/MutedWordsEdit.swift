import Foundation

/// Adding and removing muted words (`["word", "<lowercase>"]`) on a kind
/// 10000 that other clients edit too. Only `word` entries for the words named
/// change: people, hashtags, threads, other words and the rest of the
/// encrypted part stay as they are. A word lives on one side: putting it in
/// the public tags takes it out of the private part, and the other way round.
/// Same rules as blocks (`ListMerge.addingPrivate` / `removingPrivate`).
/// Web twin: muted-words.js; Android: NostrServiceMutedWords.kt.
enum MutedWordsEdit {
    /// The longest word or phrase taken. Longer text is refused.
    static let maxLength = 100

    /// What a typed word is stored as: trimmed, lowercased, inner runs of
    /// white space made one space. Nil when empty, too long, or a lone "#"
    /// (a hashtag mute is a `t` entry, not a word).
    static func normalized(_ typed: String) -> String? {
        let parts = typed.lowercased().split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        let word = parts.joined(separator: " ")
        guard !word.isEmpty, word.count <= maxLength, word != "#" else { return nil }
        return word
    }

    /// What a stored or named word is matched by: `normalized` without the
    /// length cap and the "#" rule, so a word another app saved that
    /// `normalized` would refuse can still be removed or moved. Nil when empty.
    static func key(_ text: String) -> String? {
        let word = text.lowercased().split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        return word.isEmpty ? nil : word
    }

    /// `tags` with a `word` entry for each of `add` it doesn't hold yet, put
    /// at the end, and every `word` entry for `remove` taken out. Words are
    /// compared by `key`, so "Spoiler " and "spoiler" are one.
    static func edited(_ tags: [[String]], add: [String], remove: [String]) -> [[String]] {
        let removed = Set(remove.compactMap(key))
        var out = tags.filter { tag in
            !(tag.count >= 2 && tag[0] == "word" && key(tag[1]).map(removed.contains) == true)
        }
        var present = Set(out.compactMap { $0.count >= 2 && $0[0] == "word" ? key($0[1]) : nil })
        for word in add.compactMap(key) where !removed.contains(word) && present.insert(word).inserted {
            out.append(["word", word])
        }
        return out
    }

    /// The words held in `tags`, by `key`.
    static func words(in tags: [[String]]) -> Set<String> {
        Set(tags.compactMap { $0.count >= 2 && $0[0] == "word" ? key($0[1]) : nil })
    }

    /// The decrypted private part as tags, or nil when it is not exactly a
    /// JSON array of string arrays: writing it back would lose what it holds.
    /// Empty or blank text is an empty part (`[]`): it holds nothing to lose.
    static func strictTags(_ plaintext: String) -> [[String]]? {
        if plaintext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [] }
        guard let data = plaintext.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return nil }
        var tags: [[String]] = []
        for item in array {
            guard let tag = item as? [Any] else { return nil }
            let strings = tag.compactMap { $0 as? String }
            guard strings.count == tag.count else { return nil }
            tags.append(strings)
        }
        return tags
    }

    /// The whole edit: the new public tags and encrypted content.
    struct Result: Equatable {
        var tags: [[String]]
        var content: String
    }

    /// Why an edit can't be published. Nothing is published then.
    enum Failure: Error, Equatable {
        /// No word to add or remove.
        case nothingToDo
        /// The private part had to change but couldn't be opened, rewritten
        /// and checked: publishing would lose it, or keep a removed word.
        case privatePart
    }

    /// `add` put in the public tags (`publicly`) or the encrypted part, and
    /// taken out of the other side; `remove` taken out of both. `knownPrivate`:
    /// the words this device read in the private part. When the part can't be
    /// opened, adding to it fails, and so does removing a word known to be in
    /// it; anything else keeps the content as it is. A changed part is
    /// encrypted again with the scheme it came in (NIP-04 when it has "?iv=",
    /// else NIP-44; an empty one starts NIP-44) and must open again to the
    /// edited part, so a signer that echoes the text back never gets
    /// published. (This check can't catch a signer using another key: NIP-04
    /// and NIP-44 derive the same shared key from either side, so it would
    /// open its own text. That case is stopped by the pubkey check on the
    /// signed event, `SignerReplyCheck` in `signEventAsync`.) Words are
    /// matched by `key`, so one saved by another app longer than `maxLength`
    /// can still be moved or removed; typed words are checked by `normalized`
    /// before they get here. `decrypt` and `encrypt` take the text and whether
    /// it is NIP-04.
    static func apply(tags: [[String]], content: String, add: [String], remove: [String],
                      publicly: Bool, knownPrivate: Set<String>,
                      decrypt: (String, Bool) async throws -> String,
                      encrypt: (String, Bool) async throws -> String) async -> Swift.Result<Result, Failure> {
        let adding = add.compactMap(key), removing = remove.compactMap(key)
        let knownPrivate = Set(knownPrivate.compactMap(key))
        guard !adding.isEmpty || !removing.isEmpty else { return .failure(.nothingToDo) }
        let newTags = publicly
            ? edited(tags, add: adding, remove: removing)
            : edited(tags, add: [], remove: adding + removing)
        let privateAdd = publicly ? [] : adding
        let privateRemove = publicly ? adding + removing : removing

        let ciphertext = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if ciphertext.isEmpty {
            guard !privateAdd.isEmpty else { return .success(Result(tags: newTags, content: content)) }
        }
        let nip04 = !ciphertext.isEmpty && MuteList.isNip04(ciphertext)
        let plaintext: String
        if ciphertext.isEmpty {
            plaintext = "[]"
        } else if let opened = try? await decrypt(ciphertext, nip04) {
            plaintext = opened
        } else {
            let needed = !privateAdd.isEmpty || privateRemove.contains(where: knownPrivate.contains)
            return needed ? .failure(.privatePart) : .success(Result(tags: newTags, content: content))
        }
        guard let part = strictTags(plaintext) else {
            // Not ours to rewrite. Fine only when it holds none of the removed
            // words and none are to be added.
            let read = (try? MuteList.privateTags(fromJSON: plaintext)) ?? []
            let stays = privateAdd.isEmpty && words(in: read).isDisjoint(with: privateRemove)
            return stays ? .success(Result(tags: newTags, content: content)) : .failure(.privatePart)
        }
        let newPart = edited(part, add: privateAdd, remove: privateRemove)
        if newPart == part, !ciphertext.isEmpty { return .success(Result(tags: newTags, content: content)) }
        guard let data = try? JSONSerialization.data(withJSONObject: newPart, options: [.withoutEscapingSlashes]),
              let json = String(data: data, encoding: .utf8),
              let encrypted = try? await encrypt(json, nip04), !encrypted.isEmpty,
              MuteList.isNip04(encrypted) == nip04,
              let reopened = try? await decrypt(encrypted, nip04), reopened == json else { return .failure(.privatePart) }
        return .success(Result(tags: newTags, content: encrypted))
    }
}
