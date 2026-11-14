package com.nostrvault.service

import android.content.Context
import android.net.Uri
import coil.ImageLoader
import coil.decode.DataSource
import coil.decode.ImageSource
import coil.fetch.FetchResult
import coil.fetch.SourceResult
import coil.request.Options
import com.nostrvault.data.model.BlossomUri
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import okio.buffer
import okio.source
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.util.concurrent.TimeUnit

/**
 * Opens a locked DM photo ([DMFile] link): fetches the ciphertext (at most [DMFile.MAX_FILE], no
 * cookies, no referrer, no redirects, https to a public host only), checks it is the file named by
 * x, decrypts it, and checks the result is the file named by ox. Web: dm-file.js openFileLink.
 *
 * The ciphertext is kept in the app's cache under its hash (at most [CACHE_MAX], oldest dropped
 * first), so a photo seen again isn't fetched again; the opened photo is only ever in memory (and,
 * while saving, a temp file). One file is opened at a time: each holds its ciphertext and photo in
 * memory, and a thread of big photos from anyone who can DM you must not run the app out of it.
 */
object DMFileLoader {
    /** The biggest file a thread shows by itself; a bigger one opens when tapped (the viewer). */
    const val AUTO_SHOW_MAX = 16L * 1024 * 1024

    /** How much ciphertext the cache keeps. */
    internal const val CACHE_MAX = 200L * 1024 * 1024

    /** Coil request parameter: this request may open a file up to [DMFile.MAX_FILE] (the viewer, a tap). */
    const val FULL = "dm_file_full"

    /** The file is bigger than this request shows by itself (not refused: tap to open it). */
    class TooBig : IOException("too big to show by itself")

    private val gate = Semaphore(1)

    private val client = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .callTimeout(60, TimeUnit.SECONDS)
        .followRedirects(false)
        .followSslRedirects(false)
        .addNetworkInterceptor { chain ->
            val url = chain.request().url
            if (!url.isHttps || BlossomUri.isPrivateHost(url.host.lowercase())) throw IOException("Refused ${url.host}")
            // The address actually connected to, as BlossomService.publicOnlyClient: a public name
            // that resolves to 127.0.0.1 or a LAN host is refused too.
            val addr = chain.connection()?.socket()?.inetAddress
            if (addr == null || com.nostrvault.util.UrlSafety.isInternalAddress(addr)) {
                throw IOException("Refused: ${url.host} is not a public address")
            }
            chain.proceed(chain.request())
        }
        .build()

    private fun directory(context: Context) = File(context.cacheDir, "dm_files").apply { mkdirs() }

    /**
     * The opened photo's bytes and type. Throws when it can't be fetched or isn't the file that was
     * sent, and [TooBig] when its ciphertext is over [max] (under [DMFile.MAX_FILE]).
     */
    suspend fun open(context: Context, link: String, max: Long = DMFile.MAX_FILE): Pair<ByteArray, String> =
        gate.withPermit { withContext(Dispatchers.IO) { openNow(context, link, max) } }

    private fun openNow(context: Context, link: String, max: Long): Pair<ByteArray, String> {
        val f = DMFile.parseFileLink(link) ?: throw IOException("not a DM file")
        val name = f.x ?: DMFile.sha256Hex(f.url.toByteArray())
        val kept = File(directory(context), name)
        if (kept.isFile && kept.length() > max) throw if (max < DMFile.MAX_FILE) TooBig() else IOException("too large")
        val cached = if (kept.isFile) runCatching { kept.readBytes() }.getOrNull() else null
        if (cached != null) {
            try {
                val plain = DMFile.decrypt(cached, f.key, f.nonce, f.x, f.ox)
                kept.setLastModified(System.currentTimeMillis())
                return plain to f.mime
            } catch (_: DMFile.Refused) {
                kept.delete()
            }
        }
        val cipher = fetchCapped(f.url, max)
        val plain = DMFile.decrypt(cipher, f.key, f.nonce, f.x, f.ox)
        runCatching {
            val temp = File(kept.parentFile, "${kept.name}.${System.nanoTime()}.part")
            temp.writeBytes(cipher)
            if (!temp.renameTo(kept)) temp.delete()
            trim(kept.parentFile!!, CACHE_MAX)
        }
        return plain to f.mime
    }

    /** Drops the oldest kept files (by last use) until the folder holds at most [max] bytes. */
    internal fun trim(dir: File, max: Long) {
        val files = dir.listFiles()?.filter { it.isFile }?.sortedByDescending { it.lastModified() } ?: return
        var total = 0L
        for (file in files) {
            total += file.length()
            if (total > max) file.delete()
        }
    }

    /** GET [url], read in chunks and stopped at the cap: a body with no length that never ends can't fill memory. */
    internal fun fetchCapped(url: String, max: Long = DMFile.MAX_FILE): ByteArray =
        client.newCall(Request.Builder().url(url).get().build()).execute().use { r ->
            if (r.code != 200) throw IOException("HTTP ${r.code}")
            val body = r.body ?: throw IOException("empty")
            fun over(): IOException = if (max < DMFile.MAX_FILE) TooBig() else IOException("too large")
            if (body.contentLength() > max) throw over()
            val out = ByteArrayOutputStream()
            body.byteStream().use { input ->
                val buf = ByteArray(64 * 1024)
                while (true) {
                    val n = input.read(buf)
                    if (n < 0) break
                    if (out.size() + n > max) throw over()
                    out.write(buf, 0, n)
                }
            }
            out.toByteArray()
        }

    /** Writes the opened photo to a temp file for saving; the caller deletes it. */
    suspend fun openToFile(context: Context, link: String): Pair<File, String> {
        val (plain, mime) = open(context, link)
        return withContext(Dispatchers.IO) {
            val f = File.createTempFile("dm_open_", ".tmp", context.cacheDir)
            f.writeBytes(plain)
            f to mime
        }
    }

    /**
     * Coil fetcher for locked DM photo links, so the thread and the full-screen viewer draw the
     * opened photo. Up to [AUTO_SHOW_MAX] unless the request sets [FULL] (the viewer).
     */
    class Fetcher(private val link: String, private val options: Options) : coil.fetch.Fetcher {
        override suspend fun fetch(): FetchResult {
            val max = if (options.parameters.value<Boolean>(FULL) == true) DMFile.MAX_FILE else AUTO_SHOW_MAX
            val (plain, mime) = open(options.context, link, max)
            return SourceResult(
                // Read straight from the opened bytes: no second copy of a big photo.
                source = ImageSource(plain.inputStream().source().buffer(), options.context),
                mimeType = mime,
                dataSource = DataSource.NETWORK,
            )
        }

        class Factory : coil.fetch.Fetcher.Factory<Uri> {
            override fun create(data: Uri, options: Options, imageLoader: ImageLoader): coil.fetch.Fetcher? {
                val link = data.toString()
                return if (DMFile.isFileLink(link)) Fetcher(link, options) else null
            }
        }
    }
}
