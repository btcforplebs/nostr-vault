package com.nostrvault.service

import android.content.Context
import android.net.Uri
import android.util.Log
import coil.ImageLoader
import coil.decode.DataSource
import coil.decode.ImageSource
import coil.fetch.FetchResult
import coil.fetch.Fetcher
import coil.fetch.SourceResult
import coil.request.Options
import com.nostrvault.data.model.BlossomUri
import com.nostrvault.fips.MeshAuthor
import com.nostrvault.relay.RelayConfiguration
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import okio.Path.Companion.toOkioPath
import java.io.File
import java.io.IOException
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit

/**
 * Reads a BUD-10 `blossom:` link's file: the link's `xs` servers, then the
 * author's kind 10063 list, then this account's media servers and the
 * new-account defaults. Each answer is hashed before it is kept; the first one
 * that matches is saved under the link's sha256, and photos, video frames and
 * players all read that one file. A link no server can serve is not asked again
 * for [RETRY_AFTER_MS], so a feed full of it costs one try.
 * iOS: `BlossomURIFetcher` (#1312). Web: `loadBlossom` (#1311).
 */
object BlossomUriLoader {
    private const val TAG = "BlossomUri"

    /** Servers one link may ask from its own hints, and again from the author's list and ours together. */
    const val MAX_SERVERS = 5
    /** The most one file may be. Bigger answers are dropped unread. */
    const val MAX_BYTES = 512L shl 20
    private const val RETRY_AFTER_MS = 120_000L
    /** How long a read waits for an author's 10063 it has just asked for. */
    private const val LIST_WAIT_MS = 4_000L

    /** Kind 10063 lists by author, and a way to ask for one. Set by [NostrService]. */
    @Volatile var serverLists: () -> Map<String, List<String>> = { emptyMap() }
    @Volatile var requestServerList: (String) -> Unit = {}
    /** This account's media servers. Set by [NostrService]. */
    @Volatile var ownServers: () -> List<String> = { emptyList() }

    private val client = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(15, TimeUnit.SECONDS)
        .callTimeout(300, TimeUnit.SECONDS)
        // Every hop, redirects included, is https to a public host: a link
        // cannot send readers to probe their own network.
        .addNetworkInterceptor { chain ->
            val url = chain.request().url
            if (!url.isHttps || BlossomUri.isPrivateHost(url.host.lowercase())) throw IOException("Refused ${url.host}")
            chain.proceed(chain.request())
        }
        .build()

    private val inFlight = ConcurrentHashMap<String, CompletableDeferred<File?>>()
    private val failedAt = ConcurrentHashMap<String, Long>()
    /** Files already hashed this launch, by path, size and mtime. */
    private val verified = ConcurrentHashMap.newKeySet<String>()

    private fun directory(context: Context): File =
        File(context.cacheDir, "blossom_links").apply { mkdirs() }

    /**
     * The verified local file for [link], downloading it if needed; null when
     * it is not a `blossom:` link or no server had the right bytes.
     */
    suspend fun file(context: Context, link: String, noteAuthor: String? = null): File? {
        val uri = BlossomUri.parse(link) ?: return null
        return withContext(Dispatchers.IO) { fileFor(context, uri, noteAuthor) }
    }

    private suspend fun fileFor(context: Context, uri: BlossomUri, noteAuthor: String?): File? {
        val path = File(directory(context), "${uri.sha256}.${uri.ext}")
        if (path.exists()) {
            val stamp = "${path.path}|${path.length()}|${path.lastModified()}"
            if (stamp in verified) return path
            if (hashFile(path) == uri.sha256) {
                verified += stamp
                return path
            }
            path.delete()
        }
        failedAt[uri.sha256]?.let { if (System.currentTimeMillis() - it < RETRY_AFTER_MS) return null }
        if (uri.size != null && uri.size > MAX_BYTES) return null

        val mine = CompletableDeferred<File?>()
        val running = inFlight.putIfAbsent(uri.sha256, mine)
        if (running != null) return running.await()
        val result = try {
            download(uri, uri.author ?: noteAuthor ?: BlossomUri.noteAuthor(uri.sha256), path)
        } catch (e: Exception) {
            null
        }
        if (result == null) failedAt[uri.sha256] = System.currentTimeMillis() else failedAt.remove(uri.sha256)
        inFlight.remove(uri.sha256)
        mine.complete(result)
        return result
    }

    /** The link's own servers first; the author's list is only looked up (and waited for) when none had it. */
    private suspend fun download(uri: BlossomUri, author: String?, path: File): File? {
        val own = uri.candidates(emptyList(), emptyList())
        firstMatch(uri, own.take(MAX_SERVERS), path)?.let { return it }
        val authorServers = author?.let { serverList(it) }.orEmpty()
        val rest = uri.candidates(authorServers, ownServers() + RelayConfiguration.newAccountBlossomMirrors)
            .filter { it !in own }
        firstMatch(uri, rest.take(MAX_SERVERS), path)?.let { return it }
        Log.i(TAG, "Blossom: ${uri.sha256.take(8)} unavailable on ${minOf(own.size, MAX_SERVERS) + minOf(rest.size, MAX_SERVERS)} servers")
        return null
    }

    /** GETs `/<sha256>.<ext>` from each in turn; the first whole body that hashes to the link moves to [path]. */
    private fun firstMatch(uri: BlossomUri, urls: List<String>, path: File): File? {
        for (url in urls) {
            val host = runCatching { Uri.parse(url).host }.getOrNull() ?: "?"
            val temp = File(path.parentFile, "${path.name}.${System.nanoTime()}.part")
            val ok = fetchTo(url, temp) == uri.sha256
            if (!ok) {
                temp.delete()
                Log.i(TAG, "Blossom: ${uri.sha256.take(8)} not on $host")
                continue
            }
            path.delete()
            if (!temp.renameTo(path)) {
                temp.delete()
                return null
            }
            verified += "${path.path}|${path.length()}|${path.lastModified()}"
            Log.i(TAG, "Blossom: read ${uri.sha256.take(8)} from $host (${path.length()} bytes)")
            return path
        }
        return null
    }

    /** GETs [url] into [file]; the body's sha256, or null on any failure or past [MAX_BYTES]. */
    private fun fetchTo(url: String, file: File): String? = try {
        client.newCall(Request.Builder().url(url).get().build()).execute().use { r ->
            val body = r.body
            if (r.code != 200 || body == null || body.contentLength() > MAX_BYTES) return null
            val digest = MessageDigest.getInstance("SHA-256")
            var total = 0L
            body.byteStream().use { input ->
                file.outputStream().use { out ->
                    val buf = ByteArray(64 * 1024)
                    while (true) {
                        val n = input.read(buf)
                        if (n < 0) break
                        total += n
                        if (total > MAX_BYTES) return null
                        digest.update(buf, 0, n)
                        out.write(buf, 0, n)
                    }
                }
            }
            digest.digest().toHex()
        }
    } catch (e: IOException) {
        null
    } catch (e: IllegalArgumentException) {
        null
    }

    /** The author's newest 10063 servers, asking relays once and waiting briefly when none has been seen yet. */
    private suspend fun serverList(author: String): List<String> {
        serverLists()[author]?.let { return it }
        requestServerList(author)
        val deadline = System.currentTimeMillis() + LIST_WAIT_MS
        while (System.currentTimeMillis() < deadline) {
            delay(500)
            serverLists()[author]?.let { return it }
        }
        return emptyList()
    }

    private fun hashFile(file: File): String? = try {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buf = ByteArray(1 shl 20)
            while (true) {
                val n = input.read(buf)
                if (n < 0) break
                digest.update(buf, 0, n)
            }
        }
        digest.digest().toHex()
    } catch (e: IOException) {
        null
    }

    private fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it) }

    private val MIME = mapOf(
        "jpg" to "image/jpeg", "jpeg" to "image/jpeg", "png" to "image/png", "gif" to "image/gif",
        "webp" to "image/webp", "avif" to "image/avif", "svg" to "image/svg+xml", "bmp" to "image/bmp",
        "mp4" to "video/mp4", "m4v" to "video/mp4", "mov" to "video/quicktime", "webm" to "video/webm",
        "mkv" to "video/x-matroska", "avi" to "video/x-msvideo",
    )

    /**
     * Coil fetcher for `blossom:` links: the checked file, so a photo is drawn
     * and a video's frame read (by `VideoFrameDecoder`) only from bytes that
     * hash to the link. No server with the right bytes is an error, which the
     * card shows as "Media unavailable".
     */
    class Fetcher(
        private val link: String,
        private val options: Options,
    ) : coil.fetch.Fetcher {
        override suspend fun fetch(): FetchResult {
            val author = options.tags.tag(MeshAuthor::class.java)?.pubkey
            val uri = BlossomUri.parse(link) ?: throw IOException("Not a blossom: link")
            val file = file(options.context, link, author) ?: throw IOException("Blossom ${uri.sha256.take(8)} unavailable")
            return SourceResult(
                source = ImageSource(file.toOkioPath()),
                mimeType = MIME[uri.ext],
                dataSource = DataSource.NETWORK,
            )
        }

        class Factory : coil.fetch.Fetcher.Factory<Uri> {
            override fun create(data: Uri, options: Options, imageLoader: ImageLoader): coil.fetch.Fetcher? =
                if (data.scheme.equals(BlossomUri.SCHEME, ignoreCase = true)) Fetcher(data.toString(), options) else null
        }
    }
}
