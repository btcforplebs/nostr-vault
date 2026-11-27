import Foundation

/// Fills in the size of a media file that no local source knows (a link in
/// someone else's post, or a server that leaves `size` out of its list) with
/// one `HEAD` request, asked only for rows on screen and remembered by hash
/// (`MediaSizeCache`). Concurrent asks for one hash share one request.
@MainActor
final class MediaSizeLookup {
    static let shared = MediaSizeLookup()

    private var cache = MediaSizeCache()
    private var inFlight: [String: Task<Int64?, Never>] = [:]
    private var saveTask: Task<Void, Never>?

    private static var diskURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("media_sizes.json")
    }

    private init() {
        guard let url = Self.diskURL, let data = try? Data(contentsOf: url),
              let saved = try? JSONDecoder().decode(MediaSizeCache.self, from: data) else { return }
        cache = saved
    }

    /// The size already known for `hash`, without asking anyone.
    func cached(hash: String) -> Int64? { cache.size(hash) }

    /// The size of the file at `url` (whose content hash is `hash`), asking
    /// the server once if it is not known yet. nil when the server gives none.
    func size(hash: String, url: URL) async -> Int64? {
        let key = hash.lowercased()
        guard MediaSizeCache.isHash(key) else { return nil }
        if let known = cache.size(key) { return known }
        if let running = inFlight[key] { return await running.value }
        guard url.scheme == "https" || url.scheme == "http",
              !(url.host?.lowercased().hasSuffix(".fips") ?? true) else { return nil }
        let task = Task<Int64?, Never> {
            var request = URLRequest(url: url)
            request.httpMethod = "HEAD"
            request.timeoutInterval = 5
            guard let (_, response) = try? await MediaSessionService.shared.session.data(for: request),
                  let http = response as? HTTPURLResponse else { return nil }
            return MediaSizeCache.size(status: http.statusCode,
                                       contentLength: http.value(forHTTPHeaderField: "Content-Length"))
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        if let result {
            cache.store(hash: key, size: result)
            scheduleSave()
        }
        return result
    }

    /// One write a moment after the last answer, so a screenful is one write.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, let url = Self.diskURL else { return }
            cache = cache.pruned()
            guard let data = try? JSONEncoder().encode(cache) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}
