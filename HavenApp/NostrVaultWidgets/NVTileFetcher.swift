import Foundation

// MARK: - Tile fetching
//
// The half of the media problem the app cannot solve for us.
//
// Blossom blobs living on this device are shrunk by the app and handed over as
// bytes (see NVThumbnails). Media hosted anywhere else has no local file to
// shrink, so it has to come down the wire — and the only place a widget may do
// that is its timeline provider, which is async and does have a network. The
// widget's `body` has neither, which is why `AsyncImage` renders a placeholder
// and never resolves.
//
// Everything here is therefore best-effort and firmly time-boxed: a widget that
// takes too long to produce a timeline gets its entry dropped, so a slow host
// must cost us that tile, never the whole grid.
enum NVTileFetcher {
    /// Per-request ceiling. Short on purpose: the tile is decoration, and a
    /// widget refresh that stalls is worse than a gap in the grid.
    private static let timeout: TimeInterval = 4

    /// Tiles fetched per refresh. Each one is a request and a decode inside a
    /// process with a hard memory ceiling.
    private static let maxConcurrentFetches = 12

    static func fetch(_ tiles: [NVWidgetSnapshot.MediaTile], maxPixel: Int = 160) async -> [String: Data] {
        await fetch(tiles.map { (id: $0.id, url: $0.url) }, maxPixel: maxPixel)
    }

    /// The same fetch keyed by whatever the caller wants. Feed Glance keys
    /// avatars by URL so two notes from one author cost one download.
    static func fetch(_ items: [(id: String, url: URL)],
                      maxPixel: Int = 160,
                      limit: Int = maxConcurrentFetches) async -> [String: Data] {
        let wanted = items.filter { isFetchable($0.url) }.prefix(limit)
        guard !wanted.isEmpty else { return [:] }

        // Not an ephemeral session: a widget refreshes on a timer, and the same
        // avatars come back every time. The shared URL cache turns all but the
        // first refresh into a disk read.
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = timeout
        config.requestCachePolicy = .returnCacheDataElseLoad
        let session = URLSession(configuration: config)

        return await withTaskGroup(of: (String, Data)?.self) { group in
            for item in wanted {
                group.addTask {
                    guard let (data, response) = try? await session.data(from: item.url),
                          (response as? HTTPURLResponse)?.statusCode ?? 200 < 400,
                          let shrunk = NVDownsample.tile(from: data, maxPixel: maxPixel)
                    else { return nil }
                    return (item.id, shrunk)
                }
            }
            var out: [String: Data] = [:]
            for await result in group {
                if let (id, data) = result { out[id] = data }
            }
            return out
        }
    }

    /// The relay serves its own blobs from 127.0.0.1, and the relay is only up
    /// while the app is running — which is precisely when nobody is looking at
    /// the Home Screen. Those tiles come from the handoff or not at all, so
    /// spending a 4 s timeout on them would just delay every other tile.
    /// A `.fips` vault is reachable only over the mesh, which the widget has
    /// no way into; looking its host up would hand the vault npub to the
    /// resolver on every refresh.
    private static func isFetchable(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        if host.hasSuffix(".fips") || host.hasSuffix(".fips.") { return false }
        return host != "127.0.0.1" && host != "localhost" && host != "::1"
    }
}
