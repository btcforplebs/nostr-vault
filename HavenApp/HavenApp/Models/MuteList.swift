import Foundation

/// What a NIP-51 kind 10000 mute list hides beyond the public `p` tags, which
/// stay in `blockedNpubsPerAccount` (this device publishes those). Other
/// clients also write muted words (`word`), hashtags (`t`) and threads (`e`),
/// and they can put any entry in the private part: the content, a JSON array
/// of tags encrypted to the user's own key (NIP-44, or NIP-04 from older
/// clients, told apart by its "?iv=").
///
/// `privatePubkeys` are kept apart from the public blocks so that a block or
/// unblock made here, which republishes the `p` tags, never makes a private
/// block public. The same rules as the web app (web-vault/src/net/blocks.js).
struct MuteList: Equatable, Codable {
    var privatePubkeys: Set<String> = []
    /// Lowercased; a note whose text contains one is hidden.
    var words: [String] = []
    /// Lowercased, without the "#".
    var hashtags: Set<String> = []
    /// Event ids: the note itself, and every reply under it.
    var threads: Set<String> = []
    /// Why the private part was not read, or "" when it was (or there is none).
    var privateNote: String = ""

    static let empty = MuteList()

    var hidesNotes: Bool { !words.isEmpty || !hashtags.isEmpty || !threads.isEmpty }

    /// Words, hashtags and threads from public and private tags; people from
    /// the private tags only.
    init(publicTags: [[String]] = [], privateTags: [[String]] = [], privateNote: String = "") {
        let all = publicTags + privateTags
        func values(_ name: String) -> [String] {
            var seen = Set<String>(), out: [String] = []
            for tag in all where tag.count >= 2 && tag[0] == name {
                let value = tag[1].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if !value.isEmpty, seen.insert(value).inserted { out.append(value) }
            }
            return out
        }
        words = values("word")
        hashtags = Set(values("t").map { $0.hasPrefix("#") ? String($0.dropFirst()) : $0 })
        threads = Set(values("e").filter(Self.isHex64))
        privatePubkeys = Set(privateTags.compactMap { tag -> String? in
            guard tag.count >= 2, tag[0] == "p" else { return nil }
            let key = tag[1].lowercased()
            return Self.isHex64(key) ? key : nil
        })
        self.privateNote = privateNote
    }

    /// Whether a note is hidden by a muted word, hashtag or thread. People are
    /// checked by the block list the screens already use.
    func hides(id: String, content: String, tags: [[String]], parentId: String? = nil) -> Bool {
        guard hidesNotes else { return false }
        if !threads.isEmpty {
            if threads.contains(id.lowercased()) { return true }
            if let parentId, threads.contains(parentId.lowercased()) { return true }
            // NIP-10: the root (marked, or the first positional e tag) and the
            // reply target. Mention-marked e tags are quotes, not the thread.
            let refs = tags.filter { $0.count >= 2 && $0[0] == "e" && ($0.count < 4 || $0[3] != "mention") }
            if refs.contains(where: { threads.contains($0[1].lowercased()) }) { return true }
        }
        if !hashtags.isEmpty, tags.contains(where: { tag in
            guard tag.count >= 2, tag[0] == "t" else { return false }
            let value = tag[1].lowercased()
            return hashtags.contains(value.hasPrefix("#") ? String(value.dropFirst()) : value)
        }) { return true }
        if !words.isEmpty {
            let text = content.lowercased()
            if !text.isEmpty, words.contains(where: { text.contains($0) }) { return true }
        }
        return false
    }

    // MARK: - Reading a kind 10000

    static func isNip04(_ ciphertext: String) -> Bool { ciphertext.contains("?iv=") }

    static func isHex64(_ s: String) -> Bool {
        s.count == 64 && s.allSatisfy { $0.isHexDigit }
    }

    enum PrivateError: LocalizedError {
        case notAList
        var errorDescription: String? { "the private part isn't a list" }
    }

    /// The decrypted private part: a JSON array of string arrays.
    static func privateTags(fromJSON plaintext: String) throws -> [[String]] {
        guard let data = plaintext.data(using: .utf8),
              let array = try JSONSerialization.jsonObject(with: data) as? [Any] else { throw PrivateError.notAList }
        return array.compactMap { ($0 as? [Any])?.compactMap { $0 as? String } }
    }

    /// The whole list from an event's tags and content. `decrypt44` and
    /// `decrypt04` open ciphertext encrypted to the user's own key; when the
    /// one needed throws, only the public part applies and `privateNote` says why.
    static func read(tags: [[String]], content: String,
                     decrypt44: (String) async throws -> String,
                     decrypt04: (String) async throws -> String) async -> MuteList {
        let ciphertext = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ciphertext.isEmpty else { return MuteList(publicTags: tags) }
        do {
            let plaintext = isNip04(ciphertext) ? try await decrypt04(ciphertext) : try await decrypt44(ciphertext)
            return MuteList(publicTags: tags, privateTags: try privateTags(fromJSON: plaintext))
        } catch {
            return MuteList(publicTags: tags, privateNote: error.localizedDescription)
        }
    }
}
