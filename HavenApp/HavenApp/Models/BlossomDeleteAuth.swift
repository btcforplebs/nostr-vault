import Foundation

/// The tags of a Blossom delete token (kind 24242, BUD-02 / BUD-11).
///
/// One token per server, naming that server: the same token goes to public
/// mirrors, and one that named no server could be replayed by a mirror
/// against the home vault, which now refuses a token naming another server.
/// It lasts five minutes, long enough for a slow server, too short to keep.
enum BlossomDeleteAuth {
    static let lifetime: TimeInterval = 5 * 60

    static func tags(sha256: String, deleteURL: URL, now: Date = Date()) -> [[String]] {
        var tags = [
            ["t", "delete"],
            ["x", sha256],
            ["u", deleteURL.absoluteString],
        ]
        if let host = deleteURL.host?.lowercased(), !host.isEmpty {
            tags.append(["server", host])
        }
        tags.append(["expiration", String(Int64(now.timeIntervalSince1970 + lifetime))])
        return tags
    }
}
