package com.nostrvault.ui.screens.browser

import androidx.webkit.ProxyConfig
import androidx.webkit.ProxyController
import androidx.webkit.WebViewFeature
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
 * override. The override is WebView-wide, so it is cleared when the browser closes.
 */
internal object MeshProxy {
    val isSupported: Boolean get() = WebViewFeature.isFeatureSupported(WebViewFeature.PROXY_OVERRIDE)

    private const val DEAD_END = "http://127.0.0.1:9"
    private val now = Executor { it.run() }
    private var on: Boolean? = null

    /**
     * Mesh pages on ([mesh]) or off. [wait] blocks until the WebView has it, for an intercept thread about to
     * hand the page its first byte; the main thread passes false.
     */
    fun set(mesh: Boolean, wait: Boolean) {
        val done = CountDownLatch(1)
        synchronized(this) {
            if (!isSupported || on == mesh) return
            on = mesh
            val controller = ProxyController.getInstance()
            if (mesh) {
                controller.setProxyOverride(
                    ProxyConfig.Builder().addProxyRule(DEAD_END).removeImplicitRules().build(), now,
                ) { done.countDown() }
            } else {
                controller.clearProxyOverride(now) { done.countDown() }
            }
        }
        if (wait) done.await(2, TimeUnit.SECONDS)
    }
}
