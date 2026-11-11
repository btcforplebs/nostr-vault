package com.nostrvault.fips

import java.net.URI
import java.net.URLDecoder

/**
 * Addresses for the in-app browser: which links open in it, and how a `<npub>.fips` site maps onto the mesh
 * door (iOS/Mac: Models/FipsURL.swift).
 *
 * A `.fips` address names a node by its npub; nothing is looked up. Android keeps the site's real origin,
 * `http://<npub>.fips/…`, and answers every request to it from the WebView's `shouldInterceptRequest`
 * through `NvFipsIngress` (the door), so root-relative links resolve against the site. iOS shows the same
 * page under its own `nvfips://` scheme instead, because WKWebView can't intercept http. A `.fips` URL must
 * never reach DNS: there it would only leak the npub and load whatever a resolver answered (FipsHostGuard).
 */
object FipsUrl {
    /** The mesh door serves port 80 only (fips-v2 `MESH_PORT`). */
    const val MESH_PORT = 80

    private val npubRegex = Regex("^npub1[02-9ac-hj-np-z]{58}$")

    /** Any host under `.fips`, npub or not (case-insensitive, trailing dot too). */
    fun isFipsHost(host: String?): Boolean {
        val h = host?.lowercase()?.removeSuffix(".") ?: return false
        return h == "fips" || h.endsWith(".fips")
    }

    /** The npub a `.fips` host names: `<npub>.fips` only. Hosts-file names (`site.fips`) are not supported. */
    fun npubInFipsHost(host: String?): String? {
        val h = host?.lowercase()?.removeSuffix(".") ?: return null
        if (!h.endsWith(".fips")) return null
        return h.removeSuffix(".fips").takeIf { npubRegex.matches(it) }
    }

    private fun parse(url: String): URI? = try { URI(url.trim()) } catch (_: Exception) { null }

    private fun schemeOf(url: String): String =
        parse(url)?.scheme?.lowercase() ?: url.substringBefore(':', "").lowercase()

    /** The host of an absolute hierarchical URL, without IPv6 brackets. Null for `mailto:`, `data:`, junk. */
    fun hostOf(url: String): String? = parse(url)?.takeIf { !it.isOpaque }?.let { it.host ?: it.rawAuthority?.substringAfterLast('@')?.substringBefore(':') }

    /**
     * `http(s)://<npub>.fips[:80]/a?b#c` as the browser loads it: `http://<npub>.fips/a?b#c`. Null for a host
     * that is not an npub, or a port other than 80 (the door has no other). https is read as http: the mesh
     * session is already end-to-end encrypted to that npub, and the door speaks plain HTTP. User info is dropped.
     */
    fun siteUrl(url: String): String? {
        val uri = parse(url)?.takeIf { !it.isOpaque } ?: return null
        val scheme = uri.scheme?.lowercase()
        if (scheme != "http" && scheme != "https") return null
        val npub = npubInFipsHost(hostOf(url)) ?: return null
        if (uri.port != -1 && uri.port != MESH_PORT) return null
        val path = uri.rawPath?.takeIf { it.isNotEmpty() } ?: "/"
        val query = uri.rawQuery?.let { "?$it" } ?: ""
        val fragment = uri.rawFragment?.let { "#$it" } ?: ""
        return "http://$npub.fips$path$query$fragment"
    }

    /** The npub a page URL reads from over the mesh, or null for anything else. */
    fun meshNpub(url: String?): String? = url?.let { siteUrl(it) }?.let { npubInFipsHost(hostOf(it)) }

    /**
     * The loopback door request for a site URL: `<base><path>?<query>`, where `base` is the engine's
     * `http://127.0.0.1:<port>/<token>`. The fragment stays in the page. Null when either is not one.
     */
    fun doorUrl(base: String, site: String): String? {
        val b = parse(base) ?: return null
        if (b.scheme?.lowercase() != "http" || (b.host != "127.0.0.1" && b.host != "[::1]" && b.host != "::1")) return null
        val s = parse(siteUrl(site) ?: return null) ?: return null
        val root = base.trimEnd('/')
        val path = s.rawPath?.takeIf { it.isNotEmpty() } ?: "/"
        val query = s.rawQuery?.let { "?$it" } ?: ""
        return root + path + query
    }

    /** The `Host` the site gets: its own name, as a browser on a FIPS daemon sends it. */
    fun hostHeader(site: String): String? = meshNpub(site)?.let { "$it.fips" }

    /**
     * A mesh reply's `Location`, made safe: a relative one resolves against the page (so it stays on the site),
     * an absolute `.fips` one becomes its site URL, any other absolute URL is kept (it leaves the mesh, which the
     * navigation rules then handle). Null for a `.fips` target the door can't serve, so it never reaches DNS.
     */
    fun redirectTarget(location: String, from: String): String? {
        val resolved = try { URI(from).resolve(location.trim()) } catch (_: Exception) { return null }
        val text = resolved.toString()
        val scheme = resolved.scheme?.lowercase() ?: return null
        if (isFipsHost(hostOf(text))) return siteUrl(text)
        return text.takeIf { scheme == "http" || scheme == "https" }
    }

    // Link taps

    sealed interface Route {
        /** A `.fips` site: the browser, over the mesh. */
        data class Mesh(val url: String) : Route
        /** An http(s) page on the internet: the browser. */
        data class Web(val url: String) : Route
        /** A `.fips` address the browser can't open (not an npub, another port): refused, never sent to DNS. */
        data object RefusedFips : Route
        /** Everything else (mailto:, lightning:, nostr:…), or the toggle is off: the system. */
        data object System : Route
    }

    /**
     * Where a tapped link goes. [inApp] is "Open links in Nostr Vault". Even with it off, a `.fips` link never
     * goes to the system browser: that would resolve the npub through DNS.
     */
    fun route(url: String, inApp: Boolean): Route {
        val scheme = schemeOf(url)
        if (scheme != "http" && scheme != "https") return Route.System
        if (isFipsHost(hostOf(url))) return siteUrl(url)?.let { Route.Mesh(it) } ?: Route.RefusedFips
        return if (inApp) Route.Web(url.trim()) else Route.System
    }

    // Inside the browser

    sealed interface Navigation {
        data object Allow : Navigation
        /** A `.fips` site in another shape (https, :80, user info): load its plain site URL instead. */
        data class Load(val url: String) : Navigation
        /** A `.fips` address the door can't serve, or a top-level `data:`/`blob:` page: refused, never sent to DNS. */
        data object Refuse : Navigation
        /** Another scheme (`nostr:`, `lightning:`, `mailto:`…): back to the app, if the reader tapped it. */
        data object External : Navigation
        /** An internet page asked for from a mesh page: only after the reader confirms it (the site sees the IP). */
        data class LeaveMesh(val url: String) : Navigation
    }

    /**
     * Where a navigation inside the browser may go (WebViewClient.shouldOverrideUrlLoading). A `.fips` URL never
     * reaches the network: top-level it is served over the mesh, in a frame or as a websocket it is refused (the
     * door is HTTP on port 80 only). From a mesh page ([fromMesh]) nothing goes to the internet by itself: a frame
     * is refused, a page waits for the reader ([Navigation.LeaveMesh]).
     */
    fun navigation(url: String, isMainFrame: Boolean, fromMesh: Boolean): Navigation {
        when (val scheme = schemeOf(url)) {
            "http", "https", "ws", "wss" -> {
                if (!isFipsHost(hostOf(url))) {
                    if (!fromMesh) return Navigation.Allow
                    return if (isMainFrame && scheme.startsWith("http")) Navigation.LeaveMesh(url) else Navigation.Refuse
                }
                if (!isMainFrame || !scheme.startsWith("http")) return Navigation.Refuse
                val site = siteUrl(url) ?: return Navigation.Refuse
                return if (site == url) Navigation.Allow else Navigation.Load(site)
            }
            LEAVE_SCHEME -> {
                val target = leaveTarget(url)
                if (!isMainFrame || target == null) return Navigation.Refuse
                if (isFipsHost(hostOf(target))) return siteUrl(target)?.let { Navigation.Load(it) } ?: Navigation.Refuse
                return Navigation.LeaveMesh(target)
            }
            "about" -> return Navigation.Allow
            "data", "blob" -> return if (isMainFrame) Navigation.Refuse else Navigation.Allow
            "javascript", "file", "content", "intent", "" -> return Navigation.Refuse
            else -> return Navigation.External
        }
    }

    /**
     * A mesh page's off-mesh link, as the page script hands it over the moment it is clicked:
     * `nvleave:<percent-encoded http(s) URL>`. A browser may open a connection to a clicked http(s) link's host
     * before the app is asked; to this scheme it opens none.
     */
    const val LEAVE_SCHEME = "nvleave"

    fun leaveTarget(url: String): String? {
        if (schemeOf(url) != LEAVE_SCHEME) return null
        val text = try { URLDecoder.decode(url.trim().substring(LEAVE_SCHEME.length + 1).replace("+", "%2B"), "UTF-8") } catch (_: Exception) { return null }
        val target = parse(text) ?: return null
        val s = target.scheme?.lowercase()
        if ((s != "http" && s != "https") || hostOf(text).isNullOrEmpty()) return null
        return text
    }

    // Every request the page makes (WebViewClient.shouldInterceptRequest)

    sealed interface Request {
        /** Read it through the door to [npub]'s port 80. */
        data class Mesh(val npub: String, val site: String) : Request
        /** Answer with nothing: it must not reach the network. */
        data object Block : Request
        /** The internet, as any browser. */
        data object Pass : Request
    }

    /**
     * What one request may do. [meshPage] is the npub of the mesh page on screen, or null on a web page.
     * - A `.fips` request never passes: a page's own site (or a top-level load) reads over the mesh; any other
     *   `.fips` request, a web page's included, is blocked, so a web page can't make the engine dial an npub.
     * - On a mesh page nothing reaches an internet host: every subresource is blocked, and a top-level load only
     *   passes when the app asked for it ([allowedTopLevel]: the reader typed it or confirmed leaving the mesh).
     */
    fun request(url: String, isMainFrame: Boolean, meshPage: String?, allowedTopLevel: Boolean): Request {
        val scheme = schemeOf(url)
        val host = hostOf(url)
        if (scheme == "http" || scheme == "https" || scheme == "ws" || scheme == "wss") {
            if (isFipsHost(host)) {
                val npub = npubInFipsHost(host)
                val site = siteUrl(url)
                if (npub == null || site == null) return Request.Block
                return if (isMainFrame || npub == meshPage) Request.Mesh(npub, site) else Request.Block
            }
            if (meshPage == null) return Request.Pass
            return if (isMainFrame && allowedTopLevel) Request.Pass else Request.Block
        }
        // data:, blob: and the like never hit the network; anything else stays off a mesh page.
        return if (meshPage == null || scheme == "data" || scheme == "blob") Request.Pass else Request.Block
    }

    /**
     * The policy every mesh page is served with, on top of the site's own: it may load from its own site only
     * (no other host, no websocket: a `ws://<npub>.fips` would go to DNS, as WebView never intercepts sockets),
     * and post forms nowhere. Inline script and style stay allowed: the policy is about where bytes go.
     */
    fun meshPolicy(npub: String): String {
        val self = "http://$npub.fips"
        return "default-src $self data: blob: 'unsafe-inline' 'unsafe-eval'; " +
            "connect-src $self; form-action $self; frame-src $self; worker-src $self blob:; " +
            "base-uri $self; object-src 'none'"
    }

    /** The site's response headers that the browser keeps. */
    private val droppedHeaders = setOf(
        "content-length", "content-encoding", "transfer-encoding", "connection", "keep-alive",
        // A site over the mesh can't set what WebView would keep after the page: HSTS, Alt-Svc, cookies.
        "strict-transport-security", "alt-svc", "set-cookie", "set-cookie2",
        // Link: preconnect / preload hints to other hosts, which no rule here could stop.
        "link", "refresh", "x-dns-prefetch-control", "content-type",
    )

    /**
     * A mesh reply's headers for the WebView: the site's own minus [droppedHeaders], with [meshPolicy] added to
     * any policy the site sent (two policies both hold) and DNS prefetch off.
     */
    fun meshHeaders(npub: String, site: Map<String, String>): Map<String, String> {
        val out = LinkedHashMap<String, String>()
        var sitePolicy: String? = null
        for ((k, v) in site) {
            val key = k.lowercase()
            if (key in droppedHeaders) continue
            if (key == "content-security-policy") { sitePolicy = v; continue }
            out[k] = v
        }
        out["Content-Security-Policy"] = listOfNotNull(sitePolicy, meshPolicy(npub)).joinToString(", ")
        out["X-DNS-Prefetch-Control"] = "off"
        out["Cache-Control"] = "no-store"
        return out
    }

    /**
     * What the reader typed in the address bar, as a URL to open: a bare `<npub>.fips/…` gets http, `example.com`
     * gets https. Null for blank input or text with a space.
     */
    fun typedUrl(text: String): String? {
        val t = text.trim()
        if (t.isEmpty() || t.contains(' ')) return null
        val scheme = schemeOf(t)
        if ((scheme == "http" || scheme == "https") && t.contains("://") && !hostOf(t).isNullOrEmpty()) return t
        val hostPart = t.substringBefore('/').substringBefore(':')
        val url = (if (isFipsHost(hostPart)) "http://" else "https://") + t
        return url.takeIf { !hostOf(it).isNullOrEmpty() }
    }

    /** Text safe inside HTML element content and quoted attributes. */
    fun htmlEscaped(text: String): String = buildString(text.length) {
        for (c in text) when (c) {
            '&' -> append("&amp;")
            '<' -> append("&lt;")
            '>' -> append("&gt;")
            '"' -> append("&quot;")
            '\'' -> append("&#39;")
            else -> append(c)
        }
    }
}
