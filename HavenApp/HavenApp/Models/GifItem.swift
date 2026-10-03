import Foundation

/// Where the GIF picker is searching.
///
/// The sources are not interchangeable, and the picker leans on the
/// differences rather than flattening them: nostr.build pages on request,
/// Tenor returns fifty GIFs of every shape in a single request.
///
/// getyarn (movie and TV quote clips) was removed on 2026-10-03: we have no
/// permission to use the site (Logen).
enum GifSource: String, CaseIterable, Identifiable, Hashable {
    case nostrBuild
    case tenor

    /// Sources this build offers, in picker order. The App Store build
    /// (`APPSTORE`, set by release_all.sh) leaves out Tenor, whose search page
    /// is read without the service's permission. nostr.build is an official API.
    static var available: [GifSource] {
        #if APPSTORE
        return [.nostrBuild]
        #else
        return [.nostrBuild, .tenor]
        #endif
    }

    var id: String { rawValue }

    /// Segment label. Short enough to sit two-up on the narrowest iPhone.
    var title: String {
        switch self {
        case .nostrBuild: return "nostr.build"
        case .tenor: return "Tenor"
        }
    }

    /// Shown before a search has been run.
    var searchPrompt: String {
        switch self {
        case .nostrBuild: return "Search nostr.build for a GIF"
        case .tenor: return "Search Tenor for a GIF"
        }
    }

    /// Text-field placeholder. Both sources search on return only.
    var fieldPrompt: String {
        switch self {
        case .nostrBuild: return "Search GIFs, then press return"
        case .tenor: return "Search GIFs, then press return"
        }
    }

    /// "Show more" label. The two sources hand back different things and the
    /// button should say which.
    var moreLabel: String {
        switch self {
        case .nostrBuild: return "Show more GIFs"
        case .tenor: return "Show more GIFs"
        }
    }

    func noResults(for query: String) -> String {
        switch self {
        case .nostrBuild: return "No GIFs found for \u{201C}\(query)\u{201D}"
        case .tenor: return "No GIFs found for \u{201C}\(query)\u{201D}"
        }
    }

    var attribution: String {
        switch self {
        case .nostrBuild: return "GIFs from nostr.build"
        case .tenor: return "GIFs via Tenor"
        }
    }

    /// nostr.build serves pages; Tenor's search page renders one set of 50 and
    /// ignores a request for a second, so "show more" there only ever reveals
    /// what is already in hand.
    var supportsPaging: Bool {
        switch self {
        case .nostrBuild: return true
        case .tenor: return false
        }
    }
}

/// One searchable GIF, flattened from whichever source produced it so the grid
/// does not have to know which one it is drawing.
struct GifItem: Identifiable, Hashable {
    let source: GifSource
    /// Unique within a source; `id` prefixes it so two sources cannot collide.
    let sourceID: String
    /// Small animated preview for the grid.
    let previewURL: URL
    /// Static first frame, drawn while the animation arrives.
    let stillURL: URL?
    /// Full-quality GIF to download when the cell is picked.
    let attachURL: URL
    /// Drawn over the art when present. Tenor items have none: their
    /// descriptions are long alt-text sentences that would bury the GIF.
    let caption: String?
    let subcaption: String?
    /// Read out in place of the art. Always populated, caption or not.
    let accessibilityText: String
    /// Width / height of the preview. The grid draws each cell at its own
    /// ratio rather than cropping everything to a common one.
    let aspectRatio: Double

    var id: String { "\(source.rawValue):\(sourceID)" }

    init(_ gif: NostrBuildGif) {
        source = .nostrBuild
        sourceID = gif.id
        previewURL = gif.previewURL
        stillURL = gif.stillURL
        attachURL = gif.url
        caption = nil
        subcaption = nil
        accessibilityText = gif.title.isEmpty ? "GIF from nostr.build" : gif.title
        aspectRatio = gif.aspectRatio
    }

    init(_ gif: TenorGif) {
        source = .tenor
        sourceID = gif.id
        previewURL = gif.previewURL
        stillURL = gif.stillURL
        attachURL = gif.attachURL
        caption = nil
        subcaption = nil
        accessibilityText = gif.description.isEmpty ? "GIF from Tenor" : gif.description
        aspectRatio = gif.aspectRatio
    }
}
