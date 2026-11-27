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
        /// The person may be in the private part but it couldn't be rewritten
        /// and checked: publishing would leave them blocked, or lose the part.
        case failed
    }

    /// `content` with `remove` (hex) taken out of its encrypted `p` entries,
    /// encrypted again with the scheme it came in: NIP-04 when it has "?iv=",
    /// else NIP-44. `decrypt` and `encrypt` take the text and whether it is
    /// NIP-04. Unchanged only when no one in `remove` is in it, or when it
    /// can't be opened and `knownPrivate` (this device holds one of them as a
    /// private block) is false. The new content is opened again with `decrypt`
    /// and must give back the edited part in the same scheme, so a signer that
    /// echoes the plaintext or uses another key or account never gets published.
    static func removingPrivate(content: String, remove: [String], knownPrivate: Bool,
                                decrypt: (String, Bool) async throws -> String,
                                encrypt: (String, Bool) async throws -> String) async -> PrivateEdit {
        let ciphertext = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remove.isEmpty, !ciphertext.isEmpty else { return .content(content) }
        let nip04 = MuteList.isNip04(ciphertext)
        guard let plaintext = try? await decrypt(ciphertext, nip04) else {
            return knownPrivate ? .failed : .content(content)
        }
        guard let edited = privateRemoved(plaintext: plaintext, remove: remove) else {
            // What reading the list back sees: if it still has them, publishing
            // this content blocks them again.
            let read = (try? MuteList.privateTags(fromJSON: plaintext)) ?? []
            return edit(name: "p", base: read, add: [], remove: remove).count < read.count ? .failed : .content(content)
        }
        guard let encrypted = try? await encrypt(edited, nip04), !encrypted.isEmpty,
              MuteList.isNip04(encrypted) == nip04,
              let reopened = try? await decrypt(encrypted, nip04), reopened == edited else { return .failed }
        return .content(encrypted)
    }

    /// The private part of a kind 10000 with people put in: the decrypted
    /// `plaintext` with a `p` entry for each of `add` (hex) it doesn't hold
    /// yet, as JSON again. Nil when it is not exactly a JSON array of string
    /// arrays: writing it back would then lose what it holds.
    static func privateAdded(plaintext: String, add: [String]) -> String? {
        guard let data = plaintext.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return nil }
        var tags: [[String]] = []
        for item in array {
            guard let tag = item as? [Any] else { return nil }
            let strings = tag.compactMap { $0 as? String }
            guard strings.count == tag.count else { return nil }
            tags.append(strings)
        }
        let edited = edit(name: "p", base: tags, add: add, remove: [])
        guard let out = try? JSONSerialization.data(withJSONObject: edited, options: [.withoutEscapingSlashes]) else { return nil }
        return String(data: out, encoding: .utf8)
    }

    /// `content` with `add` (hex) put in its encrypted `p` entries: a private
    /// block. It is encrypted again with the scheme it came in (NIP-04 when it
    /// has "?iv=", else NIP-44); an empty content starts a NIP-44 one. Fails
    /// when there is no one to add, when the content can't be opened (a new
    /// one would lose what it holds), or when the new content doesn't open
    /// again to the edited part in the same scheme, as in `removingPrivate`.
    /// Android: ListMerge.addingPrivate.
    static func addingPrivate(content: String, add: [String],
                              decrypt: (String, Bool) async throws -> String,
                              encrypt: (String, Bool) async throws -> String) async -> PrivateEdit {
        guard !add.isEmpty else { return .failed }
        let ciphertext = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let nip04 = !ciphertext.isEmpty && MuteList.isNip04(ciphertext)
        let plaintext: String
        if ciphertext.isEmpty {
            plaintext = "[]"
        } else {
            guard let opened = try? await decrypt(ciphertext, nip04) else { return .failed }
            plaintext = opened
        }
        guard let edited = privateAdded(plaintext: plaintext, add: add),
              let encrypted = try? await encrypt(edited, nip04), !encrypted.isEmpty,
              MuteList.isNip04(encrypted) == nip04,
              let reopened = try? await decrypt(encrypted, nip04), reopened == edited else { return .failed }
        return .content(encrypted)
    }

    /// What an edit builds on.
    enum EditBase<Event> {
        /// The newest list, published or already held here.
        case list(Event)
        /// At least two relays answered, every one asked did, and none has a list.
        case none
        /// Not known: publishing could replace a list this device never saw.
        case unknown
        /// Not known because the account has no relay list (kind 10002) of its
        /// own yet, so there are no relays of its own to check. The app's
        /// default relays are not the account's: their "none" says nothing
        /// about a list kept elsewhere (Tron #1456/#1459 follow-up).
        case noRelayList
    }

    /// A copy dated this far ahead of now or more is skipped, as the web's
    /// follows.js MAX_SKEW: signed after it, an edit would have to be dated in
    /// the future too, and signed before it, relays keep the old copy.
    static let maxSkew: Int64 = 15 * 60

    /// What to tell the person when an edit was refused for `.noRelayList`.
    static let noRelayListMessage = "Your own relays aren't known: you have no relay list yet, or every relay in it is unreachable, so your newest list can't be checked. Nothing was changed. Fix your relays in Settings › Relays first."

    /// The account's own relays for checking a list: the write relays named
    /// in its own kind 10002 (`published`, nil when none is known here),
    /// `unusable` ones (loopback, known-dead hosts) dropped. Never the app's defaults: with no 10002 this is
    /// empty, and editBase says `.noRelayList`.
    static func ownRelays(published: [String]?, unusable: (String) -> Bool) -> [String] {
        var seen = Set<String>()
        return (published ?? []).filter { !unusable($0) && seen.insert(relayKey($0)).inserted }
    }

    /// Where an edit looks for the newest copy of a list besides the
    /// account's own relays: the first three read relays and the indexers.
    /// An account whose kind 10002 names one relay (often also its only read
    /// relay) then still gets the second answer `ownMajority` asks for: its
    /// own relay and an indexer (Logen 2026-11-02 13:21Z). Without the
    /// indexers Merge said "Not enough of your relays answered" forever.
    static func editLookupAsk(readRelays: [String]) -> [String] {
        var seen = Set<String>()
        return (Array(readRelays.prefix(3)) + RelayDraft.indexers).filter { seen.insert(relayKey($0)).inserted }
    }

    /// The created_at for an edit of a list dated `base`: now, or one second
    /// after the base when the base is ahead (a phone clock behind the other
    /// app's), so relays keep the edit. editBase never picks a base dated
    /// `maxSkew` or more ahead, so this is never further ahead than that.
    static func signedAt(now: Int64, base: Int64?) -> Int64 {
        max(now, (base ?? 0) + 1)
    }

    /// The newest of the list the relays returned and the one this device
    /// already `held`. Only the account's `own` relays (its write relays,
    /// loopback dropped) count towards most. A list is the base once more than
    /// half of them answered and at least two relays answered in all
    /// (`ownMajority`), and it is the newest copy among those that answered
    /// and the one held here. A single answer is never enough: one relay may
    /// send an old copy while a slower one holds a newer one (list-wipe audit
    /// 2026-11-02; Logen 13:21Z: most, not all). "None" still needs every own relay answering
    /// and knowsNone: with no base there is nothing to check a first list
    /// against. No own relays (no kind 10002 yet): `.noRelayList`. Copies dated `maxSkew` or more ahead of
    /// `now` are skipped, and one being found (here or by the lookup, `ahead`)
    /// means a list exists, so it is never "none".
    /// `own` has no default, so every call site has to name them (Tron #1459).
    static func editBase<Event>(_ lookup: ReplaceableLookup<Event>, held: Event?, own: [String],
                                now: Int64 = Int64(Date().timeIntervalSince1970),
                                createdAt: (Event) -> Int64) -> EditBase<Event> {
        editBase(lookup, held: held, own: own, now: now, createdAt: createdAt) { mine, ownAnswered in
            ownMajority(ownAnswered: ownAnswered, own: mine.count, answered: lookup.answered)
        }
    }

    /// `editBase` for the follow list (kind 3) only: an own relay that was
    /// dialled and failed to connect (`lookup.unreachable`) drops out of the
    /// count (`followMajority`). One not dialled or that timed out still
    /// counts. Every other list keeps `ownMajority`. "None" (a first follow
    /// with no list found) still needs every own relay answering, dead ones
    /// included (Tron, web #2611). A relay list of exactly one relay counts
    /// purplepag.es as its second (`followCounted`), so both must answer.
    static func followEditBase<Event>(_ lookup: ReplaceableLookup<Event>, held: Event?, own: [String],
                                      now: Int64 = Int64(Date().timeIntervalSince1970),
                                      createdAt: (Event) -> Int64) -> EditBase<Event> {
        let unreachable = Set(lookup.unreachable.subtracting(lookup.answeredBy).map(relayKey))
        return editBase(lookup, held: held, own: followCounted(own: own), now: now, createdAt: createdAt) { mine, ownAnswered in
            followMajority(ownAnswered: ownAnswered, ownReached: mine.subtracting(unreachable).count)
        }
    }

    /// purplepag.es: the second answer a one-relay list needs (`followCounted`).
    /// `editLookupAsk` already asks it (RelayDraft.indexers).
    static let followIndexer = "wss://purplepag.es"

    /// The relays that count for the follow list: `own`, plus `followIndexer`
    /// when `own` names exactly one relay, so that relay and purplepag.es must
    /// both answer (Logen 2026-11-27, b219c87b; Android #2616, web the same).
    /// Two or more own relays: own only, and no indexer ever counts.
    static func followCounted(own: [String]) -> [String] {
        var seen = Set<String>()
        let mine = own.filter { seen.insert(relayKey($0)).inserted }
        return mine.count == 1 && !seen.contains(relayKey(followIndexer)) ? mine + [followIndexer] : mine
    }

    /// `base` for a follow or unfollow made on `before` (the list on screen)
    /// that gives `after`. "No list anywhere" is not believed while the
    /// screen still shows people this tap doesn't touch and no signed copy
    /// is held here: a restored snapshot, or a list kept only on relays
    /// dropped from the 10002. Building on `[]` then would sign a 1-person
    /// list over 300 (Tron on #2613; web guardRefusal appCount > 0, Android
    /// noneUnproven). Unfollowing the last person, or a first follow on an
    /// empty screen, still builds on none.
    static func followBase<Event>(_ base: EditBase<Event>, held: Event?, before: [[String]], after: [[String]]) -> EditBase<Event> {
        guard case .none = base, held == nil else { return base }
        func people(_ tags: [[String]]) -> Set<String> {
            Set(tags.compactMap { $0.count >= 2 && $0[0] == "p" ? $0[1].lowercased() : nil })
        }
        return people(before).isDisjoint(with: people(after)) ? base : .unknown
    }

    private static func editBase<Event>(_ lookup: ReplaceableLookup<Event>, held: Event?, own: [String], now: Int64,
                                        createdAt: (Event) -> Int64,
                                        enough: (_ mine: Set<String>, _ ownAnswered: Int) -> Bool) -> EditBase<Event> {
        let mine = Set(own.map(relayKey))
        guard !mine.isEmpty else { return .noRelayList }
        guard lookup.answered > 0 else { return .unknown }
        let ownAnswered = mine.intersection(Set(lookup.answeredBy.map(relayKey))).count
        let copies = [lookup.event, held].compactMap { $0 }
        let usable = copies.filter { createdAt($0) < now + maxSkew }
        if let newest = usable.max(by: { createdAt($0) < createdAt($1) }) {
            return enough(mine, ownAnswered) ? .list(newest) : .unknown
        }
        let ahead = lookup.ahead || usable.count < copies.count
        return !ahead && knowsNone(asked: lookup.asked, answered: lookup.answered) && ownAnswered == mine.count ? .none : .unknown
    }

    /// `editBase` for a key setup made on this device that has signed no
    /// follow list yet (FreshAccountKeys): it can't have one anywhere, so a
    /// silent relay or a missing kind 10002 doesn't make its list unknown.
    /// It builds on the newest copy seen here, or on none. As Android's
    /// ContactManager.saveBase with freshKey. A copy dated `maxSkew` or more
    /// ahead means the key has a list somewhere, so then `base` stands.
    static func freshKeyBase<Event>(_ base: EditBase<Event>, fresh: Bool, lookup: ReplaceableLookup<Event>, held: Event?,
                                    now: Int64 = Int64(Date().timeIntervalSince1970),
                                    createdAt: (Event) -> Int64) -> EditBase<Event> {
        guard fresh else { return base }
        switch base {
        case .list, .none: return base
        case .unknown, .noRelayList: break
        }
        let copies = [lookup.event, held].compactMap { $0 }
        let usable = copies.filter { createdAt($0) < now + maxSkew }
        guard !lookup.ahead, usable.count == copies.count else { return base }
        return usable.max(by: { createdAt($0) < createdAt($1) }).map { .list($0) } ?? .none
    }

    /// Whether enough relays answered to edit a list on the newest copy they
    /// sent: more than half of the account's `own` relays, and at least two
    /// relays in all (`answered` counts every relay asked, as knowsNone). A
    /// single answer, or none, never is (Logen 2026-11-02 13:21Z). An account
    /// with one own relay edits once it and one more relay (an indexer)
    /// answered. Same rule as Android ListMerge.ownMajority and web
    /// follows.js ownMajority.
    static func ownMajority(ownAnswered: Int, own: Int, answered: Int) -> Bool {
        own > 0 && ownAnswered * 2 > own && answered >= 2
    }

    /// Whether enough relays answered to edit the follow list (Logen
    /// 2026-11-27): own relays whose dial failed to connect drop out, at least two
    /// own relays answered (an indexer such as purplepag.es doesn't count),
    /// and more than half of the other `ownReached` ones answered (a relay
    /// that was slow, timed out connecting, or was not dialled at all counts
    /// as not answering). A relay list of one relay counts purplepag.es as
    /// its second own relay (`followCounted`). Same rule as web
    /// followListKnown and Android FollowListKnown:
    /// - 7 own, 3 never connect, 4 answer: yes.
    /// - 7 own, 4 never connect, 3 answer: yes (was no under ownMajority).
    /// - 3 connect, 2 answer, 1 slow: yes. 5 connect, 2 answer, 3 slow: no.
    /// - 1 of 2+ own relays answered (with or without an indexer), or none: no.
    /// - A one-relay list: yes once it and purplepag.es both answered.
    static func followMajority(ownAnswered: Int, ownReached: Int) -> Bool {
        ownAnswered >= 2 && ownAnswered * 2 > ownReached
    }

    /// "You have no list" is known only when at least two relays answered and
    /// every relay asked did. One relay saying none is not that: it may just
    /// not hold the list (Logen 2026-10-31).
    static func knowsNone(asked: Int, answered: Int) -> Bool {
        answered >= 2 && answered >= asked
    }

    /// A follow or unfollow made on `before` (the list the tap saw) applied to
    /// `base`, the newest list fetched right before signing. Every tag of
    /// `base` stays as it is (petnames, relay hints, tags other than `p`), the
    /// `p` entries the tap removed come out, and the ones it added go at the
    /// end. Signing the copy loaded at launch instead put back people
    /// unfollowed and dropped people followed in another app since.
    static func contactEdit(base: [[String]], before: [[String]], after: [[String]]) -> [[String]] {
        func person(_ tag: [String]) -> String? {
            tag.count >= 2 && tag[0] == "p" ? tag[1].lowercased() : nil
        }
        let had = Set(before.compactMap(person))
        let removed = had.subtracting(after.compactMap(person))
        var out = base.filter { tag in person(tag).map { !removed.contains($0) } ?? true }
        var present = Set(out.compactMap(person))
        for tag in after {
            if let key = person(tag), !had.contains(key), present.insert(key).inserted { out.append(tag) }
        }
        return out
    }

    static func relayKey(_ url: String) -> String {
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
        static var shared: Bases { Bases(file: sharedFile) }

        /// Where `shared` keeps its file; a factory reset deletes it (ListPublishReset).
        static var sharedFile: URL {
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("Haven", isDirectory: true)
                .appendingPathComponent(basesFileName)
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
