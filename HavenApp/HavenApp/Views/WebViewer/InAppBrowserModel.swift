import Foundation
import WebKit

/// One in-app browser: its web view and what the chrome shows.
///
/// The web view has its own non-persistent data store (nothing it stores
/// outlives it, and it shares nothing with the app), no script message
/// handlers (no bridge into the app), the `.fips` block rules, and the
/// `nvfips://` handler for mesh pages.
@MainActor
final class InAppBrowserModel: ObservableObject {
    enum Kind: Equatable {
        /// Read over the FIPS mesh with the mesh key: the site never sees this device's IP.
        case mesh
        /// The internet: the site sees this device's IP, as in any browser.
        case web
    }

    @Published private(set) var address = ""
    @Published private(set) var title = ""
    @Published private(set) var kind: Kind = .web
    @Published private(set) var isLoading = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    /// "Waiting for the mesh…" while a mesh page waits for its tree parent.
    @Published private(set) var meshStatus: String?
    /// A web page that failed to load, in plain words.
    @Published private(set) var failure: String?
    /// False until the `.fips` block rules are in: no page loads before.
    @Published private(set) var ready = false

    let webView: WKWebView
    /// Links the browser does not open (`nostr:`, `mailto:`…), handed back to the app.
    var onExternal: ((URL) -> Void)?

    private let handler: FipsSchemeHandler
    private let navigation = InAppBrowserNavigation()
    private var observers: [NSKeyValueObservation] = []
    private var pending: URL?

    init(url: URL, ingress: @escaping FipsSchemeHandler.Ingress = FipsSchemeHandler.live) {
        handler = FipsSchemeHandler(ingress: ingress)
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(handler, forURLScheme: FipsURL.scheme)
        config.userContentController.addUserScript(WKUserScript(
            source: InAppBrowserNavigation.rewriteScript, injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        #if os(iOS)
        config.allowsInlineMediaPlayback = true
        #endif
        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = navigation
        webView.uiDelegate = navigation
        webView.allowsBackForwardNavigationGestures = true
        // Dark behind a page that is still loading, not a white flash.
        #if os(iOS)
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        #else
        webView.underPageBackgroundColor = .black
        #endif

        handler.onStatus = { [weak self] status in self?.meshStatus = status }
        navigation.onExternal = { [weak self] url in self?.onExternal?(url) }
        navigation.onFailure = { [weak self] error in
            self?.failure = (error as NSError).localizedDescription
        }
        observe()
        pending = url
        Task { await installRules() }
    }

    private func installRules() async {
        guard let rules = await InAppBrowserNavigation.compileBlockRules() else {
            // Without the rules a page's .fips images would go to DNS: no page at all.
            failure = "The browser couldn't start safely."
            return
        }
        webView.configuration.userContentController.add(rules)
        ready = true
        if let pending {
            self.pending = nil
            open(pending)
        }
    }

    private func observe() {
        observers = [
            webView.observe(\.url, options: [.initial, .new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.urlChanged(view.url) }
            },
            webView.observe(\.title, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.title = view.title ?? "" }
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated {
                    self?.isLoading = view.isLoading
                    if view.isLoading { self?.failure = nil }
                }
            },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.progress = view.estimatedProgress }
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.canGoBack = view.canGoBack }
            },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.canGoForward = view.canGoForward }
            },
        ]
    }

    private func urlChanged(_ url: URL?) {
        guard let url, url.scheme != "about" else { return }
        if let site = FipsURL.siteURL(forViewer: url) {
            kind = .mesh
            address = site.absoluteString
        } else {
            kind = .web
            address = url.absoluteString
        }
    }

    // MARK: - Actions

    /// Opens `url` here: a `.fips` site over the mesh, an http(s) page on the web.
    func open(_ url: URL) {
        guard ready else {
            pending = url
            return
        }
        failure = nil
        switch FipsURL.route(url, inApp: true) {
        case .mesh(let viewer):
            kind = .mesh
            address = FipsURL.siteURL(forViewer: viewer)?.absoluteString ?? address
            webView.load(URLRequest(url: viewer))
        case .web(let page):
            kind = .web
            address = page.absoluteString
            webView.load(URLRequest(url: page))
        case .refusedFips:
            kind = .mesh
            address = url.absoluteString
            webView.loadHTMLString(FipsSchemeHandler.page(.refused, url: url), baseURL: nil)
        case .system:
            onExternal?(url)
        }
    }

    /// The address bar's Go. Returns false for text that is not an address.
    @discardableResult
    func submit(_ text: String) -> Bool {
        guard let url = FipsURL.typedURL(text) else { return false }
        open(url)
        return true
    }

    func reloadOrStop() {
        if isLoading { webView.stopLoading() } else if failure != nil, let url = webView.url ?? URL(string: address) {
            open(url)
        } else {
            webView.reload()
        }
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }

    /// What Share hands out: a mesh page as its `http://<npub>.fips/…` address.
    var shareURL: URL? {
        guard let url = webView.url else { return URL(string: address) }
        return FipsURL.siteURL(forViewer: url) ?? (url.scheme == "about" ? nil : url)
    }

    /// The page for Safari / the default browser: web pages only. A mesh
    /// page there would resolve its npub through DNS.
    var systemBrowserURL: URL? {
        guard kind == .web, let url = shareURL, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }

    /// The browser is closing: stop loads so nothing keeps reading after it.
    func close() {
        webView.stopLoading()
        observers.removeAll()
    }
}
