import Foundation

/// The link Copy link hands out for a vault file: a loopback address (only
/// this device can open it) moved onto the Mac relay's address, or the first
/// Blossom mirror when no Mac relay is set. The file's path and query stay.
enum MediaShareLink {
    static func isLoopback(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        return host == "127.0.0.1" || host == "localhost" || host == "0.0.0.0"
    }

    static func external(for url: URL, macRelayHTTPS: String, mirrors: [String]) -> URL {
        guard isLoopback(url) else { return url }
        for base in [macRelayHTTPS] + mirrors.prefix(1) where !base.isEmpty {
            if let moved = move(url, onto: base) { return moved }
        }
        return url
    }

    private static func move(_ url: URL, onto base: String) -> URL? {
        guard var components = URLComponents(string: base) else { return nil }
        let path = url.path.isEmpty ? "/" : url.path
        components.path = (components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path) + path
        components.query = url.query
        return components.url
    }
}
