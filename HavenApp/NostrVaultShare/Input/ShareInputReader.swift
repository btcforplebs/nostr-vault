import Foundation
import UniformTypeIdentifiers

// MARK: - Share input
//
// NSExtensionItem attachments → NVShareInput for the classifier, plus the
// providers whose files an action may copy into the queue. Reads strings and
// small property lists only; files stay providers until an action that needs
// them is picked, and are then copied, never loaded into memory.

struct ShareInputReader {
    struct Result {
        var input = NVShareInput()
        /// A file provider and the type it offers, in share order.
        var files: [(provider: NSItemProvider, type: UTType)] = []
        /// Set when Safari's preprocessing JS ran (selection, JSON-LD types).
        var fromSafariPage = false
        var ldJSON: String?
    }

    /// File types the portal reads besides photos and videos.
    static let fileTypes: [UTType] = [.pdf, .calendarEvent, UTType("com.apple.ical.ics") ?? .calendarEvent, .vCard]

    static func read(_ items: [NSExtensionItem]) async -> Result {
        var result = Result()
        for provider in items.flatMap({ $0.attachments ?? [] }) {
            if provider.hasItemConformingToTypeIdentifier(UTType.propertyList.identifier),
               let page = await loadPage(provider) {
                result.fromSafariPage = true
                apply(page, to: &result)
                continue
            }
            if let media = ShareModel.mediaType(of: provider) {
                result.files.append((provider, media))
                result.input.files.append(.init(mime: media.preferredMIMEType ?? "application/octet-stream",
                                                name: provider.suggestedName ?? ""))
                continue
            }
            if let fileType = fileType(of: provider) {
                result.files.append((provider, fileType))
                let ext = fileType.preferredFilenameExtension.map { ".\($0)" } ?? ""
                let name = provider.suggestedName.map { ($0 as NSString).pathExtension.isEmpty ? $0 + ext : $0 } ?? "shared\(ext)"
                result.input.files.append(.init(mime: fileType.preferredMIMEType ?? "application/octet-stream", name: name))
                continue
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
               !provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
               let url = await loadURL(provider), result.input.url == nil {
                result.input.url = NVShareLimits.cap(url, NVShareLimits.url)
                continue
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
               let text = await loadString(provider) {
                let joined = [result.input.text, text].compactMap { $0 }.joined(separator: "\n")
                result.input.text = NVShareLimits.cap(joined, NVShareLimits.text)
            }
        }
        // Chrome and others send the page title as text next to the URL.
        if result.input.title == nil, result.input.url != nil, let text = result.input.text,
           !text.isEmpty, text.count <= NVShareLimits.title, !text.contains("://") {
            result.input.title = text
        }
        return result
    }

    private static func fileType(of provider: NSItemProvider) -> UTType? {
        let types = provider.registeredTypeIdentifiers.compactMap(UTType.init)
        for wanted in fileTypes {
            if let match = types.first(where: { $0.conforms(to: wanted) }) { return match }
        }
        return nil
    }

    // MARK: Safari page

    /// What SharePreprocess.js returned. Every value is the page's, so each
    /// is type-checked and capped.
    struct Page {
        var url: String?
        var title: String?
        var selection: String?
        var ldTypes: [String] = []
        var ldJSON: String?
    }

    static func page(from results: [String: Any]) -> Page {
        func str(_ key: String, _ cap: Int) -> String? {
            guard let s = results[key] as? String, !s.isEmpty else { return nil }
            return NVShareLimits.cap(s, cap)
        }
        let url = str("url", NVShareLimits.url)
        // A page may name any canonical URL. Only take it on the page's own
        // host, or one page could make the highlight's source tag name
        // another site (Tron, PR 1610).
        let canonical = str("canonical", NVShareLimits.url).flatMap { c in
            NVShareClassifier.sameHost(c, url) ? c : nil
        }
        let types = (results["ld_types"] as? [Any] ?? []).compactMap { $0 as? String }
        return Page(
            url: [canonical, url].compactMap { $0 }.first { isWeb($0) },
            title: str("title", NVShareLimits.title),
            selection: str("selection", NVShareLimits.selection),
            ldTypes: Array(types.prefix(NVShareLimits.ldTypes)).compactMap { NVShareLimits.cap($0, NVShareLimits.ldType) },
            ldJSON: str("ld_json", 200_000)
        )
    }

    private static func apply(_ page: Page, to result: inout Result) {
        if let url = page.url { result.input.url = url }
        if let title = page.title { result.input.title = title }
        if let selection = page.selection { result.input.selection = selection }
        result.input.ldTypes = page.ldTypes
        result.ldJSON = page.ldJSON
    }

    private static func isWeb(_ s: String) -> Bool {
        let lower = s.lowercased()
        return lower.hasPrefix("https://") || lower.hasPrefix("http://")
    }

    // MARK: Loading

    private static func loadPage(_ provider: NSItemProvider) async -> Page? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.propertyList.identifier) { item, _ in
                let dict = item as? NSDictionary
                let results = dict?[NSExtensionJavaScriptPreprocessingResultsKey] as? [String: Any]
                continuation.resume(returning: results.map(page(from:)))
            }
        }
    }

    private static func loadURL(_ provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.url.identifier) { item, _ in
                let url = (item as? URL) ?? (item as? NSURL as URL?)
                    ?? (item as? String).flatMap(URL.init(string:))
                continuation.resume(returning: url?.absoluteString)
            }
        }
    }

    private static func loadString(_ provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) { item, _ in
                var text = item as? String
                if text == nil, let data = item as? Data, data.count <= NVShareLimits.text * 4 {
                    text = String(data: data, encoding: .utf8)
                }
                continuation.resume(returning: NVShareLimits.cap(text, NVShareLimits.text))
            }
        }
    }

    /// Copies one file provider into a temporary file the caller owns (the
    /// provided file is deleted as soon as the load handler returns).
    static func copyFile(_ provider: NSItemProvider, type: UTType, to folder: URL) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                guard let url else { continuation.resume(returning: nil); return }
                let target = folder.appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension(url.pathExtension)
                let ok = (try? FileManager.default.copyItem(at: url, to: target)) != nil
                continuation.resume(returning: ok ? target : nil)
            }
        }
    }
}
