import Foundation

// MARK: - nostr.build GIF API

/// One GIF from gifs.nostr.build. `url` is the original, already hosted on
/// nostr.build, so it can go straight into a note.
struct NostrBuildGif: Identifiable, Hashable {
    let id: String
    let url: URL
    let title: String
    /// Width-fitted animated WebP (at most 240 px wide) for the picker grid,
    /// or the still when the GIF is too large to animate.
    let previewURL: URL
    let stillURL: URL?
    let aspectRatio: Double
}

/// Client for the official gifs.nostr.build API
/// (https://gifs.nostr.build/developers/reference).
///
/// Every request must come from a registered client. A native app registers
/// either an API key or its User-Agent; the app uses the User-Agent route, so
/// there is no secret in the binary for anyone to pull out. Until the
/// registration is approved the API answers 403 `client_not_registered`,
/// which the picker reports as `notRegistered` and steps past.
enum NostrBuildGifService {
    static let baseURL = URL(string: "https://gifs.nostr.build/api/v1/")!

    /// API key for a registered client (`Authorization: Bearer gnb_…`), which
    /// is how the API's guide says native apps identify. It comes from the
    /// gitignored Config/Secrets.xcconfig through Info.plist; the repo is
    /// public, so it is never committed. Empty = feature off.
    static var apiKey: String {
        let raw = Bundle.main.object(forInfoDictionaryKey: "NostrBuildGIFAPIKey") as? String ?? ""
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // An unexpanded `$(NOSTR_BUILD_GIF_KEY)` means no xcconfig reached the build.
        return key.hasPrefix("$(") ? "" : key
    }

    static var isConfigured: Bool { !apiKey.isEmpty }

    /// The User-Agent registered with gifs.nostr.build. Changing it means
    /// registering the new one.
    static var userAgent: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        #if os(iOS)
        let platform = "iOS"
        #else
        let platform = "macOS"
        #endif
        return "NostrVault/\(version) (\(platform); +https://github.com/btcforplebs/nostr-vault)"
    }

    enum ServiceError: LocalizedError {
        case notRegistered
        case rateLimited
        case unavailable(Int)

        var errorDescription: String? {
            switch self {
            case .notRegistered: return "nostr.build GIFs aren't switched on for this app yet"
            case .rateLimited: return "nostr.build is busy, try again in a moment"
            case .unavailable(let code): return "nostr.build GIFs are unavailable (\(code))"
            }
        }
    }

    static let pageSize = 24

    static func search(_ query: String, page: Int) async throws -> [NostrBuildGif] {
        var parts = URLComponents(url: baseURL.appendingPathComponent("search"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: String(pageSize)),
            URLQueryItem(name: "offset", value: String(page * pageSize)),
        ]
        var request = URLRequest(url: parts.url!)
        request.timeoutInterval = 15
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if isConfigured {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ServiceError.unavailable(-1) }
        switch http.statusCode {
        case 200: break
        case 403: throw ServiceError.notRegistered
        case 429: throw ServiceError.rateLimited
        default: throw ServiceError.unavailable(http.statusCode)
        }
        return try decode(data)
    }

    /// Decodes a search page. Split out so it can be checked without the network.
    static func decode(_ data: Data) throws -> [NostrBuildGif] {
        struct Page: Decodable { let items: [Item] }
        struct Preview: Decodable { let width: Int; let height: Int; let animated: String?; let still: String }
        struct Previews: Decodable { let w240: Preview }
        struct Item: Decodable {
            let id: String
            let url: String
            let width: Int
            let height: Int
            let title: String
            let previews: Previews
        }
        return try JSONDecoder().decode(Page.self, from: data).items.compactMap { item in
            guard let url = URL(string: item.url),
                  let still = URL(string: item.previews.w240.still) else { return nil }
            let preview = item.previews.w240.animated.flatMap(URL.init(string:)) ?? still
            let w = Double(item.previews.w240.width), h = Double(item.previews.w240.height)
            let ratio = (w > 0 && h > 0) ? w / h : (item.height > 0 ? Double(item.width) / Double(item.height) : 1)
            return NostrBuildGif(id: item.id, url: url, title: item.title,
                                 previewURL: preview, stillURL: still,
                                 aspectRatio: min(max(ratio, 0.5), 2.5))
        }
    }
}

extension NostrBuildGifService {
    static let maxDownloadBytes = 25 * 1024 * 1024

    enum DownloadError: LocalizedError {
        case tooLarge
        case notAGIF

        var errorDescription: String? {
            switch self {
            case .tooLarge: return "GIF is too large to attach"
            case .notAGIF: return "nostr.build did not return a GIF"
            }
        }
    }

    /// Downloads a picked GIF for re-hosting on the user's own Blossom
    /// servers. nostr.build serves both GIF and animated WebP originals.
    static func download(_ url: URL) async throws -> (data: Data, isWebP: Bool) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ServiceError.unavailable(http.statusCode)
        }
        guard data.count <= maxDownloadBytes else { throw DownloadError.tooLarge }
        let isGIF = data.prefix(6) == Data("GIF87a".utf8) || data.prefix(6) == Data("GIF89a".utf8)
        let isWebP = data.count >= 12 && data.prefix(4) == Data("RIFF".utf8) && data[8..<12] == Data("WEBP".utf8)
        guard isGIF || isWebP else { throw DownloadError.notAGIF }
        return (data, isWebP)
    }
}
