import Foundation

/// The Media tab's type chips. Pure rules only, so MediaLogic tests can
/// compile it; `category(of:)` for a `MediaItem` lives in MediaGalleryTypes.
enum MediaTypeFilter: String, CaseIterable {
    case photo = "Photo"
    case video = "Video"
    case gif = "GIF"
    case audio = "Audio"
    case other = "Other"

    /// Audio file endings the Audio chip matches when the MIME type is missing.
    static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "ogg", "opus", "flac"]

    /// The chip for a file: GIF first, then Audio by `audio/*` MIME or file
    /// ending, then `fallback` (what the item's own type says).
    static func category(mimeType: String?, pathExtension: String, fallback: MediaTypeFilter) -> MediaTypeFilter {
        let mime = mimeType?.lowercased() ?? ""
        let ext = pathExtension.lowercased()
        if ext == "gif" || mime.contains("gif") { return .gif }
        if mime.hasPrefix("audio/") || audioExtensions.contains(ext) { return .audio }
        return fallback
    }

    /// Decodes the persisted selection. An empty selection shows nothing at
    /// all and there is no UI path back from it, so "none stored" means
    /// "everything".
    static func selection(from raw: String) -> Set<MediaTypeFilter> {
        let stored = Set(raw.split(separator: ",").compactMap { MediaTypeFilter(rawValue: String($0)) })
        // Saved as "everything" before Audio existed: still everything.
        if stored.isEmpty || stored == [.photo, .video, .gif, .other] { return Set(allCases) }
        return stored
    }

    /// Encodes a selection in `allCases` order so the stored string is stable.
    static func rawSelection(_ selection: Set<MediaTypeFilter>) -> String {
        allCases.filter { selection.contains($0) }.map(\.rawValue).joined(separator: ",")
    }

    /// Storage key the Media tab and the composer's relay picker share, so
    /// organising one organises the other.
    static let storageKey = "mediaGallery.typeFilter"
}
