import Foundation

/// Who is live right now, for the red ring on their profile picture.
///
/// Keeps the newest NIP-53 kind 30311 event per stream address (a stream that
/// has since ended replaces its own live announcement), and answers "is this
/// pubkey hosting a stream that is on air and playable?" A pubkey counts only
/// as the host — the `p` tag marked Host, else the author — never as a guest,
/// the same rule the Live tab uses.
///
/// Pure Foundation so the tests can build it; `LiveStatusService` does the
/// fetching and turns the answer into a `LiveStream`.
struct LiveStatusBook {
    struct Event: Equatable {
        let id: String
        let pubkey: String
        let createdAt: Int64
        let tags: [[String]]

        var host: String { LiveChat.hostPubkey(authorPubkey: pubkey, tags: tags) }

        var address: String? {
            guard let d = tags.first(where: { $0.count >= 2 && $0[0] == "d" })?[1]
                    .trimmingCharacters(in: .whitespacesAndNewlines), !d.isEmpty else { return nil }
            return LiveChat.address(authorPubkey: pubkey, identifier: d)
        }

        /// The Live tab's test: status live (or missing), not past `ends`,
        /// republished within the hour, and an HLS URL the player can open.
        func isLive(at now: Int64) -> Bool {
            func value(_ name: String) -> String? {
                guard let raw = tags.first(where: { $0.count >= 2 && $0[0] == name })?[1] else { return nil }
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            guard LiveChat.playableStreamURL(tags: tags) != nil else { return false }
            return LiveChat.isOnAir(status: value("status"), createdAt: createdAt,
                                    ends: value("ends").flatMap { Int64($0) }, now: now)
        }
    }

    /// How long a "not live" answer for a pubkey stands before it is asked
    /// again. Streams start at any time, so this is short.
    static let recheckAfter: TimeInterval = 3 * 60

    private var byAddress: [String: Event] = [:]
    private var askedAt: [String: Date] = [:]

    /// Takes an event in. Returns true when it changed the book.
    @discardableResult
    mutating func ingest(_ event: Event) -> Bool {
        guard let address = event.address else { return false }
        if let existing = byAddress[address], existing.createdAt >= event.createdAt { return false }
        byAddress[address] = event
        return true
    }

    /// The newest live stream `pubkey` hosts, if any.
    func liveEvent(hostedBy pubkey: String, at now: Int64) -> Event? {
        byAddress.values
            .filter { $0.host == pubkey && $0.isLive(at: now) }
            .max { $0.createdAt < $1.createdAt }
    }

    /// Every pubkey hosting a live stream at `now`.
    func liveHosts(at now: Int64) -> Set<String> {
        Set(byAddress.values.filter { $0.isLive(at: now) }.map(\.host))
    }

    /// Of `pubkeys`, the ones not asked about within `recheckAfter`, marked as
    /// asked at `now`.
    mutating func takeDue(_ pubkeys: Set<String>, now: Date) -> [String] {
        let due = pubkeys.filter { key in
            guard let at = askedAt[key] else { return true }
            return now.timeIntervalSince(at) >= Self.recheckAfter
        }.sorted()
        for key in due { askedAt[key] = now }
        return due
    }

    /// Another account has a different block list and follows; start over.
    mutating func reset() {
        byAddress.removeAll()
        askedAt.removeAll()
    }
}
