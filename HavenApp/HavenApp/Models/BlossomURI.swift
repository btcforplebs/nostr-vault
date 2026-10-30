import Foundation
import CryptoKit

/// A BUD-10 Blossom link: `blossom:<sha256>.<ext>?xs=<server>&as=<pubkey>&sz=<bytes>`.
///
/// The link names a file by its hash, not by where it lives. `xs` hints at
/// servers that hold it (any number, bare domains or full URLs), `as` is the
/// author whose kind 10063 server list may hold it, and `sz` its size. A
/// reader tries the servers in turn, GETs `/<sha256>.<ext>` and keeps the
/// bytes only when they hash to the link's sha256, since any server may answer.
/// Web: `web-vault/src/net/blossom-uri.js`. Android: none yet.
struct BlossomURI: Equatable {
    var sha256: String
    /// Lowercase, no dot: "jpg", "mp4".
    var ext: String
    /// The `xs` servers, as https base URLs, in the link's order.
    var servers: [URL]
    /// The `as` pubkey as hex, when it is one.
    var author: String?
    /// The `sz` byte count, when given.
    var size: Int?

    static let scheme = "blossom"

    /// `blossom:` links in a note's text. The extension must be a media one
    /// for the link to be drawn: a `.pdf` stays text.
    static let regex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"blossom:[0-9a-f]{64}\.[a-z0-9]{1,8}(?:\?[^\s]*)?"#,
        options: .caseInsensitive
    )

    static func isURI(_ url: URL) -> Bool {
        url.scheme?.lowercased() == scheme
    }

    /// nil for anything that is not a well-formed `blossom:` link.
    init?(_ url: URL) {
        guard Self.isURI(url) else { return nil }
        let parts = url.absoluteString.dropFirst(Self.scheme.count + 1)
            .split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let name = parts[0].lowercased()
        guard name.range(of: #"^[0-9a-f]{64}\.[a-z0-9]{1,8}$"#, options: .regularExpression) != nil else { return nil }
        sha256 = String(name.prefix(64))
        ext = String(name.dropFirst(65))
        servers = []
        let items = parts.count > 1 ? (URLComponents(string: "?" + parts[1])?.queryItems ?? []) : []
        var seen = Set<String>()
        for item in items {
            switch item.name {
            case "xs":
                if let server = Self.serverURL(item.value), seen.insert(server.absoluteString).inserted {
                    servers.append(server)
                }
            case "as":
                if author == nil { author = Self.hexPubkey(item.value) }
            case "sz":
                if size == nil, let value = item.value, let n = Int(value), n >= 0 { size = n }
            default:
                break
            }
        }
    }

    /// Where to ask, in order: the link's own servers, then the author's
    /// list, then ours. Each is `<server>/<sha256>.<ext>`, once each, https only.
    func candidates(authorServers: [String], fallbackServers: [String]) -> [URL] {
        var seen = Set<String>()
        let bases = servers + (authorServers + fallbackServers).compactMap(Self.serverURL)
        return bases.compactMap { base -> URL? in
            let blob = base.appendingPathComponent("\(sha256).\(ext)")
            return seen.insert(blob.absoluteString.lowercased()).inserted ? blob : nil
        }
    }

    /// Whether `data` is the file this link names.
    func matches(_ data: Data) -> Bool {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == sha256
    }

    /// Whether the file at `file` is the one this link names, read in 1 MB
    /// pieces so a video never sits in memory.
    func matches(file: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let chunk = handle.readData(ofLength: 1 << 20)
            guard !chunk.isEmpty else { return false }
            hasher.update(data: chunk)
            return true
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined() == sha256
    }

    /// A server as an https base URL with no trailing slash: a bare domain
    /// gets `https://`; http, other schemes and anything with a query are dropped.
    static func serverURL(_ value: String?) -> URL? {
        guard var text = value?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        guard let components = URLComponents(string: text),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.query == nil, components.fragment == nil
        else { return nil }
        return components.url
    }

    /// `as` as 64-char lowercase hex: hex as given, or an npub decoded.
    static func hexPubkey(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespaces).lowercased() else { return nil }
        if value.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil { return value }
        guard value.hasPrefix("npub1"), let decoded = Bech32.decode(value), decoded.hrp == "npub",
              decoded.data.count == 32 else { return nil }
        return decoded.data.map { String(format: "%02x", $0) }.joined()
    }
}
