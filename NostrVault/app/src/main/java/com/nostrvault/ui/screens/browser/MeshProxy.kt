package com.nostrvault.ui.screens.browser

import androidx.webkit.ProxyConfig
import androidx.webkit.ProxyController
import androidx.webkit.WebViewFeature
import java.util.Collections
import java.util.WeakHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executor
import java.util.concurrent.TimeUnit

/**
 * While a mesh page is on screen, every connection the WebView itself would open goes to a proxy that is not
 * there (loopback port 9), so none reaches an internet host.
 *
 * Neither `shouldInterceptRequest` nor the page's policy sees a `<link rel=preconnect>`: Chromium opens that TCP
 * connection by itself, and the emulator test (InAppBrowserMeshLeakTest) caught a mesh page doing it. Mesh
 * requests are still answered, because interception comes before the proxy. Implicit bypass rules (localhost,
 * 127.0.0.1) are removed too, so a page can't reach another app's loopback server either. Web pages run with no
 * override.
 *
 * The override is WebView-wide, so one browser decides it at a time: the [owner] whose page is on screen. Another
 * browser can't turn it off underneath a mesh page, and a closed browser ([release]) never touches it again, even
 * from an intercept thread still finishing a request.
 */
internal object MeshProxy {
    val isSupported: Boolean get() = WebViewFeature.isFeatureSupported(WebViewFeature.PROXY_OVERRIDE)

    private const val DEAD_END = "http://127.0.0.1:9"
    private val now = Executor { it.run() }
    private var on: Boolean? = null
    private var owner: Any? = null
    private val released: MutableSet<Any> = Collections.newSetFromMap(WeakHashMap())

    /**
     * [owner]'s page is on screen: mesh rules on ([mesh]) or off. [wait] blocks until the WebView has it, for an
     * intercept thread about to hand the page its first byte; the main thread passes false.
     */
    fun set(owner: Any, mesh: Boolean, wait: Boolean) {
        val done = CountDownLatch(1)
        synchronized(this) {
            if (owner in released) return
            this.owner = owner
            if (!apply(mesh, done)) return
        }
        if (wait) done.await(2, TimeUnit.SECONDS)
    }

    /** [owner] closed: it decides nothing from now on, and the override goes if it was the one that set it. */
    fun release(owner: Any) = synchronized(this) {
        released += owner
        if (this.owner === owner) {
            this.owner = null
            apply(mesh = false, done = null)
        }
    }

    /** False when there was nothing to change. */
    private fun apply(mesh: Boolean, done: CountDownLatch?): Boolean {
        if (!isSupported || on == mesh) return false
        on = mesh
        val controller = ProxyController.getInstance()
        if (mesh) {
            controller.setProxyOverride(
                ProxyConfig.Builder().addProxyRule(DEAD_END).removeImplicitRules().build(), now,
            ) { done?.countDown() }
        } else {
            controller.clearProxyOverride(now) { done?.countDown() }
        }
        return true
    }
}
