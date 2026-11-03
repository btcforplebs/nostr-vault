package com.nostrvault.service.shareportal

import android.annotation.SuppressLint
import android.content.Context
import android.print.PagePdfPrintBridge
import android.print.PrintAttributes
import android.webkit.WebView
import android.webkit.WebViewClient
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import java.io.File
import kotlin.coroutines.resume

/**
 * A web page as a PDF, for a private copy of a link shared on its own. An
 * off-screen WebView loads the page (no JavaScript: a saved copy is the
 * page's text and pictures, not a running app), then its print adapter
 * writes A4 pages. Twin: PagePDFRenderer.swift.
 */
object PagePdfRenderer {
    private const val LOAD_TIMEOUT_MS = 30_000L

    /** The PDF bytes, or null when the page didn't load in time or didn't print. */
    suspend fun render(context: Context, url: String): ByteArray? {
        if (!url.startsWith("https://", ignoreCase = true) && !url.startsWith("http://", ignoreCase = true)) return null
        val out = File(context.cacheDir, "page-pdf-${System.nanoTime()}.pdf")
        try {
            val ok = withTimeoutOrNull(LOAD_TIMEOUT_MS + 15_000) {
                withContext(Dispatchers.Main) { print(context, url, out) }
            } ?: false
            return if (ok && out.length() > 0) withContext(Dispatchers.IO) { out.readBytes() } else null
        } finally {
            out.delete()
        }
    }

    @SuppressLint("SetJavaScriptEnabled")
    private suspend fun print(context: Context, url: String, out: File): Boolean = suspendCancellableCoroutine { cont ->
        val web = WebView(context.applicationContext)
        web.settings.javaScriptEnabled = false
        web.settings.allowFileAccess = false
        web.settings.allowContentAccess = false
        var started = false
        fun finish(ok: Boolean) {
            web.stopLoading()
            web.destroy()
            if (cont.isActive) cont.resume(ok)
        }
        web.webViewClient = object : WebViewClient() {
            override fun onPageFinished(view: WebView, loaded: String?) {
                if (started) return
                started = true
                val attributes = PrintAttributes.Builder()
                    .setMediaSize(PrintAttributes.MediaSize.ISO_A4)
                    .setResolution(PrintAttributes.Resolution("pdf", "pdf", 300, 300))
                    .setMinMargins(PrintAttributes.Margins.NO_MARGINS)
                    .build()
                val adapter = view.createPrintDocumentAdapter("page")
                PagePdfPrintBridge.write(adapter, attributes, out) { finish(it) }
            }
        }
        web.postDelayed({ if (!started) { started = true; finish(false) } }, LOAD_TIMEOUT_MS)
        cont.invokeOnCancellation { web.post { web.destroy() } }
        web.loadUrl(url)
    }
}
