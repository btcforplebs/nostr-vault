import Foundation

/// Vertex's Verify Reputation service (vertexlab.io), the follower count
/// npub.world shows. The app sends a signed kind 5312 request naming the
/// profile; Vertex answers with a kind 6312 whose first entry is that
/// profile, or a kind 7000 error (e.g. a key with no credits).
/// https://vertexlab.io/docs/endpoints/verify-reputation/
enum VertexReputation {
    static let relayURL = "wss://relay.vertexlab.io"
    /// The key Vertex signs its answers with. Anything else on its relay
    /// tagging our request is ignored.
    static let servicePubkey = "b0565a0d950477811f35ff76e5981ede67a90469a97feec13dc17f36290debfe"

    static let requestKind = 5312
    static let resultKind = 6312
    static let feedbackKind = 7000

    static func requestTags(target: String) -> [[String]] {
        [["param", "target", target]]
    }

    enum Reply: Equatable {
        case followers(Int)
        /// Vertex refused; use the relay count instead.
        case failed(String)
    }

    /// Reads one event from Vertex's relay. Nil means it isn't the answer to
    /// `requestId` (wrong author, wrong request, or a non-final status), so
    /// keep waiting.
    static func reply(kind: Int, pubkey: String, tags: [[String]], content: String,
                      requestId: String, target: String) -> Reply? {
        guard pubkey == servicePubkey,
              tags.contains(where: { $0.count >= 2 && $0[0] == "e" && $0[1] == requestId }) else { return nil }
        switch kind {
        case resultKind:
            guard let data = content.data(using: .utf8),
                  let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  let first = entries.first,
                  first["pubkey"] as? String == target,
                  let followers = first["followers"] as? Int, followers >= 0 else {
                return .failed("unreadable result")
            }
            return .followers(followers)
        case feedbackKind:
            guard let status = tags.first(where: { $0.count >= 2 && $0[0] == "status" }),
                  status[1] == "error" else { return nil }
            return .failed(status.count >= 3 ? status[2] : "error")
        default:
            return nil
        }
    }

    /// Answers kept for a while so reopening a profile doesn't spend another
    /// request, and a pause after a refusal so a key without credits doesn't
    /// send every profile it opens to Vertex for nothing.
    struct Cache {
        static let answerLifetime: TimeInterval = 30 * 60
        static let refusalPause: TimeInterval = 30 * 60

        private var answers: [String: (count: Int, at: Date)] = [:]
        private var refusedAt: Date?

        func followers(for target: String, now: Date) -> Int? {
            guard let hit = answers[target], now.timeIntervalSince(hit.at) < Self.answerLifetime else { return nil }
            return hit.count
        }

        func shouldAsk(now: Date) -> Bool {
            guard let refusedAt else { return true }
            return now.timeIntervalSince(refusedAt) >= Self.refusalPause
        }

        mutating func record(_ reply: Reply, for target: String, now: Date) {
            switch reply {
            case .followers(let count):
                answers[target] = (count, now)
                refusedAt = nil
            case .failed:
                refusedAt = now
            }
        }
    }
}
