import Foundation

/// Fetches a shared page's HTML for the recipe and calendar actions (§6.2):
/// http(s) only, GET, 15 s, `text/html` only, at most 3 MB. In the app, never
/// in the share extension. No cookies are sent or kept.
enum SharePageFetcher {
    static let maxBytes = 3 * 1024 * 1024

    static func html(_ urlString: String?) async -> String? {
        guard let urlString, let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return nil }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 15
        config.httpShouldSetCookies = false
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        guard let (bytes, response) = try? await session.bytes(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let mime = http.mimeType?.lowercased(), mime == "text/html" || mime == "application/xhtml+xml" else { return nil }
        if http.expectedContentLength > Int64(maxBytes) { return nil }
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > maxBytes { return nil }
            }
        } catch { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }
}
