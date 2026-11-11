package com.nostrvault.ui.screens.browser

import android.content.Context
import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import com.nostrvault.fips.MeshSiteDoor
import com.nostrvault.ui.components.NostrWebLinks
import com.nostrvault.ui.theme.NostrVaultTheme
import dagger.hilt.android.AndroidEntryPoint
import java.lang.ref.WeakReference
import javax.inject.Inject

/**
 * Hosts [InAppBrowserScreen] over whatever screen the link was tapped on (iOS: a full-screen cover). Its own
 * activity, so every link tap, from any screen, sheet or dialog, opens it the same way: [InAppBrowser.open].
 *
 * One browser is open at a time. A second one (a link tapped in the app opened over the first) closes the first:
 * a hidden WebView keeps running its page's scripts, and a mesh page out of sight must not run while the web page
 * on screen has the WebView-wide [MeshProxy] off.
 */
@AndroidEntryPoint
class InAppBrowserActivity : ComponentActivity() {
    @Inject lateinit var door: MeshSiteDoor

    private var model: InAppBrowserModel? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        val url = intent.getStringExtra(EXTRA_URL)
        if (url == null) { finish(); return }
        open?.get()?.takeIf { it !== this }?.retire()
        open = WeakReference(this)
        val model = InAppBrowserModel(this, door::ingress).also { this.model = it }
        model.onExternal = { link ->
            finish()
            // nostr: comes back into the app through its own intent filter; mailto:, lightning: go to their apps.
            runCatching { startActivity(Intent(Intent.ACTION_VIEW, android.net.Uri.parse(link)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
        }
        setContent {
            NostrVaultTheme(oledMode = true) {
                InAppBrowserScreen(
                    model = model,
                    onClose = ::finish,
                    onShare = { share(it) },
                    onOpenInBrowser = { NostrWebLinks.openInSystemBrowser(this, it) },
                )
            }
        }
        model.open(url)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        intent.getStringExtra(EXTRA_URL)?.let { model?.open(it) }
    }

    override fun onResume() {
        super.onResume()
        model?.resume()
    }

    override fun onPause() {
        model?.pause()
        super.onPause()
    }

    /** A newer browser opened: this one's page stops now, not when the system gets round to destroying it. */
    private fun retire() {
        // The WebView leaves the screen before it is destroyed.
        setContent {}
        model?.close()
        model = null
        finish()
    }

    private fun share(url: String) {
        val send = Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, url)
        runCatching { startActivity(Intent.createChooser(send, null)) }
    }

    override fun onDestroy() {
        model?.close()
        model = null
        if (open?.get() === this) open = null
        super.onDestroy()
    }

    companion object {
        private const val EXTRA_URL = "url"

        /** The browser open now (main thread only). */
        private var open: WeakReference<InAppBrowserActivity>? = null

        fun intent(context: Context, url: String): Intent =
            Intent(context, InAppBrowserActivity::class.java).putExtra(EXTRA_URL, url)
                .apply { if (context !is android.app.Activity) addFlags(Intent.FLAG_ACTIVITY_NEW_TASK) }
    }
}
