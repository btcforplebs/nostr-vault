package com.nostrvault.service

import android.content.Context
import android.net.Uri
import android.util.Log
import coil.ImageLoader
import coil.decode.DataSource
import coil.decode.ImageSource
import coil.fetch.FetchResult
import coil.fetch.SourceResult
import coil.request.Options
import com.nostrvault.data.model.BlossomUri
import com.nostrvault.data.model.HtreeLink
import com.nostrvault.fips.MeshAuthor
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import okio.Path.Companion.toOkioPath
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit

/**
 * Reads an `htree://` photo ([HtreeLink]): `GET <server>/<blob hash>` from
 * upload.iris.to, then the author's kind 10063 servers, then this account's
 * media servers. A server's answer is kept only when it hashes to the blob
 * hash, decrypts, hashes to the plain sha256 the key is, and is a picture.
 * The plain photo is cached under that sha256, so the feed, the viewer and
 * Save to Vault all read the same checked file. A link no server can serve is
 * not asked again for [RETRY_AFTER_MS]. Same shape as [BlossomUriLoader].
 * Web: `web-vault/src/net/htree.js` (#2508).
 */
object HtreeLoader {
    private const val TAG = "Htree"
    private const val RETRY_AFTER_MS = 120_000L
    private const val LIST_WAIT_MS = 4_000L

    private val client = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(15, TimeUnit.SECONDS)
        .callTimeout(60, TimeUnit.SECONDS)
        // No redirects: a public server could send readers on to a home-network host.
        .followRedirects(false)
        .followSslRedirects(false)
        .addNetworkInterceptor { chain ->
            val url = chain.request().url
            if (!url.isHttps || BlossomUri.isPrivateHost(url.host.lowercase())) throw IOException("Refused ${url.host}")
            chain.proceed(chain.request())
        }
        .build()

    private val inFlight = ConcurrentHashMap<String, CompletableDeferred<File?>>()
    private val failedAt = ConcurrentHashMap<String, Long>()
    private val verified = ConcurrentHashMap.newKeySet<String>()

    private fun directory(context: Context): File = File(context.cacheDir, "htree_links").apply { mkdirs() }

    /** The checked plain photo for [link], downloading it if needed; null when no server had it. */
    suspend fun file(context: Context, link: String, noteAuthor: String? = null): File? {
        val parsed = HtreeLink.parse(link) ?: return null
        return withContext(Dispatchers.IO) { fileFor(context, parsed, noteAuthor) }
    }

    private suspend fun fileFor(context: Context, link: HtreeLink, noteAuthor: String?): File? {
        val sha = link.plainSha256
        val path = File(directory(context), sha)
        if (path.exists()) {
            val stamp = "${path.path}|${path.length()}|${path.lastModified()}"
            if (stamp in verified) return path
            if (runCatching { HtreeLink.sha256Hex(path.readBytes()) }.getOrNull() == sha) {
                verified += stamp
                return path
            }
            path.delete()
        }
        failedAt[sha]?.let { if (System.currentTimeMillis() - it < RETRY_AFTER_MS) return null }
        val mine = CompletableDeferred<File?>()
        val running = inFlight.putIfAbsent(sha, mine)
        if (running != null) return running.await()
        val result = try {
            download(link, noteAuthor ?: HtreeLink.noteAuthor(link.blobHash), path)
        } catch (e: CancellationException) {
            // The row went away: not a failure, so no 120 s hold, and the cancel goes on.
            inFlight.remove(sha)
            mine.complete(null)
            throw e
        } catch (e: Exception) {
            null
        }
        if (result == null) failedAt[sha] = System.currentTimeMillis() else failedAt.remove(sha)
        inFlight.remove(sha)
        mine.complete(result)
        return result
    }

    /** Iris first; the author's list is only looked up (and waited for) when Iris didn't have it. */
    private suspend fun download(link: HtreeLink, author: String?, path: File): File? {
        val iris = link.candidates(emptyList(), emptyList())
        firstMatch(link, iris, path)?.let { return it }
        val authorServers = author?.let { serverList(it) }.orEmpty()
        val rest = link.candidates(authorServers, BlossomUriLoader.ownServers()).filter { it !in iris }
        firstMatch(link, rest, path)?.let { return it }
        Log.i(TAG, "htree ${link.blobHash.take(8)} unavailable on ${iris.size + rest.size} servers")
        return null
    }

    private fun firstMatch(link: HtreeLink, urls: List<String>, path: File): File? {
        for (url in urls) {
            val blob = fetch(url) ?: continue
            val opened = HtreeLink.open(link, blob) ?: continue
            val temp = File(path.parentFile, "${path.name}.${System.nanoTime()}.part")
            temp.writeBytes(opened.bytes)
            path.delete()
            if (!temp.renameTo(path)) {
                temp.delete()
                return null
            }
            verified += "${path.path}|${path.length()}|${path.lastModified()}"
            return path
        }
        return null
    }

    /** The whole body of a 200, or null past [HtreeLink.MAX_BLOB_BYTES] or on any failure. */
    private fun fetch(url: String): ByteArray? = try {
        client.newCall(Request.Builder().url(url).get().build()).execute().use { r ->
            val body = r.body
            if (r.code != 200 || body == null || body.contentLength() > HtreeLink.MAX_BLOB_BYTES) return null
            val out = ByteArrayOutputStream()
            body.byteStream().use { input ->
                val buf = ByteArray(64 * 1024)
                while (true) {
                    val n = input.read(buf)
                    if (n < 0) break
                    if (out.size() + n > HtreeLink.MAX_BLOB_BYTES) return null
                    out.write(buf, 0, n)
                }
            }
            out.toByteArray()
        }
    } catch (e: IOException) {
        null
    } catch (e: IllegalArgumentException) {
        null
    }

    /** The author's newest 10063 servers, from the lists [BlossomUriLoader] is given. */
    private suspend fun serverList(author: String): List<String> {
        BlossomUriLoader.serverLists()[author]?.let { return it }
        BlossomUriLoader.requestServerList(author)
        val deadline = System.currentTimeMillis() + LIST_WAIT_MS
        while (System.currentTimeMillis() < deadline) {
            delay(500)
            BlossomUriLoader.serverLists()[author]?.let { return it }
        }
        return emptyList()
    }

    /** Coil fetcher for `htree://` links: the checked plain photo; none is an error ("Image unavailable"). */
    class Fetcher(private val link: String, private val options: Options) : coil.fetch.Fetcher {
        override suspend fun fetch(): FetchResult {
            val author = options.tags.tag(MeshAuthor::class.java)?.pubkey
            val parsed = HtreeLink.parse(link) ?: throw IOException("Not an htree link")
            val file = file(options.context, link, author) ?: throw IOException("htree ${parsed.blobHash.take(8)} unavailable")
            val head = ByteArray(16)
            val n = file.inputStream().use { it.read(head) }
            val mime = HtreeLink.sniffImage(head.copyOf(maxOf(n, 0)))
            return SourceResult(source = ImageSource(file.toOkioPath()), mimeType = mime, dataSource = DataSource.NETWORK)
        }

        class Factory : coil.fetch.Fetcher.Factory<Uri> {
            override fun create(data: Uri, options: Options, imageLoader: ImageLoader): coil.fetch.Fetcher? =
                if (data.scheme.equals(HtreeLink.SCHEME, ignoreCase = true)) Fetcher(data.toString(), options) else null
        }
    }
}
