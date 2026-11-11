package com.nostrvault.ui.screens.browser

import android.graphics.Bitmap
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import com.nostrvault.fips.FipsUrl
import com.nostrvault.fips.MeshPage
import com.nostrvault.fips.MeshSiteFetcher
import java.io.ByteArrayInputStream

/**
 * The in-app browser's rules for where a page may go (iOS/Mac: InAppBrowserNavigation + FipsSchemeHandler).
 *
 * - `http://<npub>.fips/…` keeps its real origin and every request to it, the page and its subresources, is
 *   answered here from the mesh door ([MeshSiteFetcher]). A `.fips` URL never reaches the network.
 * - A mesh page reaches no internet host by itself: its subresources to any other host are answered empty here
 *   (and refused before that by the page's policy, [FipsUrl.meshPolicy]); a top-level load off the mesh is asked
 *   about natively first, and one the app did not ask for (a script, a form, a refresh) is dropped.
 * - Any other scheme (`nostr:`, `lightning:`, `mailto:`…) goes back to the app, only when the reader tapped it.
 */
internal class FipsWebViewClient(
    private val fetcher: MeshSiteFetcher,
    /**
     * False on a WebView too old for [MeshGuardScript] or [MeshProxy]: mesh pages are refused, as WebRTC or
     * preconnects could not be stopped.
     */
    private val guardInstalled: Boolean,
) : WebViewClient() {
    /** A link this view does not open (another scheme), tapped by the reader. */
    var onExternal: (String) -> Unit = {}
    /** The reader tapped a link from a mesh page to the internet: ask first. */
    var onLeaveMesh: (String) -> Unit = {}
    /** The page on screen changed (main thread). */
    var onPage: (String) -> Unit = {}
    var onFinished: (String) -> Unit = {}

    /** The npub of the mesh page on screen, or null on a web page. Read on WebView's intercept threads. */
    @Volatile var meshPage: String? = null
        private set

    /**
     * The one top-level internet load a mesh page may make next: what the reader typed, confirmed, or went back
     * or forward to. Used once.
     */
    @Volatile var allowedOnce: String? = null

    override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
        val url = request.url.toString()
        val isMain = request.isForMainFrame
        val fromMesh = FipsUrl.meshNpub(view.url) != null
        return when (val nav = FipsUrl.navigation(url, isMain, fromMesh)) {
            FipsUrl.Navigation.Allow -> false
            is FipsUrl.Navigation.Load -> { view.loadUrl(nav.url); true }
            FipsUrl.Navigation.Refuse -> {
                if (isMain) showPage(view, MeshPage.Refused, url)
                true
            }
            FipsUrl.Navigation.External -> {
                // Only what the reader tapped: a page can't fire app links by itself.
                if (request.hasGesture()) onExternal(url)
                true
            }
            is FipsUrl.Navigation.LeaveMesh -> {
                // A page can fake a link tap (`a.click()`), so even a tap only asks; script and refresh leaves drop.
                if (isMain && request.hasGesture()) onLeaveMesh(nav.url)
                true
            }
        }
    }

    override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse? {
        val url = request.url.toString()
        val isMain = request.isForMainFrame
        val allowed = isMain && allowedOnce == url
        val decision = FipsUrl.request(url, isMain, meshPage, allowed)
        if (isMain) {
            if (allowed) allowedOnce = null
            when (decision) {
                is FipsUrl.Request.Mesh -> { meshPage = decision.npub; MeshProxy.set(this, mesh = true, wait = true) }
                FipsUrl.Request.Pass -> { meshPage = null; MeshProxy.set(this, mesh = false, wait = true) }
                FipsUrl.Request.Block -> {}
            }
        }
        return when (decision) {
            FipsUrl.Request.Pass -> null
            FipsUrl.Request.Block -> if (isMain && FipsUrl.isFipsHost(FipsUrl.hostOf(url))) html(MeshPage.html(MeshPage.Refused, url)) else blocked()
            is FipsUrl.Request.Mesh -> {
                if (!guardInstalled) return if (isMain) html(MeshPage.html(MeshPage.OldWebView, url)) else blocked()
                when (val reply = fetcher.fetch(decision.npub, decision.site, request.method, isMain,
                    accept = request.requestHeaders["Accept"], range = request.requestHeaders["Range"])) {
                    is MeshSiteFetcher.Reply.Body -> WebResourceResponse(reply.mime, reply.charset, reply.status, reply.reason, reply.headers, reply.stream)
                    is MeshSiteFetcher.Reply.Page -> html(reply.html, reply.status, decision.npub)
                    MeshSiteFetcher.Reply.Fail -> blocked(502)
                }
            }
        }
    }

    override fun onPageStarted(view: WebView, url: String, favicon: Bitmap?) = pageOnScreen(url)

    override fun doUpdateVisitedHistory(view: WebView, url: String, isReload: Boolean) = pageOnScreen(url)

    /** Back/forward from the page cache never asks shouldInterceptRequest: the page on screen is the truth. */
    private fun pageOnScreen(url: String) {
        // Our own pages (data:, about:) keep the mesh rules of the page before them.
        if (!url.startsWith("data:") && !url.startsWith("about:")) {
            meshPage = FipsUrl.meshNpub(url)
            claimProxy()
        }
        onPage(url)
    }

    /** This browser is on screen again: the proxy goes back to what its page needs, whatever another set. */
    fun claimProxy() = MeshProxy.set(this, mesh = meshPage != null, wait = false)

    override fun onPageFinished(view: WebView, url: String) = onFinished(url)

    private fun showPage(view: WebView, page: MeshPage, url: String) =
        view.loadDataWithBaseURL(null, MeshPage.html(page, url), "text/html", "utf-8", null)

    private fun html(body: String, status: Int = 200, npub: String? = null): WebResourceResponse {
        val headers = buildMap {
            put("Cache-Control", "no-store")
            // A page we wrote loads nothing at all.
            put("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'" + (npub?.let { "; form-action 'none'" } ?: ""))
        }
        return WebResourceResponse("text/html", "utf-8", status, reason(status), headers, ByteArrayInputStream(body.toByteArray()))
    }

    private fun blocked(status: Int = 403) =
        WebResourceResponse("text/plain", "utf-8", status, reason(status), mapOf("Cache-Control" to "no-store"), ByteArrayInputStream(ByteArray(0)))

    private fun reason(status: Int) = when (status) {
        200 -> "OK"; 403 -> "Forbidden"; 405 -> "Method Not Allowed"; 502 -> "Bad Gateway"; else -> "Status $status"
    }
}
