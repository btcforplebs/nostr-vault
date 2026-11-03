import Foundation

/// What a shared picture or video post publishes: NIP-68 (kind 20) for
/// pictures, NIP-71 (kind 21, or 22 for a portrait video) for one video.
/// Pure, so it is unit tested against the shared fixtures
/// (`Fixtures/SharePortal/media-post-cases.json`); Android's
/// MediaPostShareTags.kt builds the same event.
///
/// One post is pictures or one video, never both: NIP-68 holds only
/// pictures and NIP-71 one video. The review card says so before anything
/// uploads.
enum MediaPostShareTags {
    static let pictureKind = 20
    static let videoKind = 21
    static let shortVideoKind = 22
    static let maxPictures = 20

    /// One uploaded file, as the event describes it.
    struct Media: Equatable {
        var url: String
        var mime: String
        var sha256: String
        var width: Int?
        var height: Int?
        var bytes: Int?
        /// Seconds, videos only.
        var duration: Double?
        var alt: String?
    }

    enum Shape: Equatable {
        case pictures
        case video
    }

    enum Problem: Error, Equatable {
        case nothing
        case mixed
        case tooManyVideos
        case tooManyPictures
        case notMedia

        var message: String {
            switch self {
            case .nothing: return "Nothing to post: no picture or video came with this share."
            case .mixed: return "A post is pictures or one video, not both. Share them separately."
            case .tooManyVideos: return "One video per post. Share the others separately."
            case .tooManyPictures: return "Up to \(MediaPostShareTags.maxPictures) pictures per post."
            case .notMedia: return "Only pictures and videos can be posted."
            }
        }
    }

    static func isPicture(_ mime: String) -> Bool { mime.lowercased().hasPrefix("image/") }
    static func isVideo(_ mime: String) -> Bool { mime.lowercased().hasPrefix("video/") }

    /// Pictures NIP-68 lists. Anything else (HEIC, TIFF, …) is turned into a
    /// JPEG before it uploads, so every reader can show it.
    static let postableImageTypes: Set<String> = ["image/jpeg", "image/png", "image/gif", "image/webp", "image/avif", "image/apng"]

    static func needsJPEG(_ mime: String) -> Bool {
        isPicture(mime) && !postableImageTypes.contains(mime.lowercased())
    }

    /// What the shared files can become, by their types.
    static func shape(mimes: [String]) -> Result<Shape, Problem> {
        guard !mimes.isEmpty else { return .failure(.nothing) }
        if mimes.contains(where: { !isPicture($0) && !isVideo($0) }) { return .failure(.notMedia) }
        let videos = mimes.filter(isVideo).count
        if videos > 0 && videos < mimes.count { return .failure(.mixed) }
        if videos > 1 { return .failure(.tooManyVideos) }
        if videos == 1 { return .success(.video) }
        if mimes.count > maxPictures { return .failure(.tooManyPictures) }
        return .success(.pictures)
    }

    /// Kind 22 for a video taller than it is wide (NIP-71 short form).
    static func kind(_ shape: Shape, media: [Media]) -> Int {
        switch shape {
        case .pictures: return pictureKind
        case .video:
            if let m = media.first, let w = m.width, let h = m.height, h > w { return shortVideoKind }
            return videoKind
        }
    }

    /// One `imeta` per file (NIP-92 fields), in the order shared.
    static func imeta(_ m: Media) -> [String] {
        var fields = ["imeta", "url \(m.url)", "m \(m.mime.lowercased())", "x \(m.sha256)"]
        if let w = m.width, let h = m.height, w > 0, h > 0 { fields.append("dim \(w)x\(h)") }
        if let size = m.bytes, size > 0 { fields.append("size \(size)") }
        if let d = m.duration, d > 0 { fields.append("duration \(format(d))") }
        if let alt = flat(m.alt) { fields.append("alt \(alt)") }
        return fields
    }

    /// The event's tags. `title` is the short name readers show; empty means
    /// none for pictures, and the caption's first line (or "Video") for a
    /// video, where NIP-71 asks for one. `publishedAt` is a unix time.
    static func tags(_ shape: Shape, media: [Media], title: String, caption: String, publishedAt: Int) -> [[String]] {
        var out: [[String]] = []
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        switch shape {
        case .pictures:
            if !t.isEmpty { out.append(["title", t]) }
        case .video:
            out.append(["title", t.isEmpty ? videoTitle(caption) : t])
            out.append(["published_at", String(publishedAt)])
        }
        for m in media { out.append(imeta(m)) }
        // NIP-68 filter tags: each type and hash once.
        if shape == .pictures {
            var types: [String] = []
            for m in media where !types.contains(m.mime.lowercased()) { types.append(m.mime.lowercased()) }
            for type in types { out.append(["m", type]) }
            for m in media { out.append(["x", m.sha256]) }
        }
        out.append(contentsOf: NoteTagging.hashtagTags(in: "\(t) \(caption)"))
        out.append(["alt", altText(shape, count: media.count, title: t, caption: caption)])
        return out
    }

    /// The caption is the content, trimmed.
    static func content(caption: String) -> String {
        caption.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func videoTitle(_ caption: String) -> String {
        let first = caption.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        if first.isEmpty { return "Video" }
        return first.count > 80 ? String(first.prefix(80)) + "…" : first
    }

    /// For clients that don't know these kinds (NIP-31).
    static func altText(_ shape: Shape, count: Int, title: String, caption: String) -> String {
        let what: String
        switch shape {
        case .pictures: what = count == 1 ? "A picture" : "\(count) pictures"
        case .video: what = "A video"
        }
        let about = title.isEmpty ? (flat(caption).map { String($0.prefix(140)) } ?? "") : title
        return about.isEmpty ? what : "\(what): \(about)"
    }

    private static func flat(_ s: String?) -> String? {
        guard let s else { return nil }
        let joined = s.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return joined.isEmpty ? nil : joined
    }

    /// Seconds with at most 3 decimals, no trailing zeros ("12", "12.5").
    static func format(_ seconds: Double) -> String {
        let ms = (seconds * 1000).rounded()
        let whole = Int(ms) / 1000, frac = Int(ms) % 1000
        if frac == 0 { return String(whole) }
        var f = String(format: "%03d", frac)
        while f.hasSuffix("0") { f.removeLast() }
        return "\(whole).\(f)"
    }
}
