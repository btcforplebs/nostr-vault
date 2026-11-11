import Foundation

/// Addresses for the in-app browser: which links open in it, and how a
/// `<npub>.fips` site maps onto the mesh door.
///
/// A `.fips` address names a node by its npub; nothing is looked up. The
/// browser shows such a page under `nvfips://<npub>/<path>`, its own scheme,
/// so root-relative links resolve against the site and never against the
/// loopback door (whose path holds a secret token). A `.fips` URL must never
/// reach DNS: there it would only leak the npub and load whatever a resolver
/// answered (the `FipsHostBlocker` promise). Android: fips/FipsUrl.kt.
enum FipsURL {
    /// The browser's scheme for mesh pages.
    static let scheme = "nvfips"

    /// The mesh door serves port 80 only (fips-v2 `MESH_PORT`).
    static let meshPort = 80

    /// Any host under `.fips`, npub or not (case-insensitive).
    static func isFipsHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased(), !host.isEmpty else { return false }
        let bare = host.hasSuffix(".") ? String(host.dropLast()) : host
        return bare == "fips" || bare.hasSuffix(".fips")
    }

    /// The npub a `.fips` host names: `<npub>.fips` only. Hosts-file style
    /// names (`site.fips`) are not supported.
    static func npub(inFipsHost host: String?) -> String? {
        guard var host = host?.lowercased() else { return nil }
        if host.hasSuffix(".") { host.removeLast() }
        guard host.hasSuffix(".fips") else { return nil }
        return HomeVaultLogic.meshNpub(fromEntry: "fipsmesh://\(host.dropLast(5))/")
    }

    // MARK: - Site ↔ viewer

    /// `http://<npub>.fips/a?b#c` → `nvfips://<npub>/a?b#c`. Nil for a host
    /// that is not an npub, or a port other than 80 (the door has no other).
    /// https is read as http: the mesh session is already end-to-end
    /// encrypted to that npub, and the door speaks plain HTTP.
    static func viewerURL(forSite url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let npub = npub(inFipsHost: url.host)
        else { return nil }
        if let port = url.port, port != meshPort { return nil }
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        parts.scheme = Self.scheme
        parts.host = npub
        parts.port = nil
        parts.user = nil
        parts.password = nil
        if parts.percentEncodedPath.isEmpty { parts.percentEncodedPath = "/" }
        return parts.url
    }

    /// The npub a viewer URL reads from, or nil.
    static func npub(inViewer url: URL) -> String? {
        guard url.scheme?.lowercased() == scheme, let host = url.host else { return nil }
        return HomeVaultLogic.meshNpub(fromEntry: "fipsmesh://\(host.lowercased())/")
    }

    /// `nvfips://<npub>/a?b#c` → `http://<npub>.fips/a?b#c`: what the address
    /// bar shows and Share hands out.
    static func siteURL(forViewer url: URL) -> URL? {
        guard let npub = npub(inViewer: url),
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        parts.scheme = "http"
        parts.host = "\(npub).fips"
        parts.port = nil
        if parts.percentEncodedPath.isEmpty { parts.percentEncodedPath = "/" }
        return parts.url
    }

    /// The loopback door request for a viewer URL: `<base><path>?<query>`,
    /// where `base` is the engine's `http://127.0.0.1:<port>/<token>`. The
    /// fragment stays in the page. Nil when the base or the URL is not one.
    static func ingressURL(base: URL, forViewer url: URL) -> URL? {
        guard npub(inViewer: url) != nil,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              base.scheme == "http", let baseHost = base.host, baseHost == "127.0.0.1" || baseHost == "::1"
        else { return nil }
        var root = base.absoluteString
        while root.hasSuffix("/") { root.removeLast() }
        var path = parts.percentEncodedPath
        if !path.hasPrefix("/") { path = "/" + path }
        let query = parts.percentEncodedQuery.map { "?\($0)" } ?? ""
        return URL(string: root + path + query)
    }

    /// The `Host` the site gets: its own name, as a daemon's browser would send.
    static func hostHeader(forViewer url: URL) -> String? {
        npub(inViewer: url).map { "\($0).fips" }
    }

    /// A redirect's `Location`, made safe for the viewer: an absolute
    /// `.fips` URL becomes its viewer URL, a relative one resolves against
    /// the page (so it stays on the site), and any other absolute URL is kept
    /// (it leaves the mesh, which the navigation rules then handle). Nil for
    /// a `.fips` target the door can't serve, so it never reaches DNS.
    static func redirectTarget(_ location: String, from viewer: URL) -> URL? {
        guard let resolved = URL(string: location, relativeTo: viewer)?.absoluteURL else { return nil }
        if resolved.scheme?.lowercased() == scheme { return npub(inViewer: resolved) != nil ? resolved : nil }
        if isFipsHost(resolved.host) { return viewerURL(forSite: resolved) }
        return resolved
    }

    // MARK: - Link taps

    enum Route: Equatable {
        /// A `.fips` site: the browser, over the mesh.
        case mesh(URL)
        /// An http(s) page on the internet: the browser.
        case web(URL)
        /// A `.fips` address the browser can't open (not an npub, or another
        /// port): refused, never sent to DNS or the system browser.
        case refusedFips
        /// Everything else (mailto:, lightning:, …), or the toggle is off: the system.
        case system
    }

    /// Where a tapped link goes. `inApp` is "Open links in Nostr Vault".
    /// Even with it off, a `.fips` link never goes to the system browser:
    /// that would resolve the npub through DNS.
    static func route(_ url: URL, inApp: Bool) -> Route {
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == Self.scheme {
            return npub(inViewer: url) != nil ? .mesh(url) : .refusedFips
        }
        guard scheme == "http" || scheme == "https" else { return .system }
        if isFipsHost(url.host) {
            return viewerURL(forSite: url).map(Route.mesh) ?? .refusedFips
        }
        return inApp ? .web(url) : .system
    }

    // MARK: - Inside the browser

    enum Navigation: Equatable {
        case allow
        /// A `.fips` site: load its mesh page instead.
        case load(URL)
        /// A `.fips` address the door can't serve, or a top-level `data:`
        /// page: refused, never sent to DNS.
        case refuse
        /// Another scheme (`nostr:`, `lightning:`, `mailto:`…): back to the app.
        case external
        /// An internet page asked for from a mesh page: only after the
        /// reader confirms it, because there the site sees this device's IP.
        case leaveMesh(URL)
    }

    /// Where a load inside the browser may go. A `.fips` URL never reaches
    /// the network: top-level it becomes its mesh page, in a frame or as a
    /// websocket it is refused (the door is HTTP on port 80 only). From a
    /// mesh page (`fromMesh`) nothing goes to the internet by itself: a
    /// frame is refused, a page waits for the reader (`.leaveMesh`).
    static func navigation(to url: URL, isMainFrame: Bool, fromMesh: Bool) -> Navigation {
        let scheme = url.scheme?.lowercased() ?? ""
        switch scheme {
        case Self.scheme:
            return npub(inViewer: url) != nil ? .allow : .refuse
        case "http", "https", "ws", "wss":
            guard isFipsHost(url.host) else {
                guard fromMesh else { return .allow }
                return isMainFrame && scheme.hasPrefix("http") ? .leaveMesh(url) : .refuse
            }
            guard isMainFrame, scheme.hasPrefix("http"), let viewer = viewerURL(forSite: url) else { return .refuse }
            return .load(viewer)
        case leaveScheme:
            // A mesh page's link off the mesh, as the page script hands it over.
            guard isMainFrame, let target = leaveTarget(url) else { return .refuse }
            if isFipsHost(target.host) { return viewerURL(forSite: target).map(Navigation.load) ?? .refuse }
            return .leaveMesh(target)
        case "about":
            return .allow
        case "data", "blob":
            return isMainFrame ? .refuse : .allow
        default:
            return .external
        }
    }

    /// A mesh page's off-mesh link, as the browser's page script rewrites
    /// it the moment it is clicked: `nvleave:<percent-encoded http(s) URL>`.
    /// WebKit opens a connection to an http(s) link's host as soon as it is
    /// clicked, before the app is asked; to this scheme it opens none.
    static let leaveScheme = "nvleave"

    static func leaveTarget(_ url: URL) -> URL? {
        guard url.scheme?.lowercased() == leaveScheme else { return nil }
        let encoded = url.absoluteString.dropFirst(leaveScheme.count + 1)
        guard let text = String(encoded).removingPercentEncoding, let target = URL(string: text),
              let s = target.scheme?.lowercased(), s == "http" || s == "https", target.host != nil else { return nil }
        return target
    }

    // MARK: - Content rules

    /// WebKit content-rule `url-filter`s that block every http(s)/ws(s) load
    /// to a `.fips` host, with or without a trailing dot or a port. WebKit's
    /// regex subset has no `|` or `{}`, so each shape is its own filter.
    /// Websockets never reach `decidePolicyFor`: these are their only gate.
    static let fipsBlockFilters: [String] = ["https?", "wss?"].flatMap { s in [
        "^\(s)://[^/]*\\.fips[:/]", "^\(s)://[^/]*\\.fips$",
        "^\(s)://[^/]*\\.fips\\.[:/]", "^\(s)://[^/]*\\.fips\\.$",
    ] }

    /// On a mesh page (top URL `nvfips:`), every internet load is blocked:
    /// images, fetch, websockets, frames. The mesh page's promise is that the
    /// site never sees this device's IP, and nothing may break it without a tap.
    static let offMeshFilters = ["^https?://", "^wss?://"]
    static let meshTopURL = "^\(scheme):"

    /// The browser's content rules, as WebKit's JSON.
    static var browserRulesJSON: String {
        var rules: [[String: Any]] = fipsBlockFilters.map {
            ["trigger": ["url-filter": $0], "action": ["type": "block"]]
        }
        rules += offMeshFilters.map {
            ["trigger": ["url-filter": $0, "if-top-url": [meshTopURL]], "action": ["type": "block"]]
        }
        let data = try! JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    /// What the user typed in the address bar, as a URL to open: a bare
    /// `<npub>.fips/...` or `example.com` gets a scheme. Nil for blank input.
    static func typedURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }
        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
           ["http", "https", Self.scheme].contains(scheme), url.host != nil {
            return url
        }
        let hostPart = trimmed.split(separator: "/", maxSplits: 1).first.map(String.init) ?? trimmed
        let prefix = isFipsHost(hostPart.split(separator: ":").first.map(String.init)) ? "http://" : "https://"
        guard let url = URL(string: prefix + trimmed), url.host != nil else { return nil }
        return url
    }

    // MARK: - Pages the browser writes itself

    /// Text safe inside HTML element content and quoted attributes.
    static func htmlEscaped(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(character)
            }
        }
        return out
    }
}
