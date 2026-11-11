import Foundation

/// Where the GIF picker is searching.
///
/// nostr.build (an official API, paged on request) is the only source.
/// getyarn (movie and TV quote clips) was removed on 2026-10-03 and the
/// scraped GIF search on 2026-11-11: we have no permission to use either
/// site (Logen).
enum GifSource: String, CaseIterable, Identifiable, Hashable {
    case nostrBuild

    /// Sources this build offers, in picker order. Safe by default:
    ///
    /// - nostr.build (an official API) only when the build carries its API key
    ///   (`NostrBuildGIFAPIKey`, from the gitignored Secrets.xcconfig).
    ///
    /// Empty means the composer hides its GIF button.
    static var available: [GifSource] {
        var sources: [GifSource] = []
        if NostrBuildGifService.isConfigured { sources.append(.nostrBuild) }
        return sources
    }

    var id: String { rawValue }

    /// Segment label. Short enough to sit two-up on the narrowest iPhone.
    var title: String {
        switch self {
        case .nostrBuild: return "nostr.build"
        }
    }

    /// Shown before a search has been run.
    var searchPrompt: String {
        switch self {
        case .nostrBuild: return "Search nostr.build for a GIF"
        }
    }

    /// Text-field placeholder. Both sources search on return only.
    var fieldPrompt: String {
        switch self {
        case .nostrBuild: return "Search GIFs, then press return"
        }
    }

    /// "Show more" label. The two sources hand back different things and the
    /// button should say which.
    var moreLabel: String {
        switch self {
        case .nostrBuild: return "Show more GIFs"
        }
    }

    func noResults(for query: String) -> String {
        switch self {
        case .nostrBuild: return "No GIFs found for \u{201C}\(query)\u{201D}"
        }
    }

    var attribution: String {
        switch self {
        case .nostrBuild: return "GIFs from nostr.build"
        }
    }

    /// nostr.build serves pages.
    var supportsPaging: Bool {
        switch self {
        case .nostrBuild: return true
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
    /// Drawn over the art when present.
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

}
