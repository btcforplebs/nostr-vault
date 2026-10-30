import Foundation

// MARK: - Supported Media Formats

/// Single source of truth for all media format metadata in the app.
/// Every extension list, MIME mapping, and media-URL regex should derive
/// from these tables rather than maintaining independent copies.
enum SupportedMediaFormats {

    // MARK: Media Category

    enum Category: String, CaseIterable {
        case image
        case gif       // Separated from image for rendering decisions
        case video
        case audio
    }

    // MARK: Format Definitions

    /// Each entry maps one file extension to its canonical MIME type and category.
    struct FormatEntry {
        let ext: String          // Lowercase, no dot (e.g. "jpg")
        let mime: String         // Canonical MIME (e.g. "image/jpeg")
        let category: Category
    }

    /// The master table.
    static let all: [FormatEntry] = [
        // Images
        FormatEntry(ext: "jpg",  mime: "image/jpeg",    category: .image),
        FormatEntry(ext: "jpeg", mime: "image/jpeg",    category: .image),
        FormatEntry(ext: "png",  mime: "image/png",     category: .image),
        FormatEntry(ext: "webp", mime: "image/webp",    category: .image),
        FormatEntry(ext: "heic", mime: "image/heic",    category: .image),
        FormatEntry(ext: "avif", mime: "image/avif",    category: .image),
        FormatEntry(ext: "tiff", mime: "image/tiff",    category: .image),
        FormatEntry(ext: "tif",  mime: "image/tiff",    category: .image),
        FormatEntry(ext: "svg",  mime: "image/svg+xml", category: .image),

        // GIF (distinct category for animated rendering)
        FormatEntry(ext: "gif",  mime: "image/gif",     category: .gif),

        // Video
        FormatEntry(ext: "mp4",  mime: "video/mp4",        category: .video),
        FormatEntry(ext: "mov",  mime: "video/quicktime",   category: .video),
        FormatEntry(ext: "webm", mime: "video/webm",        category: .video),
        FormatEntry(ext: "m4v",  mime: "video/mp4",         category: .video),
        FormatEntry(ext: "hevc", mime: "video/mp4",         category: .video),
        FormatEntry(ext: "h265", mime: "video/mp4",         category: .video),
        FormatEntry(ext: "avi",  mime: "video/x-msvideo",   category: .video),
        FormatEntry(ext: "mkv",  mime: "video/x-matroska",  category: .video),

        // Audio
        FormatEntry(ext: "mp3",  mime: "audio/mpeg",  category: .audio),
        FormatEntry(ext: "wav",  mime: "audio/wav",   category: .audio),
        FormatEntry(ext: "m4a",  mime: "audio/mp4",   category: .audio),
        FormatEntry(ext: "aac",  mime: "audio/mp4",   category: .audio),
        FormatEntry(ext: "flac", mime: "audio/flac",  category: .audio),
        FormatEntry(ext: "ogg",  mime: "audio/ogg",   category: .audio),
        FormatEntry(ext: "opus", mime: "audio/opus",  category: .audio),
    ]

    // MARK: Derived Lookups

    /// Extension -> MIME type.  e.g. "jpg" -> "image/jpeg"
    static let mimeForExtension: [String: String] = {
        Dictionary(all.map { ($0.ext, $0.mime) }, uniquingKeysWith: { first, _ in first })
    }()

    /// MIME type -> preferred extension.  e.g. "video/quicktime" -> "mov"
    /// When multiple extensions share a MIME (jpg/jpeg), the first in `all` wins.
    static let extensionForMime: [String: String] = {
        var dict: [String: String] = [:]
        for entry in all where dict[entry.mime] == nil {
            dict[entry.mime] = entry.ext
        }
        // Common non-standard aliases some servers return
        dict["video/mov"] = "mov"
        dict["audio/mpeg"] = "mp3"
        dict["audio/x-m4a"] = "m4a"
        dict["audio/aac"] = "aac"
        return dict
    }()

    /// Extension -> Category.  e.g. "mp4" -> .video
    static let categoryForExtension: [String: Category] = {
        Dictionary(all.map { ($0.ext, $0.category) }, uniquingKeysWith: { first, _ in first })
    }()

    // MARK: Extension Sets

    static let videoExtensions: Set<String> = {
        Set(all.filter { $0.category == .video }.map { $0.ext })
    }()

    static let imageExtensions: Set<String> = {
        Set(all.filter { $0.category == .image }.map { $0.ext })
    }()

    static let audioExtensions: Set<String> = {
        Set(all.filter { $0.category == .audio }.map { $0.ext })
    }()

    static let allExtensions: Set<String> = {
        Set(all.map { $0.ext })
    }()

    /// Image extensions + gif.
    static let imageOrGifExtensions: Set<String> = {
        Set(all.filter { $0.category == .image || $0.category == .gif }.map { $0.ext })
    }()

    // MARK: Classification Helpers

    static func category(forExtension ext: String) -> Category? {
        categoryForExtension[ext.lowercased()]
    }

    static func category(forMime mime: String) -> Category? {
        let lower = mime.lowercased()
        if lower.contains("image/gif") { return .gif }
        if lower.hasPrefix("image/")   { return .image }
        if lower.hasPrefix("video/")   { return .video }
        if lower.hasPrefix("audio/")   { return .audio }
        return nil
    }

    static func mime(forExtension ext: String) -> String? {
        mimeForExtension[ext.lowercased()]
    }

    static func `extension`(forMime mime: String) -> String? {
        // Strip parameters (e.g. "video/mp4; codecs=avc1" → "video/mp4")
        let base = mime.lowercased().split(separator: ";").first.map(String.init) ?? mime.lowercased()
        return extensionForMime[base.trimmingCharacters(in: .whitespaces)]
    }

    // MARK: Regex

    /// All supported extensions as a regex alternation: "aac|avif|avi|..."
    static let extensionAlternation: String = {
        all.map { $0.ext }.sorted().joined(separator: "|")
    }()

    /// The extension has to end the URL's text: next comes the end, a space,
    /// `?`/`#`, or punctuation that isn't followed by more of the word. Without
    /// it `https://www.avid.com` matched as `https://www.avi`.
    private static let extensionEnd = #"(?=$|[^\w/.\-]|[.\-](?!\w))"#

    /// Matches media URLs ending in a known extension, plus Blossom hash URLs.
    /// Callers still run `isMediaURL` on each match: a regex can't tell a file
    /// from a page.
    static let mediaURLRegex: NSRegularExpression? = {
        let pattern = #"(https?://\S+?\.(?:"# + extensionAlternation + #")"# + extensionEnd + #"(?:\?\S+)?)|(https?://\S+?/blossom/[a-f0-9]{64})|(https?://\S+?/[a-f0-9]{64})"#
        return try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
    }()

    /// Matches only extension-based media URLs (no Blossom groups).
    static let mediaExtensionRegex: NSRegularExpression? = {
        let pattern = #"https?://\S+?\.(?:"# + extensionAlternation + #")"# + extensionEnd + #"(?:\?\S+)?"#
        return try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
    }()

    /// Matches extensionless Blossom URLs (SHA-256 hex as the last path part).
    static let blossomHashRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"https?://\S+/[a-f0-9]{64}(?=\s|$)"#, options: .caseInsensitive)
    }()

    // MARK: Media or Web Page

    /// Nostr web clients and gateways. They serve a web page, not a file, at
    /// `/<64-hex>` (an event id or pubkey), so their hex links aren't Blossom
    /// blobs. Exact hosts: `blossom.primal.net` is a real Blossom server.
    static let webPageHosts: Set<String> = [
        "njump.me", "njump.to", "primal.net", "nostr.band", "snort.social",
        "iris.to", "coracle.social", "nostrudel.ninja", "habla.news",
        "yakihonne.com", "nostter.app", "jumble.social", "nostr.com",
        "damus.io", "zap.stream", "highlighter.com", "nostr.at", "nostr.eu",
        "nostrrr.com", "flycat.club", "nostrapp.link", "nostr.watch",
    ]

    static func isWebPageHost(_ url: URL) -> Bool {
        guard var host = url.host?.lowercased() else { return false }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return webPageHosts.contains(host)
    }

    /// Whether a URL names a file the media grid can draw: a known media
    /// extension on its path (not its host — `.mov` is also a TLD), or a
    /// Blossom SHA-256 path on a host that isn't a web page.
    static func isMediaURL(_ url: URL) -> Bool {
        if let blossom = BlossomURI(url) { return allExtensions.contains(blossom.ext) }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        if allExtensions.contains(url.pathExtension.lowercased()) { return true }
        guard url.pathExtension.isEmpty,
              url.lastPathComponent.range(of: #"^[a-f0-9]{64}$"#, options: [.regularExpression, .caseInsensitive]) != nil
        else { return false }
        return !isWebPageHost(url)
    }

    /// An `imeta` URL is media unless it points at a web page: no media
    /// extension and a web-client host. Extensionless uploads stay, since
    /// imeta is how those announce themselves.
    static func isImetaMediaURL(_ url: URL) -> Bool {
        if allExtensions.contains(url.pathExtension.lowercased()) { return true }
        return !isWebPageHost(url)
    }

    /// The media URLs written in a note's text, in order: extension URLs,
    /// Blossom hash URLs, then BUD-10 `blossom:` links. Web pages that only
    /// look like media are dropped.
    static func mediaURLs(in content: String) -> [URL] {
        let ns = content as NSString
        let range = NSRange(location: 0, length: ns.length)
        var urls: [URL] = []
        for regex in [mediaExtensionRegex, blossomHashRegex, BlossomURI.regex].compactMap({ $0 }) {
            urls += regex.matches(in: content, range: range)
                .compactMap { URL(string: ns.substring(with: $0.range)) }
                .filter(isMediaURL)
        }
        return urls
    }
}

// MARK: - URL Convenience

extension URL {
    var mediaCategory: SupportedMediaFormats.Category? {
        SupportedMediaFormats.category(forExtension: self.pathExtension)
    }

    var isVideo: Bool {
        SupportedMediaFormats.videoExtensions.contains(self.pathExtension.lowercased())
    }

    var isAudio: Bool {
        SupportedMediaFormats.audioExtensions.contains(self.pathExtension.lowercased())
    }

    var isImage: Bool {
        let ext = self.pathExtension.lowercased()
        if SupportedMediaFormats.imageOrGifExtensions.contains(ext) { return true }
        // Blossom hash fallback: extensionless 64-char hex paths, unless the
        // host is a web client (njump.me/<event id> is a page)
        return ext.isEmpty && SupportedMediaFormats.isMediaURL(self)
    }

    var isGIF: Bool {
        self.pathExtension.lowercased() == "gif"
    }

    var isWebP: Bool {
        self.pathExtension.lowercased() == "webp"
    }
}
