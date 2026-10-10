import Foundation

/// The URL to download a profile picture from: a small copy made by a
/// resizing service instead of the original.
///
/// Profile pictures are often far larger than an avatar needs. Across 238 real
/// follows the originals weighed 187 MB (one GIF was 25 MB); the same pictures
/// at the 256 px the avatar cache shrinks them to weigh 3.8 MB. Primal and
/// nostr.build, which host most of them, have no resize option that works for
/// GIFs, and nostr.build answers some resize paths with a placeholder animal
/// picture, so a resizing service is the only way to get small copies.
///
/// The service sees which pictures are loaded. If it can't fetch or resize a
/// picture, `default` redirects to the original, so a picture that loaded
/// before still loads. Callers keep caching under the original URL.
/// https://wsrv.nl/docs/
enum AvatarThumbnail {
    static let host = "wsrv.nl"

    /// Matches `AvatarImageCache`'s downsample size, so nothing gets blurrier.
    static let pixelSize = 256

    static func url(for original: URL) -> URL {
        guard let scheme = original.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let originalHost = original.host?.lowercased(), isPublic(host: originalHost) else {
            return original
        }
        let encoded = encode(original.absoluteString)
        let query = "url=\(encoded)&w=\(pixelSize)&h=\(pixelSize)&fit=inside&we&output=webp&default=\(encoded)"
        return URL(string: "https://\(host)/?\(query)") ?? original
    }

    /// The service can't reach the device relay, the LAN or Tor, and
    /// shouldn't learn their addresses.
    private static func isPublic(host: String) -> Bool {
        if host == Self.host || host == "localhost" || host.hasSuffix(".local") || host.hasSuffix(".onion") {
            return false
        }
        if host.contains(":") { return false } // IPv6 literal
        let octets = host.split(separator: ".").compactMap { Int($0) }
        if octets.count == 4 {
            switch (octets[0], octets[1]) {
            case (10, _), (127, _), (169, 254), (192, 168), (0, _): return false
            case (172, 16...31), (100, 64...127): return false
            default: return true
            }
        }
        return true
    }

    /// Percent-encodes everything but unreserved characters, so the original's
    /// own `?`, `&` and `=` stay inside the `url` value.
    private static func encode(_ string: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }
}
