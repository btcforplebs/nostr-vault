import WebKit

/// A web page as a PDF, for a private copy of a shared link. Loads the page
/// in an off-screen web view with no website data kept (no cookies from the
/// person's browsing, nothing left behind), waits for it to finish, and
/// prints it. Android twin: shareportal/PagePdfRenderer.kt.
@MainActor
final class PagePDFRenderer: NSObject, WKNavigationDelegate {
    static let timeout: TimeInterval = 30
    /// Wide enough for a desktop-ish layout, narrow enough to read on a phone.
    static let width: CGFloat = 820

    private let webView: WKWebView
    private var continuation: CheckedContinuation<Bool, Never>?

    private override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: Self.width, height: 1200), configuration: config)
        super.init()
        webView.navigationDelegate = self
    }

    /// The page at `url` as PDF bytes, or nil if it didn't load in time.
    static func render(_ url: URL) async -> Data? {
        let renderer = PagePDFRenderer()
        return await renderer.run(url)
    }

    private func run(_ url: URL) async -> Data? {
        let loaded = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            continuation = c
            webView.load(URLRequest(url: url, timeoutInterval: Self.timeout))
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.timeout) { [weak self] in self?.finish(false) }
        }
        guard loaded else { webView.stopLoading(); return nil }
        // A beat for late layout (web fonts, lazy images near the top).
        try? await Task.sleep(nanoseconds: 800_000_000)
        return try? await webView.pdf(configuration: WKPDFConfiguration())
    }

    private func finish(_ ok: Bool) {
        continuation?.resume(returning: ok)
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(true) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(false) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(false) }

    /// "<title>.pdf", else "<host>.pdf", made safe for the vault's file name rules.
    nonisolated static func fileName(title: String?, url: URL) -> String {
        let base = (title?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? url.host ?? "page"
        let cleaned = NVShareQueue.safeName(String(base.prefix(80)))
        return cleaned + ".pdf"
    }
}
