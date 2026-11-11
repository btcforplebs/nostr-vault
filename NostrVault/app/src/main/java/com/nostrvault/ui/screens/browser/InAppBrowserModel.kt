package com.nostrvault.ui.screens.browser

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Color
import android.os.Handler
import android.os.Looper
import android.webkit.CookieManager
import android.webkit.PermissionRequest
import android.webkit.WebChromeClient
import android.webkit.WebSettings
import android.webkit.WebStorage
import android.webkit.WebView
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import com.nostrvault.fips.FipsUrl
import com.nostrvault.fips.MeshPage
import com.nostrvault.fips.MeshSiteFetcher
import com.nostrvault.fips.MeshSiteIngress

/**
 * One in-app browser: its WebView and what the chrome shows (iOS/Mac: InAppBrowserModel.swift).
 *
 * The WebView has no JavaScript interface (no bridge into the app), no file or content access, no
 * permissions, [MeshGuardScript] in every frame, and [FipsWebViewClient] deciding every load. Cookies, storage
 * and cache are wiped when it closes.
 */
@SuppressLint("SetJavaScriptEnabled")
class InAppBrowserModel(context: Context, door: (String) -> MeshSiteIngress) {
    enum class Kind { Mesh, Web }

    var address by mutableStateOf("")
        private set
    var title by mutableStateOf("")
        private set
    var kind by mutableStateOf(Kind.Web)
        private set
    var isLoading by mutableStateOf(false)
        private set
    var progress by mutableFloatStateOf(0f)
        private set
    var canGoBack by mutableStateOf(false)
        private set
    var canGoForward by mutableStateOf(false)
        private set
    /** "Waiting for the mesh…" while a mesh page waits for its tree parent. */
    var meshStatus by mutableStateOf<String?>(null)
        private set
    /** An internet page the reader tapped from a mesh page, waiting on their yes. */
    var leavingMesh by mutableStateOf<String?>(null)

    /** Links the browser does not open (`nostr:`, `mailto:`…), handed back to the app. */
    var onExternal: (String) -> Unit = {}

    private val main = Handler(Looper.getMainLooper())
    private val fetcher = MeshSiteFetcher(door).apply { onStatus = { s -> main.post { meshStatus = s } } }
    private val guardInstalled = WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT) && MeshProxy.isSupported
    private val client = FipsWebViewClient(fetcher, guardInstalled)

    val webView: WebView = WebView(context).apply {
        setBackgroundColor(Color.BLACK)
        settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            allowFileAccess = false
            allowContentAccess = false
            setGeolocationEnabled(false)
            mediaPlaybackRequiresUserGesture = true
            mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
            // target=_blank and window.open load here: one page at a time.
            setSupportMultipleWindows(false)
            javaScriptCanOpenWindowsAutomatically = false
            builtInZoomControls = true
            displayZoomControls = false
            loadWithOverviewMode = true
            useWideViewPort = true
        }
        CookieManager.getInstance().setAcceptThirdPartyCookies(this, false)
        webViewClient = client
        webChromeClient = object : WebChromeClient() {
            override fun onProgressChanged(view: WebView, newProgress: Int) {
                this@InAppBrowserModel.progress = newProgress / 100f
                this@InAppBrowserModel.isLoading = newProgress < 100
                refreshNav()
            }
            override fun onReceivedTitle(view: WebView, t: String?) { this@InAppBrowserModel.title = t.orEmpty() }
            // Camera, microphone, MIDI, protected media: never from a page in here.
            override fun onPermissionRequest(request: PermissionRequest) = request.deny()
        }
        if (guardInstalled) WebViewCompat.addDocumentStartJavaScript(this, MeshGuardScript.SOURCE, setOf("*"))
    }

    init {
        client.onExternal = { onExternal(it) }
        client.onLeaveMesh = { leavingMesh = it }
        client.onPage = { url -> pageChanged(url) }
        client.onFinished = { isLoading = false; refreshNav() }
    }

    private fun refreshNav() {
        canGoBack = webView.canGoBack()
        canGoForward = webView.canGoForward()
    }

    private fun pageChanged(url: String) {
        refreshNav()
        if (url.startsWith("about:") || url.startsWith("data:")) return
        kind = if (FipsUrl.meshNpub(url) != null) Kind.Mesh else Kind.Web
        address = url
    }

    /** Opens [url] here: a `.fips` site over the mesh, an http(s) page on the web. */
    fun open(url: String) {
        when (val route = FipsUrl.route(url, inApp = true)) {
            is FipsUrl.Route.Mesh -> {
                kind = Kind.Mesh; address = route.url
                webView.loadUrl(route.url)
            }
            is FipsUrl.Route.Web -> {
                kind = Kind.Web; address = route.url
                // The reader asked for it: allowed even from a mesh page.
                client.allowedOnce = route.url
                webView.loadUrl(route.url)
            }
            FipsUrl.Route.RefusedFips -> {
                kind = Kind.Mesh; address = url
                webView.loadDataWithBaseURL(null, MeshPage.html(MeshPage.Refused, url), "text/html", "utf-8", null)
            }
            FipsUrl.Route.System -> onExternal(url)
        }
    }

    /** The address bar's Go. False for text that is not an address. */
    fun submit(text: String): Boolean {
        val url = FipsUrl.typedUrl(text) ?: return false
        open(url)
        return true
    }

    /** The reader said yes to leaving the mesh for [leavingMesh]. */
    fun leaveMesh() {
        val url = leavingMesh ?: return
        leavingMesh = null
        open(url)
    }

    fun reloadOrStop() = if (isLoading) webView.stopLoading() else webView.reload()

    fun goBack() = step(-1)
    fun goForward() = step(1)

    /** Back and forward go where the reader already was, even off the mesh. */
    private fun step(by: Int) {
        val list = webView.copyBackForwardList()
        val item = list.getItemAtIndex(list.currentIndex + by) ?: return
        client.allowedOnce = item.url
        webView.goBackOrForward(by)
    }

    /** What Share hands out. */
    val shareUrl: String? get() = address.takeIf { it.isNotEmpty() }

    /** The page for the default browser: web pages only. A mesh page there would resolve its npub through DNS. */
    val systemBrowserUrl: String?
        get() = address.takeIf { kind == Kind.Web && FipsUrl.route(it, inApp = true) is FipsUrl.Route.Web }

    /** The browser is closing: stop loads, and keep nothing it stored. */
    fun close() {
        webView.stopLoading()
        webView.loadUrl("about:blank")
        webView.clearHistory()
        webView.clearCache(true)
        webView.clearFormData()
        CookieManager.getInstance().removeAllCookies(null)
        CookieManager.getInstance().flush()
        WebStorage.getInstance().deleteAllData()
        webView.destroy()
        // The override is WebView-wide: nothing else in the app keeps the mesh page's dead end.
        MeshProxy.set(mesh = false, wait = false)
    }
}
