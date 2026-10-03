import Foundation

/// A single getyarn.io clip as surfaced by its search page.
struct YarnClip: Identifiable, Hashable {
    let uuid: String
    let transcript: String
    let videoTitle: String
    let duration: Double

    var id: String { uuid }

    /// Full-resolution GIF with the caption burned in. Only a fallback now:
    /// `downloadCleanGIF` attaches the clip without the quote.
    var gifHiURL: URL { YarnClipService.mediaURL(uuid: uuid, suffix: "_text_hi.gif") }
    /// Small looping preview GIF for the picker grid.
    var gifSmallURL: URL { YarnClipService.mediaURL(uuid: uuid, suffix: "_text_200_10.gif") }
    /// Static thumbnail (cheap, loads first).
    var thumbURL: URL { YarnClipService.mediaURL(uuid: uuid, suffix: "_thumb.jpg") }
    var mp4URL: URL { YarnClipService.mediaURL(uuid: uuid, suffix: ".mp4") }
    var pageURL: URL { URL(string: "https://getyarn.io/yarn-clip/\(uuid)")! }
}

/// Search client for getyarn.io.
///
/// getyarn.io has no public API. Its search page is server-rendered Nuxt and
/// embeds every result in a `<script id="__NUXT_DATA__">` JSON payload
/// (devalue format: a flat array where object values are indices into the
/// same array). We fetch the page and pull the clip objects out of that
/// payload. Media lives on `y.yarn.co` under a fixed per-uuid naming scheme,
/// so a uuid alone is enough to build every media URL.
///
/// Cloudflare fronts both hosts and rejects non-browser TLS fingerprints
/// (curl gets 403), but URLSession is accepted. Keep every getyarn-specific
/// detail in this file so a site redesign is a one-file fix.
enum YarnClipService {
    static let searchBase = "https://getyarn.io/yarn-find"
    static let mediaBase = "https://y.yarn.co/"
    static let maxGIFBytes = 25 * 1024 * 1024

    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    enum YarnError: LocalizedError {
        case badStatus(Int)
        case payloadMissing
        case tooLarge
        case notAGIF

        var errorDescription: String? {
            switch self {
            case .badStatus(let code): return "getyarn.io returned HTTP \(code)"
            case .payloadMissing: return "Could not read getyarn.io search results"
            case .tooLarge: return "GIF is too large to attach"
            case .notAGIF: return "getyarn.io did not return a GIF"
            }
        }
    }

    static func mediaURL(uuid: String, suffix: String) -> URL {
        URL(string: mediaBase + uuid + suffix)!
    }

    /// Recognises a pasted getyarn.io clip link and returns its uuid.
    /// Accepts `https://getyarn.io/yarn-clip/<uuid>` (any query/fragment) and
    /// direct `https://y.yarn.co/<uuid>[suffix]` media links.
    static func clipUUID(from url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        let uuidPattern = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
        let path = url.path.lowercased()
        if host == "getyarn.io" || host == "www.getyarn.io" {
            guard path.hasPrefix("/yarn-clip/") else { return nil }
            let rest = String(path.dropFirst("/yarn-clip/".count))
            return rest.range(of: "^\(uuidPattern)", options: .regularExpression).map { String(rest[$0]) }
        }
        if host == "y.yarn.co" {
            let rest = String(path.dropFirst())
            return rest.range(of: "^\(uuidPattern)", options: .regularExpression).map { String(rest[$0]) }
        }
        return nil
    }

    private static func request(_ url: URL) -> URLRequest {
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        return req
    }

    /// Searches getyarn.io for clips matching a quote. `page` is 0-based.
    static func search(_ query: String, page: Int = 0) async throws -> [YarnClip] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var comps = URLComponents(string: searchBase)!
        var items = [URLQueryItem(name: "text", value: trimmed)]
        if page > 0 { items.append(URLQueryItem(name: "p", value: String(page))) }
        comps.queryItems = items
        var req = request(comps.url!)
        req.setValue("text/html", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw YarnError.badStatus(http.statusCode)
        }
        guard let html = String(data: data, encoding: .utf8) else { throw YarnError.payloadMissing }
        return try parseSearchHTML(html)
    }

    /// Downloads the attach-quality GIF for a clip and verifies it is a GIF.
    static func downloadGIF(uuid: String) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request(mediaURL(uuid: uuid, suffix: "_text_hi.gif")))
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw YarnError.badStatus(http.statusCode)
        }
        guard data.count <= maxGIFBytes else { throw YarnError.tooLarge }
        let magic = data.prefix(6)
        guard magic == Data("GIF87a".utf8) || magic == Data("GIF89a".utf8) else { throw YarnError.notAGIF }
        return data
    }

    /// The clip as a GIF without the quote burned in. getyarn's full-size
    /// GIFs all carry the caption; its MP4 doesn't, so the GIF is made from
    /// that on device. Falls back to the captioned GIF if the MP4 can't be
    /// fetched or converted, so picking a clip still attaches something.
    static func downloadCleanGIF(uuid: String) async throws -> Data {
        do {
            let (video, response) = try await URLSession.shared.data(for: request(mediaURL(uuid: uuid, suffix: ".mp4")))
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw YarnError.badStatus(http.statusCode)
            }
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("yarn-\(uuid).mp4")
            try video.write(to: file)
            defer { try? FileManager.default.removeItem(at: file) }
            return try await ClipGIFEncoder.gif(fromVideoAt: file, maxBytes: maxGIFBytes)
        } catch {
            return try await downloadGIF(uuid: uuid)
        }
    }

    // MARK: - Parsing

    /// Pulls clip records out of the search page's `__NUXT_DATA__` payload.
    /// Tolerant of layout changes: we do not walk the object tree, we scan the
    /// flat array for any dictionary that carries a clip's identifying keys
    /// and resolve its scalar fields through the index table.
    static func parseSearchHTML(_ html: String) throws -> [YarnClip] {
        guard let payload = extractNuxtData(html),
              let json = try? JSONSerialization.jsonObject(with: Data(payload.utf8)),
              let table = json as? [Any] else {
            throw YarnError.payloadMissing
        }

        func resolve(_ value: Any?) -> Any? {
            // devalue: a positive Int is an index into the table, unless it is
            // the already-resolved scalar we want. Clip fields we read are all
            // strings or doubles, so treat ints as references and follow once.
            guard let value else { return nil }
            if let idx = value as? Int, idx >= 0, idx < table.count {
                let target = table[idx]
                if target is [Any] || target is [String: Any] { return nil }
                return target
            }
            return value
        }

        var seen = Set<String>()
        var clips: [YarnClip] = []
        for entry in table {
            guard let dict = entry as? [String: Any],
                  dict["uuid"] != nil, dict["transcript"] != nil, dict["gifHi"] != nil else { continue }
            guard let uuid = resolve(dict["uuid"]) as? String, !uuid.isEmpty, !seen.contains(uuid) else { continue }
            let transcript = (resolve(dict["transcript"]) as? String) ?? ""
            let title = (resolve(dict["videoTitle"]) as? String) ?? ""
            let duration = (resolve(dict["duration"]) as? NSNumber)?.doubleValue ?? 0
            seen.insert(uuid)
            clips.append(YarnClip(uuid: uuid, transcript: transcript, videoTitle: title, duration: duration))
        }
        return clips
    }

    static func extractNuxtData(_ html: String) -> String? {
        guard let idRange = html.range(of: "id=\"__NUXT_DATA__\""),
              let open = html.range(of: ">", range: idRange.upperBound..<html.endIndex),
              let close = html.range(of: "</script>", range: open.upperBound..<html.endIndex) else {
            return nil
        }
        return String(html[open.upperBound..<close.lowerBound])
    }
}
