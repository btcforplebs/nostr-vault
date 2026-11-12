import Foundation

/// A draft (kind 31234) as NIP-37 stores it: the note being drafted (its
/// kind, text, tags and time) as JSON, NIP-44 encrypted to the author's own
/// key, with only `d` (the draft id) and `k` (the drafted kind) left outside.
/// The vault's /private relay used to get the text and every tag in plain
/// text; those drafts still open, marked so they are saved again encrypted.
/// Android: DraftEvents.seal / open (data/model/Draft.kt).
enum DraftEnvelope {
    /// A fetched draft, opened. `createdAt` is the time it was saved, from
    /// inside the envelope (nil for an old plaintext draft: use the event's).
    struct Opened: Equatable {
        let content: String
        let tags: [[String]]
        let createdAt: Date?
        let wasPlaintext: Bool
    }

    private static let outside: Set<String> = ["d", "k"]

    /// -> the content and tags to sign. `tags` is the draft's full tag list
    /// (d, k, NIP-10 e, p, q); everything but d and k goes inside.
    /// Throws when `encrypt` does: a draft is never sent unencrypted.
    static func seal(content: String, tags: [[String]], updatedAt: Date,
                     encrypt: (String) async throws -> String) async throws -> (content: String, tags: [[String]]) {
        let outer = tags.filter { $0.count >= 2 && outside.contains($0[0]) }
        let inner = tags.filter { !($0.first.map(outside.contains) ?? false) }
        let kind = outer.first(where: { $0[0] == "k" }).flatMap { Int($0[1]) } ?? 1
        let event: [String: Any] = [
            "kind": kind,
            "content": content,
            "tags": inner,
            "created_at": Int(updatedAt.timeIntervalSince1970),
        ]
        let json = try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])
        let ciphertext = try await encrypt(String(decoding: json, as: UTF8.self))
        return (ciphertext, outer)
    }

    /// A fetched draft's text and tags (the old shape: outer d/k, then the
    /// inner tags). Plain text that isn't a NIP-44 payload is an old draft and
    /// opens as it is. Nil when it is encrypted but can't be opened: its
    /// ciphertext is never shown as the draft's text.
    static func open(content: String, tags: [[String]],
                     decrypt: (String) async throws -> String) async -> Opened? {
        guard looksEncrypted(content) else {
            return Opened(content: content, tags: tags, createdAt: nil, wasPlaintext: true)
        }
        guard let plain = try? await decrypt(content),
              let obj = (try? JSONSerialization.jsonObject(with: Data(plain.utf8))) as? [String: Any],
              let text = obj["content"] as? String else { return nil }
        let inner = (obj["tags"] as? [[Any]])?.compactMap { tag -> [String]? in
            let strings = tag.compactMap { $0 as? String }
            return strings.count == tag.count && !strings.isEmpty ? strings : nil
        } ?? []
        let outer = tags.filter { $0.count >= 2 && outside.contains($0[0]) }
        let created = (obj["created_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        return Opened(content: text, tags: outer + inner.filter { !outside.contains($0[0]) },
                      createdAt: created, wasPlaintext: false)
    }

    /// A NIP-44 v2 payload: base64 of at least 99 bytes (version, nonce,
    /// padded ciphertext, MAC) whose first byte is 2. Text people type is
    /// almost never that.
    static func looksEncrypted(_ content: String) -> Bool {
        guard content.count >= 132, content.count <= 87_472,
              let data = Data(base64Encoded: content), data.count >= 99 else { return false }
        return data.first == 2
    }
}
