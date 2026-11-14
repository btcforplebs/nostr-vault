package com.nostrvault.fips

import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.FilterInputStream
import java.io.IOException
import java.io.InputStream
import java.net.Proxy
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong

/**
 * Reads one request of a `<npub>.fips` page through the mesh door to that npub's port 80 (`NvFipsIngress`,
 * read-anyone through the seeds, mesh key only), with `Host: <npub>.fips` (iOS/Mac: FipsSchemeHandler).
 *
 * Nothing here touches DNS: the only socket is to the loopback door. Each page is capped in bytes, each request
 * in time. A mesh that is up but has no tree parent yet is waited for ([onStatus] says so), then answered as
 * "mesh not ready" instead of a run of silent resets. Runs on WebView's intercept threads: it blocks.
 */
class MeshSiteFetcher(
    private val door: (String) -> MeshSiteIngress,
    private val treeWaitMs: Long = TREE_WAIT_MS,
    private val treePollMs: Long = TREE_POLL_MS,
    private val client: OkHttpClient = defaultClient,
    private val retryWindowMs: Long = RETRY_WINDOW_MS,
    private val retryPauseMs: Long = RETRY_PAUSE_MS,
) {
    /** What the WebView gets back. */
    sealed interface Reply {
        /** The site's answer, streamed. [mime] and [charset] come from its Content-Type. */
        class Body(
            val status: Int,
            val reason: String,
            val mime: String,
            val charset: String?,
            val headers: Map<String, String>,
            val stream: InputStream,
        ) : Reply
        /** A page the browser writes: [html], with [status]. */
        data class Page(val html: String, val status: Int = 200) : Reply
        /** A subresource that could not be read. */
        data object Fail : Reply
    }

    /** "Waiting for the mesh…" while a page waits for the tree; null when done. */
    @Volatile var onStatus: (String?) -> Unit = {}

    private val bases = ConcurrentHashMap<String, String>()
    private val pageBytes = AtomicLong(0)

    /**
     * One request: [site] is the page's `http://<npub>.fips/…` URL (from [FipsUrl.request]), [isMain] whether it
     * is the page itself. [accept] and [range] are the WebView's own headers, passed on.
     */
    fun fetch(npub: String, site: String, method: String, isMain: Boolean, accept: String? = null, range: String? = null): Reply {
        if (isMain) pageBytes.set(0)
        val m = method.uppercase()
        if (m != "GET" && m != "HEAD") {
            // Reading only: a form post has nowhere honest to go (and WebView never shows us its body).
            return if (isMain) Reply.Page(MeshPage.html(MeshPage.ReadOnly, site), 405) else Reply.Fail
        }
        // "Still reaching this site…" lasts until the page is answered.
        try {
            return read(npub, site, m, isMain, accept, range)
        } finally {
            if (isMain) onStatus(null)
        }
    }

    private fun read(npub: String, site: String, m: String, isMain: Boolean, accept: String?, range: String?): Reply {
        var target = site
        var redirects = 0
        // A cold route resets the first asks: ask again, through a fresh door, until [retryWindowMs] (iOS MeshSiteRetry).
        val firstAsk = System.currentTimeMillis()
        while (redirects <= MAX_REDIRECTS) {
            val base = when (val d = doorFor(npub)) {
                is MeshSiteIngress.Ready -> d.base
                else -> return if (isMain) Reply.Page(MeshPage.html(MeshPage.of(d), site)) else Reply.Fail
            }
            val url = FipsUrl.doorUrl(base, target) ?: return page(isMain, MeshPage.Refused, site)
            val request = Request.Builder().url(url).method(m, null)
                .header("Host", FipsUrl.hostHeader(target) ?: return page(isMain, MeshPage.Refused, site))
                .header("Accept", accept ?: "text/html,application/xhtml+xml,*/*;q=0.8")
                .apply { if (range != null) header("Range", range) }
                .build()
            val response = try {
                client.newCall(request).execute()
            } catch (_: IOException) {
                // No byte came back: no route, a reset, a timeout. The door may be stale (the tree moved).
                bases.remove(npub)
                if (System.currentTimeMillis() - firstAsk + retryPauseMs < retryWindowMs) {
                    if (isMain) onStatus("Still reaching this site…")
                    try { Thread.sleep(retryPauseMs) } catch (_: InterruptedException) { return page(isMain, MeshPage.Unreachable, site) }
                    continue
                }
                return page(isMain, MeshPage.Unreachable, site)
            }
            if (response.code in 300..399) {
                val location = response.header("Location")
                response.close()
                val next = location?.let { FipsUrl.redirectTarget(it, target) } ?: return page(isMain, MeshPage.Refused, site)
                if (isMain) {
                    // The page itself moves: the WebView navigates, so the bar and history follow, and an off-mesh
                    // target is said, not followed.
                    return Reply.Page(if (FipsUrl.meshNpub(next) == npub) MeshPage.redirectHtml(next) else MeshPage.leaveHtml(next))
                }
                if (FipsUrl.meshNpub(next) != npub) return Reply.Fail
                target = next
                redirects++
                continue
            }
            val body = response.body ?: run { response.close(); return Reply.Fail }
            val budget = PAGE_BYTE_CAP - pageBytes.get()
            if (body.contentLength() > budget) {
                response.close()
                return page(isMain, MeshPage.TooBig, site)
            }
            val type = body.contentType()
            val headers = response.headers.toMultimap().mapValues { it.value.joinToString(", ") }
            return Reply.Body(
                status = response.code.takeIf { it in 100..599 && it !in 300..399 } ?: 502,
                reason = response.message.ifBlank { reasonFor(response.code) },
                mime = type?.let { "${it.type}/${it.subtype}" } ?: "application/octet-stream",
                charset = type?.charset()?.name(),
                headers = FipsUrl.meshHeaders(npub, headers),
                stream = Capped(body.byteStream(), pageBytes, PAGE_BYTE_CAP),
            )
        }
        return if (isMain) Reply.Page(MeshPage.html(MeshPage.Refused, site)) else Reply.Fail
    }

    private fun page(isMain: Boolean, page: MeshPage, site: String): Reply =
        if (isMain) Reply.Page(MeshPage.html(page, site)) else Reply.Fail

    /** The door to [npub], waiting out a mesh that has no tree parent yet. */
    private fun doorFor(npub: String): MeshSiteIngress {
        bases[npub]?.let { return MeshSiteIngress.Ready(it) }
        val deadline = System.currentTimeMillis() + treeWaitMs
        var reply = door(npub)
        var waited = false
        while (reply.isWaiting && System.currentTimeMillis() < deadline) {
            waited = true
            onStatus("Waiting for the mesh…")
            try { Thread.sleep(treePollMs) } catch (_: InterruptedException) { break }
            reply = door(npub)
        }
        // A page still being retried keeps its own line (fetch clears it).
        if (waited) onStatus(null)
        if (reply is MeshSiteIngress.Ready) bases[npub] = reply.base
        return reply
    }

    /** The page's bytes so far, across all its requests: past [cap] the stream breaks. */
    private class Capped(input: InputStream, private val used: AtomicLong, private val cap: Long) : FilterInputStream(input) {
        private fun count(n: Int): Int {
            if (n > 0 && used.addAndGet(n.toLong()) > cap) throw IOException("mesh page over $cap bytes")
            return n
        }
        override fun read(): Int = super.read().also { if (it >= 0) count(1) }
        override fun read(b: ByteArray, off: Int, len: Int): Int = count(super.read(b, off, len))
    }

    companion object {
        /** All of one page's responses together, so a site can't fill memory. */
        const val PAGE_BYTE_CAP = 48L shl 20
        /**
         * A quiet site gives up like a slow server, but only after the mesh could have found it: above the door's
         * 20 s connect plus the engine's 15 s lookup (iOS MeshSiteRetry.requestTimeout).
         */
        const val REQUEST_TIMEOUT_S = 40L
        /** How long one request keeps asking again after resets or timeouts (iOS MeshSiteRetry.window). */
        const val RETRY_WINDOW_MS = 45_000L
        /** The pause between those asks (iOS MeshSiteRetry.pause). */
        const val RETRY_PAUSE_MS = 2_000L
        /** How long a page waits for the engine to find its tree parent. */
        const val TREE_WAIT_MS = 45_000L
        const val TREE_POLL_MS = 3_000L
        private const val MAX_REDIRECTS = 5

        private fun reasonFor(code: Int) = when (code) {
            200 -> "OK"; 206 -> "Partial Content"; 404 -> "Not Found"; else -> "Status $code"
        }

        /** Loopback only: no proxy may see the door's token, no cookies, no cache, redirects mapped here. */
        val defaultClient: OkHttpClient by lazy {
            OkHttpClient.Builder()
                .proxy(Proxy.NO_PROXY)
                .followRedirects(false)
                .followSslRedirects(false)
                .retryOnConnectionFailure(false)
                .connectTimeout(REQUEST_TIMEOUT_S, TimeUnit.SECONDS)
                .readTimeout(REQUEST_TIMEOUT_S, TimeUnit.SECONDS)
                .callTimeout(120, TimeUnit.SECONDS)
                .build()
        }
    }
}
