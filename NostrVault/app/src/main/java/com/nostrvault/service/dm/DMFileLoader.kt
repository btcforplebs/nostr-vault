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
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import okio.Buffer
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.util.concurrent.TimeUnit

/**
 * Opens a locked DM photo ([DMFile] link): fetches the ciphertext (at most [DMFile.MAX_FILE], no
 * cookies, no referrer, no redirects, https to a public host only), checks it is the file named by
 * x, decrypts it, and checks the result is the file named by ox. Web: dm-file.js openFileLink.
 *
 * The ciphertext is kept in the app's cache under its hash, so a photo seen again isn't fetched
 * again; the opened photo is only ever in memory (and, while saving, a temp file).
 */
object DMFileLoader {
    private val client = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .callTimeout(60, TimeUnit.SECONDS)
        .followRedirects(false)
        .followSslRedirects(false)
        .addNetworkInterceptor { chain ->
            val url = chain.request().url
            if (!url.isHttps || BlossomUri.isPrivateHost(url.host.lowercase())) throw IOException("Refused ${url.host}")
            chain.proceed(chain.request())
        }
        .build()

    private fun directory(context: Context) = File(context.cacheDir, "dm_files").apply { mkdirs() }

    /** The opened photo's bytes and type. Throws when it can't be fetched or isn't the file that was sent. */
    suspend fun open(context: Context, link: String): Pair<ByteArray, String> = withContext(Dispatchers.IO) {
        val f = DMFile.parseFileLink(link) ?: throw IOException("not a DM file")
        val name = f.x ?: DMFile.sha256Hex(f.url.toByteArray())
        val kept = File(directory(context), name)
        val cached = if (kept.isFile) runCatching { kept.readBytes() }.getOrNull() else null
        if (cached != null) {
            try {
                return@withContext DMFile.decrypt(cached, f.key, f.nonce, f.x, f.ox) to f.mime
            } catch (_: DMFile.Refused) {
                kept.delete()
            }
        }
        val cipher = fetchCapped(f.url)
        val plain = DMFile.decrypt(cipher, f.key, f.nonce, f.x, f.ox)
        runCatching {
            val temp = File(kept.parentFile, "${kept.name}.${System.nanoTime()}.part")
            temp.writeBytes(cipher)
            if (!temp.renameTo(kept)) temp.delete()
        }
        plain to f.mime
    }

    /** GET [url], read in chunks and stopped at the cap: a body with no length that never ends can't fill memory. */
    internal fun fetchCapped(url: String, max: Long = DMFile.MAX_FILE): ByteArray =
        client.newCall(Request.Builder().url(url).get().build()).execute().use { r ->
            if (r.code != 200) throw IOException("HTTP ${r.code}")
            val body = r.body ?: throw IOException("empty")
            if (body.contentLength() > max) throw IOException("too large")
            val out = ByteArrayOutputStream()
            body.byteStream().use { input ->
                val buf = ByteArray(64 * 1024)
                while (true) {
                    val n = input.read(buf)
                    if (n < 0) break
                    if (out.size() + n > max) throw IOException("too large")
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

    /** Coil fetcher for locked DM photo links, so the thread and the full-screen viewer draw the opened photo. */
    class Fetcher(private val link: String, private val options: Options) : coil.fetch.Fetcher {
        override suspend fun fetch(): FetchResult {
            val (plain, mime) = open(options.context, link)
            return SourceResult(
                source = ImageSource(Buffer().write(plain), options.context),
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
