import Foundation

/// The last-copy check behind "Delete from this device" (A3). The local file
/// may go only when, asked just now, at least one OTHER place proves it holds
/// the same bytes. Logen (2026-11-27): the owner's Mac or home box counts as
/// a safe copy, like any media server; this device's own relay never does.
///
/// Fail closed: a server that did not answer, answered oddly, or whose length
/// does not match this file counts as not holding it. There is no cached
/// answer here: the caller asks every server again for this one decision.
/// Twin: Android `service/blossom/DeleteHereGate.kt`.
enum DeleteHereGate {
    /// One server's answer to `GET <server>/<sha256>` with `Range: bytes=0-0`.
    struct Answer: Equatable {
        var status: Int
        var contentType: String?
        var contentLength: String?
        var contentRange: String?
        /// Where redirects ended.
        var finalURL: URL?
        /// `cf-cache-status` (or `x-cache`): a HIT is a CDN's copy, not the server's.
        var cacheStatus: String? = nil
        /// `Age`: seconds a cache has held this answer.
        var age: String? = nil
    }

    enum Decision: Equatable {
        /// Safe: these servers proved a copy.
        case allowed(holders: [String])
        /// Not safe; say why, plainly.
        case refused(String)
    }

    /// Whether one answer proves the server holds this file, byte length and
    /// all. A full 200 must give the whole length; a 206 must give the total
    /// in `Content-Range: bytes 0-0/<total>`. Anything else (a placeholder
    /// page, a redirect away from the hash, an empty or wrong length, no
    /// length at all) proves nothing. Nor does an answer a cache gave (a
    /// HIT, or an `Age` above 0): a "Cache Everything" edge can keep a blob
    /// for days after the origin dropped it (Tron, PR 2652 S1).
    static func proves(_ a: Answer, sha256: String, localSize: Int64) -> Bool {
        guard localSize > 0 else { return false }
        if let cache = a.cacheStatus?.lowercased(), cache.contains("hit") { return false }
        if let age = a.age?.trimmingCharacters(in: .whitespaces), !age.isEmpty, age != "0" { return false }
        if let type = a.contentType?.lowercased(), type.hasPrefix("text/html") { return false }
        // Where it ended must be https and still this hash. The probe asks
        // https, but URLSession follows a redirect to http (the Mac allows
        // arbitrary loads, iOS local networking), and an http answer could
        // come from anything on the way, this device included (Tron, delete-here
        // close-out). No final URL: nothing to check, so no proof.
        guard let url = a.finalURL, url.scheme?.lowercased() == "https",
              url.absoluteString.lowercased().contains(sha256.lowercased()) else { return false }
        switch a.status {
        case 200:
            return a.contentLength.flatMap { Int64($0.trimmingCharacters(in: .whitespaces)) } == localSize
        case 206:
            guard let range = a.contentRange?.trimmingCharacters(in: .whitespaces),
                  let slash = range.lastIndex(of: "/") else { return false }
            return Int64(range[range.index(after: slash)...]) == localSize
        default:
            return false
        }
    }

    /// The probe for `sha256` on `server`: `GET <server>/<sha256>?nv=<nonce>`,
    /// so no cache can answer it from an earlier request. nil for a bad URL.
    static func probeURL(server: String, sha256: String, nonce: String) -> URL? {
        guard var base = URL(string: server), base.host != nil else { return nil }
        if base.scheme == "http", var c = URLComponents(url: base, resolvingAgainstBaseURL: false) {
            c.scheme = "https"
            if let u = c.url { base = u }
        }
        guard var c = URLComponents(url: base.appendingPathComponent(sha256), resolvingAgainstBaseURL: false) else { return nil }
        c.queryItems = [URLQueryItem(name: "nv", value: nonce)]
        return c.url
    }

    /// The host of this Mac's own public relay address (`sanitizedRelayURL`,
    /// `host[:port][/path]`, the tunnel domain), nil when there is none.
    static func relayHost(_ sanitizedRelayURL: String) -> String? {
        let trimmed = sanitizedRelayURL.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return URL(string: "https://" + trimmed)?.host?.lowercased()
    }

    /// `servers` minus this device's own relay (loopback, or `ownHosts`).
    static func candidates(_ servers: [String], ownHosts: Set<String>) -> [String] {
        var seen = Set<String>()
        return servers.filter { s in
            guard let host = URL(string: s)?.host?.lowercased(), !host.isEmpty else { return false }
            if ["127.0.0.1", "localhost", "0.0.0.0", "::1"].contains(host) || ownHosts.contains(host) { return false }
            return seen.insert(s).inserted
        }
    }

    /// The decision from each candidate's fresh answer (nil = could not ask).
    static func decide(answers: [String: Answer?], sha256: String, localSize: Int64) -> Decision {
        guard localSize > 0 else { return .refused("This file isn't on this device.") }
        guard !answers.isEmpty else {
            return .refused("No media server or other device to keep it. Copy it to a server first.")
        }
        let holders = answers.compactMap { server, answer in
            answer.map { proves($0, sha256: sha256, localSize: localSize) } == true ? server : nil
        }.sorted()
        if !holders.isEmpty { return .allowed(holders: holders) }
        let unreachable = answers.values.filter { $0 == nil }.count
        if unreachable == answers.count {
            return .refused("None of your servers answered just now, so this may be the only copy. Try again later.")
        }
        return .refused("No server has a full copy of this file, so it would be lost. Copy it to a server first.")
    }
}
