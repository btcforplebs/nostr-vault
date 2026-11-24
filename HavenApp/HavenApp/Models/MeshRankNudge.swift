import Foundation

/// The trust rank nudge (haven-go copyv2_nudge.go). A Mac that has just
/// ranked logs `RANK_BUILT` and tells the own devices that copy from it;
/// their engine logs `RANK_READY peer=<npub>` and the app catches up with
/// that device, which brings the new result down. A device that misses the
/// nudge gets it from its hourly check. Mesh keys only, never the account
/// key. Android's twin is `MeshRankNudge.kt`.
enum MeshRankNudge {
    static let builtMarker = "RANK_BUILT"
    static let readyMarker = "RANK_READY peer="
    /// While the app is open, every device it copies from is checked this often.
    static let recheckEvery: TimeInterval = 60 * 60
    /// The Mac nudges at most this often: a pass ranks each account in turn.
    static let nudgeGap = 60

    /// A `RANK_BUILT` line (a timestamp may lead it).
    static func isBuilt(_ line: String) -> Bool {
        guard RelayLogBytes.contains(line, builtMarker), let r = line.range(of: builtMarker) else { return false }
        return r.lowerBound == line.startIndex || line[line.index(before: r.lowerBound)].isWhitespace
    }

    /// The npub a `RANK_READY` line names, or nil for any other line.
    static func readyPeer(_ line: String) -> String? {
        guard RelayLogBytes.contains(line, readyMarker), let r = line.range(of: readyMarker) else { return nil }
        if r.lowerBound != line.startIndex, !line[line.index(before: r.lowerBound)].isWhitespace { return nil }
        let peer = String(line[r.upperBound...].prefix { !$0.isWhitespace })
        guard peer.hasPrefix("npub1"), peer.count == 63,
              peer.allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber) }) else { return nil }
        return peer
    }

    /// Where the nudge goes: the device's own-device base, ingress path kept.
    static func nudgeURL(base: URL) -> URL? {
        URL(string: base.absoluteString.trimmingSuffix("/") + "/copy/v2/nudge")
    }

    /// The kind 27235 tags: `u` without the ingress path (the device checks
    /// the path), POST, and `p` naming the device so it can't be replayed
    /// against another one.
    static func tags(base: URL, receiver: String) -> [[String]]? {
        guard let scheme = base.scheme, let host = base.host, !host.isEmpty, !receiver.isEmpty else { return nil }
        let port = base.port.map { ":\($0)" } ?? ""
        return [["u", "\(scheme)://\(host)\(port)/copy/v2/nudge"], ["method", "POST"], ["p", receiver]]
    }
}

private extension String {
    func trimmingSuffix(_ s: String) -> String {
        var out = self
        while out.hasSuffix(s) { out.removeLast(s.count) }
        return out
    }
}
