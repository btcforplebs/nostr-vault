import Foundation

// MARK: - Media Gallery type definitions
// Extracted from ViewerView for the MediaGallery tab split.

enum MediaLayoutMode: String {
    case grid
    case list
}

enum MediaSourceFilter {
    case all
    case blossom
    case cache
}

enum MediaLocationFilter {
    case all
    case blossom
    case cache
    case notFound
}

enum MediaTypeFilter: String, CaseIterable {
    case photo = "Photo"
    case video = "Video"
    case gif = "GIF"
    case other = "Other"

    /// The chip an item is counted under. Shared by the Media tab and the
    /// composer's relay picker so the same file lands under the same chip in both.
    static func category(of item: MediaItem) -> MediaTypeFilter {
        let ext = item.url.pathExtension.lowercased()
        if ext == "gif" || item.mimeType?.lowercased().contains("gif") == true { return .gif }
        switch item.type {
        case .image: return .photo
        case .video: return .video
        case .audio, .unknown: return .other
        }
    }

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

// MARK: - Sorting

/// How the media gallery orders its items. Persisted by raw value.
enum MediaSortOption: String, CaseIterable, Identifiable {
    case newestFirst
    case oldestFirst
    case mediaType
    case onRelayFirst

    var id: String { rawValue }

    var label: String {
        switch self {
        case .newestFirst:  return "Newest first"
        case .oldestFirst:  return "Oldest first"
        case .mediaType:    return "Media type"
        case .onRelayFirst: return "On relay first"
        }
    }

    var icon: String {
        switch self {
        case .newestFirst:  return "arrow.down"
        case .oldestFirst:  return "arrow.up"
        case .mediaType:    return "square.grid.3x3"
        case .onRelayFirst: return "externaldrive"
        }
    }

    /// Date headings only mean something when the list is actually ordered by
    /// date. Under any other sort the items are interleaved across dates, so a
    /// "Today" heading would sit above items from any month.
    var groupsByDate: Bool {
        self == .newestFirst || self == .oldestFirst
    }

    /// Shared with the composer's relay picker, like `MediaTypeFilter.storageKey`.
    static let storageKey = "mediaGallery.sortOption"

    /// Orders `items` for this option. Every branch falls back to date so the
    /// result is fully determined and does not shuffle between runs.
    func sorted(_ items: [MediaItem], isOnRelay: (MediaItem) -> Bool) -> [MediaItem] {
        switch self {
        case .newestFirst:
            return items.sorted { $0.dateAdded > $1.dateAdded }
        case .oldestFirst:
            return items.sorted { $0.dateAdded < $1.dateAdded }
        case .mediaType:
            return items.sorted {
                let a = MediaGalleryView.typeRank(for: $0), b = MediaGalleryView.typeRank(for: $1)
                if a != b { return a < b }
                return $0.dateAdded > $1.dateAdded
            }
        case .onRelayFirst:
            return items.sorted {
                let a = isOnRelay($0), b = isOnRelay($1)
                if a != b { return a }
                return $0.dateAdded > $1.dateAdded
            }
        }
    }
}

// MARK: - Date sections

/// One dated run of media items, in the order they already appear in the list.
struct MediaDateSection: Identifiable {
    let id: String
    let title: String
    let items: [MediaItem]
}

extension MediaDateSection {
    /// Adapts the generic grouping in `MediaDateGrouping` to the gallery's
    /// items. The heading doubles as the identity: a date-sorted list cannot
    /// produce the same heading twice.
    static func sections(for items: [MediaItem],
                         now: Date = Date(),
                         calendar: Calendar = .current) -> [MediaDateSection] {
        MediaDateGrouping.runs(of: items, date: \.dateAdded, now: now, calendar: calendar)
            .map { MediaDateSection(id: $0.title, title: $0.title, items: $0.items) }
    }
}
