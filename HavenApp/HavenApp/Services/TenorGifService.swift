import Foundation

/// A single Tenor GIF as surfaced by its search page.
struct TenorGif: Identifiable, Hashable {
    let id: String
    /// Tenor's own alt text for the GIF ("a cat knocking a glass off a table").
    /// Never drawn over the art -- Tenor's grid is captionless and these
    /// sentences are long -- but it is the only description a screen reader has.
    let description: String
    /// Small animated GIF for the picker grid.
    let previewURL: URL
    /// First frame as a static PNG. Cheap, loads before the animation.
    let stillURL: URL?
    /// Full-quality GIF we attach, already known to fit under `maxGIFBytes`.
    let attachURL: URL
    /// Intrinsic width / height of the preview, clamped by the picker.
    let aspectRatio: Double
    let pageURL: URL?
}

/// Search client for tenor.com.
///
/// Tenor's public JSON API was discontinued (`g.tenor.com/v1` answers HTTP 403
/// "Tenor API is discontinued") and the v2 API needs a Google Cloud key, so
/// there is no keyless endpoint to call. The search *page* is server-rendered
/// and embeds the full result set -- every media format, with byte sizes and
/// pixel dimensions -- in a `<script id="store-cache">` JSON blob. We fetch the
/// page and read that blob, which is the same shape of dependency
/// `YarnClipService` already takes on getyarn.io, and far steadier than a
/// regex over `<img src>`: we get real URLs, dimensions and descriptions
/// instead of whatever the markup happens to look like this month.
///
/// One page only. `?pos=<next>` on the search page is ignored -- it re-renders
/// the identical first 50 -- and the infinite scroll is driven by an API key
/// lifted from the page's own config, which is not ours to use. 50 results is
/// more than the picker reveals anyway.
///
/// Keep every Tenor-specific detail in this file so a site redesign is a
/// one-file fix.
enum TenorGifService {
    static let searchBase = "https://tenor.com/search/"
    static let maxGIFBytes = 25 * 1024 * 1024

    /// Very tall or very wide GIFs are common on Tenor and would either tower
    /// over their row or shrink to a sliver. Clamping keeps the grid readable
    /// while still never cropping the art.
    static let minAspectRatio = 0.62
    static let maxAspectRatio = 1.75

    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    enum TenorError: LocalizedError, Equatable {
        case badStatus(Int)
        case payloadMissing
        case tooLarge
        case notAGIF

        var errorDescription: String? {
            switch self {
            case .badStatus(let code): return "tenor.com returned HTTP \(code)"
            case .payloadMissing: return "Could not read tenor.com search results"
            case .tooLarge: return "GIF is too large to attach"
            case .notAGIF: return "tenor.com did not return a GIF"
            }
        }
    }

    /// The search URL for a query. Tenor's route is a slug, not a query string:
    /// `/search/<query>-gifs`, with the query percent-encoded as one path
    /// segment so spaces, slashes and punctuation survive.
    static func searchURL(for query: String) -> URL? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // `-gifs` is Tenor's suffix, not part of the query, so it is appended
        // after encoding.
        guard let slug = trimmed.addingPercentEncoding(withAllowedCharacters: .tenorSlugAllowed) else { return nil }
        return URL(string: searchBase + slug + "-gifs")
    }

    private static func request(_ url: URL) -> URLRequest {
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        return req
    }

    /// Searches tenor.com. Returns at most one page; there is no `page`
    /// parameter because the site does not honour one.
    static func search(_ query: String) async throws -> [TenorGif] {
        guard let url = searchURL(for: query) else { return [] }
        var req = request(url)
        req.setValue("text/html", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw TenorError.badStatus(http.statusCode)
        }
        guard let html = String(data: data, encoding: .utf8) else { throw TenorError.payloadMissing }
        return try parseSearchHTML(html)
    }

    /// Downloads a GIF chosen from a search result and verifies it is a GIF.
    /// The URL always comes from `attachURL`, so it is Tenor's own media host
    /// and its size was already checked against the cap in the payload; the
    /// cap is re-checked here because the payload is a claim, not a promise.
    static func downloadGIF(url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request(url))
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw TenorError.badStatus(http.statusCode)
        }
        guard data.count <= maxGIFBytes else { throw TenorError.tooLarge }
        let magic = data.prefix(6)
        guard magic == Data("GIF87a".utf8) || magic == Data("GIF89a".utf8) else { throw TenorError.notAGIF }
        return data
    }

    // MARK: - Parsing

    /// Pulls GIF records out of the search page's `store-cache` payload.
    ///
    /// Shape: `universal.search.<query-key>.results` is an array of result
    /// objects, each with a `media_formats` dictionary of
    /// `name -> {url, dims, size}`. The query key encodes the query and the
    /// content filter, so we do not try to predict it -- we read every search
    /// bucket the page shipped.
    static func parseSearchHTML(_ html: String) throws -> [TenorGif] {
        guard let payload = extractStoreCache(html),
              let json = try? JSONSerialization.jsonObject(with: Data(payload.utf8)),
              let root = json as? [String: Any],
              let universal = root["universal"] as? [String: Any],
              let search = universal["search"] as? [String: Any] else {
            throw TenorError.payloadMissing
        }

        var seen = Set<String>()
        var gifs: [TenorGif] = []
        // Dictionary order is not stable, but in practice a search page ships
        // exactly one bucket. Sorting the keys keeps a multi-bucket page from
        // reordering results between two runs of the same query.
        for key in search.keys.sorted() {
            guard let bucket = search[key] as? [String: Any],
                  let results = bucket["results"] as? [[String: Any]] else { continue }
            for result in results {
                guard let gif = parseResult(result), !seen.contains(gif.id) else { continue }
                seen.insert(gif.id)
                gifs.append(gif)
            }
        }
        return gifs
    }

    private static func parseResult(_ result: [String: Any]) -> TenorGif? {
        guard let id = result["id"] as? String, !id.isEmpty,
              let formats = result["media_formats"] as? [String: Any] else { return nil }

        // Attach quality: the biggest that still fits the cap. A Tenor `gif`
        // can be several megabytes, and the note it lands in has to upload.
        guard let attach = firstFormat(in: formats, named: ["gif", "mediumgif", "tinygif"], maxBytes: maxGIFBytes) else {
            return nil
        }
        // Grid preview: the small one, falling back to whatever we are attaching.
        let preview = firstFormat(in: formats, named: ["tinygif", "mediumgif", "gif"], maxBytes: nil) ?? attach
        let still = firstFormat(in: formats, named: ["gifpreview"], maxBytes: nil)

        let description = (result["content_description"] as? String)
            ?? (result["h1_title"] as? String)
            ?? ""
        let pageURL = (result["itemurl"] as? String).flatMap(URL.init(string:))

        return TenorGif(
            id: id,
            description: description.trimmingCharacters(in: .whitespacesAndNewlines),
            previewURL: preview.url,
            stillURL: still?.url,
            attachURL: attach.url,
            aspectRatio: aspectRatio(from: preview.dims),
            pageURL: pageURL
        )
    }

    private struct Format {
        let url: URL
        let dims: [Int]
    }

    /// First named format that parses and, when a cap is given, fits under it.
    /// A format with no `size` is treated as unknown rather than small: it is
    /// skipped when a cap applies, so an attach URL is never a guess.
    private static func firstFormat(in formats: [String: Any], named names: [String], maxBytes: Int?) -> Format? {
        for name in names {
            guard let entry = formats[name] as? [String: Any],
                  let urlString = entry["url"] as? String,
                  let url = URL(string: urlString) else { continue }
            if let maxBytes {
                guard let size = (entry["size"] as? NSNumber)?.intValue, size > 0, size <= maxBytes else { continue }
            }
            return Format(url: url, dims: (entry["dims"] as? [Int]) ?? [])
        }
        return nil
    }

    static func aspectRatio(from dims: [Int]) -> Double {
        guard dims.count == 2, dims[0] > 0, dims[1] > 0 else { return 1 }
        return min(max(Double(dims[0]) / Double(dims[1]), minAspectRatio), maxAspectRatio)
    }

    /// Extracts the `store-cache` script body.
    ///
    /// Scanning to the first `</script>` is safe here for the reason the
    /// payload looks the way it does: Tenor escapes every forward slash in the
    /// JSON as `\u002F`, precisely so no embedded string can close the tag
    /// early.
    static func extractStoreCache(_ html: String) -> String? {
        guard let idRange = html.range(of: "id=\"store-cache\""),
              let open = html.range(of: ">", range: idRange.upperBound..<html.endIndex),
              let close = html.range(of: "</script>", range: open.upperBound..<html.endIndex) else {
            return nil
        }
        return String(html[open.upperBound..<close.lowerBound])
    }
}

private extension CharacterSet {
    /// One path segment. Anything Tenor's route would read as structure --
    /// `/`, `?`, `#` -- has to be encoded, and a space becomes `%20`, which
    /// tenor.com resolves fine.
    static let tenorSlugAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()
}
