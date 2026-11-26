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

extension MediaTypeFilter {
    /// The chip an item is counted under. Shared by the Media tab and the
    /// composer's relay picker so the same file lands under the same chip in both.
    static func category(of item: MediaItem) -> MediaTypeFilter {
        let fallback: MediaTypeFilter
        switch item.type {
        case .image: fallback = .photo
        case .video: fallback = .video
        case .audio: fallback = .audio
        case .unknown: fallback = .other
        }
        return category(mimeType: item.mimeType, pathExtension: item.url.pathExtension, fallback: fallback)
    }
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
            return items.sorted(by: Self.newer)
        case .oldestFirst:
            return items.sorted { Self.newer($1, $0) }
        case .mediaType:
            return items.sorted {
                let a = MediaGalleryView.typeRank(for: $0), b = MediaGalleryView.typeRank(for: $1)
                if a != b { return a < b }
                return Self.newer($0, $1)
            }
        case .onRelayFirst:
            return items.sorted {
                let a = isOnRelay($0), b = isOnRelay($1)
                if a != b { return a }
                return Self.newer($0, $1)
            }
        }
    }

    /// Newer first; photos from one note share a date, so the address breaks
    /// the tie. Without it they come back in a new order every page and the
    /// mosaic re-deals sections already scrolled past.
    static func newer(_ a: MediaItem, _ b: MediaItem) -> Bool {
        if a.dateAdded != b.dateAdded { return a.dateAdded > b.dateAdded }
        return a.url.absoluteString < b.url.absoluteString
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
