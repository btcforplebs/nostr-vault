import Foundation

/// Merging this device's entries into a list published by any client. NIP-51
/// lists are replaceable, so publishing only what this device holds deletes
/// everything another client added. Twin of `ListMerge` in Android's
/// `NostrServiceListPublishing.kt`.
enum ListMerge {
    static let basesFileName = "list_publish_bases.json"

    /// Compares entries regardless of case, padding and a trailing slash.
    static func key(_ value: String) -> String {
        var out = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while out.hasSuffix("/") { out.removeLast() }
        return out.lowercased()
    }

    /// `local` as `[name, value]` tags, then the `published` tags kept: every
    /// tag of another name, and a `name` tag that is not local when
    /// `keepPublished` says so.
    static func tags(name: String, local: [String], published: [[String]],
                     keepPublished: (String) -> Bool) -> [[String]] {
        var seen = Set<String>()
        let mine = local
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && seen.insert(key($0)).inserted }
            .map { [name, $0] }
        let kept = published.filter { tag in
            guard let first = tag.first else { return false }
            if first != name { return true }
            return tag.count >= 2 && keepPublished(tag[1]) && seen.insert(key(tag[1])).inserted
        }
        return mine + kept
    }

    /// A block or unblock on a list other clients edit too: every `base` tag
    /// kept as it is, the `name` tags for `remove` taken out, and `add` put
    /// at the end unless already there. Replacing the whole `name` part with
    /// this device's entries dropped people another app had just added.
    static func edit(name: String, base: [[String]], add: [String], remove: [String]) -> [[String]] {
        let removed = Set(remove.map(key))
        var out = base.filter { tag in
            !(tag.first == name && tag.count >= 2 && removed.contains(key(tag[1])))
        }
        var present = Set(out.compactMap { $0.first == name && $0.count >= 2 ? key($0[1]) : nil })
        for value in add where !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !removed.contains(key(value)) && present.insert(key(value)).inserted {
            out.append([name, value])
        }
        return out
    }

    /// The private part of a kind 10000 with people taken out: the decrypted
    /// `plaintext` without the `p` entries for `remove` (hex), as JSON again.
    /// Nil when no one in `remove` is in it, or when it is not exactly a JSON
    /// array of string arrays: writing it back would then lose what it holds.
    static func privateRemoved(plaintext: String, remove: [String]) -> String? {
        guard let data = plaintext.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return nil }
        var tags: [[String]] = []
        for item in array {
            guard let tag = item as? [Any] else { return nil }
            let strings = tag.compactMap { $0 as? String }
            guard strings.count == tag.count else { return nil }
            tags.append(strings)
        }
        let edited = edit(name: "p", base: tags, add: [], remove: remove)
        guard edited.count < tags.count,
              let out = try? JSONSerialization.data(withJSONObject: edited, options: [.withoutEscapingSlashes]) else { return nil }
        return String(data: out, encoding: .utf8)
    }

    /// What an unblock leaves in the encrypted content.
    enum PrivateEdit: Equatable {
        case content(String)
        /// The person was taken out but the part couldn't be encrypted again.
        case failed
    }

    /// `content` with `remove` (hex) taken out of its encrypted `p` entries,
    /// encrypted again with the scheme it came in: NIP-04 when it has "?iv=",
    /// else NIP-44. `decrypt` and `encrypt` take the text and whether it is
    /// NIP-04. Unchanged when no one in `remove` is in it or this device can't
    /// open it; then reading the list back can't re-block them either.
    static func removingPrivate(content: String, remove: [String],
                                decrypt: (String, Bool) async throws -> String,
                                encrypt: (String, Bool) async throws -> String) async -> PrivateEdit {
        let ciphertext = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remove.isEmpty, !ciphertext.isEmpty else { return .content(content) }
        let nip04 = MuteList.isNip04(ciphertext)
        guard let plaintext = try? await decrypt(ciphertext, nip04),
              let edited = privateRemoved(plaintext: plaintext, remove: remove) else { return .content(content) }
        guard let encrypted = try? await encrypt(edited, nip04), !encrypted.isEmpty else { return .failed }
        return .content(encrypted)
    }

    /// What an edit builds on.
    enum EditBase<Event> {
        /// The newest list, published or already held here.
        case list(Event)
        /// Every relay answered and none has a list.
        case none
        /// Not known: publishing could replace a list this device never saw.
        case unknown
    }

    /// The newest of the list the relays returned and the one this device
    /// already `held`. Unknown when no relay answered, when no list turned up
    /// and some relay didn't answer, or when none of the account's `own`
    /// relays was heard from: neither sent the list nor every one answered.
    /// A copy on another relay alone can be older than the one on `own`.
    static func editBase<Event>(_ lookup: ReplaceableLookup<Event>, held: Event?, own: [String] = [],
                                createdAt: (Event) -> Int64) -> EditBase<Event> {
        guard lookup.answered > 0 else { return .unknown }
        let mine = Set(own.map(relayKey))
        let ownHeard = mine.isEmpty || mine.isSubset(of: Set(lookup.answeredBy.map(relayKey)))
            || lookup.from.contains { mine.contains(relayKey($0)) }
        guard ownHeard else { return .unknown }
        if let newest = [lookup.event, held].compactMap({ $0 }).max(by: { createdAt($0) < createdAt($1) }) {
            return .list(newest)
        }
        return lookup.confirmedNone ? .none : .unknown
    }

    private static func relayKey(_ url: String) -> String {
        var key = url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while key.hasSuffix("/") { key.removeLast() }
        return key
    }

    /// What this device last published per list, so the next publish can tell
    /// an entry another client added from one removed here. A list with no
    /// base yet (the first publish after this shipped) keeps every published
    /// entry: a removal made in that one publish stays on the published list,
    /// which only other clients read, rather than another client's entries
    /// being wiped.
    final class Bases {
        private let file: URL
        private static let lock = NSLock()

        init(file: URL) { self.file = file }

        /// The store in Application Support/Haven.
        static var shared: Bases {
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("Haven", isDirectory: true)
            return Bases(file: dir.appendingPathComponent(basesFileName))
        }

        func get(_ key: String) -> [String]? {
            Self.lock.lock(); defer { Self.lock.unlock() }
            return read()[key]
        }

        func put(_ key: String, _ entries: [String]) {
            Self.lock.lock(); defer { Self.lock.unlock() }
            var all = read()
            all[key] = entries
            do {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(all).write(to: file, options: .atomic)
            } catch {
                #if DEBUG
                print("ListMerge: list base not saved: \(error)")
                #endif
            }
        }

        private func read() -> [String: [String]] {
            guard let data = try? Data(contentsOf: file),
                  let all = try? JSONDecoder().decode([String: [String]].self, from: data) else { return [:] }
            return all
        }
    }
}
