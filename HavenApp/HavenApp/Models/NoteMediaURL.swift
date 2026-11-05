import Foundation

/// Media links found in note text, made ready to fetch. A link with no host
/// (`https:///abc.jpg`) can never load, so it is dropped: Import media used to
/// queue it and spin. Only links to this device (localhost, 127.0.0.1) go from
/// https to http, because the on-device vault serves plain http. Every other
/// https link stays https: an empty relay URL (the iOS default) used to send
/// all of them to http, which App Transport Security blocks.
enum NoteMediaURL {
    static func normalized(_ url: URL) -> URL? {
        guard let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        guard url.scheme?.lowercased() == "https", host == "localhost" || host == "127.0.0.1" else { return url }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = "http"
        return components?.url ?? url
    }
}
