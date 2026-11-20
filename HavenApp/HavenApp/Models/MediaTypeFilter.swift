import Foundation

/// The Media tab's type chips. Pure rules only, so MediaLogic tests can
/// compile it; `category(of:)` for a `MediaItem` lives in MediaGalleryTypes.
enum MediaTypeFilter: String, CaseIterable {
    case photo = "Photo"
    case video = "Video"
    case gif = "GIF"
    case other = "Other"

    /// Decodes the persisted selection. An empty selection shows nothing at
    /// all and there is no UI path back from it, so "none stored" means
    /// "everything".
    static func selection(from raw: String) -> Set<MediaTypeFilter> {
        let stored = Set(raw.split(separator: ",").compactMap { MediaTypeFilter(rawValue: String($0)) })
        return stored.isEmpty ? Set(allCases) : stored
    }

    /// Encodes a selection in `allCases` order so the stored string is stable.
    static func rawSelection(_ selection: Set<MediaTypeFilter>) -> String {
        allCases.filter { selection.contains($0) }.map(\.rawValue).joined(separator: ",")
    }

    /// Storage key the Media tab and the composer's relay picker share, so
    /// organising one organises the other.
    static let storageKey = "mediaGallery.typeFilter"
}
