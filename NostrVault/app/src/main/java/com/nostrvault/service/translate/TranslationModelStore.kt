package com.nostrvault.service.translate

import android.content.Context
import android.util.Log
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.File
import java.io.IOException
import java.security.MessageDigest
import java.util.concurrent.TimeUnit
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Mozilla's translation models on the phone: fetched from Mozilla (the same
 * Remote Settings server and CDN Firefox uses) the first time a direction is
 * needed, checked against the catalog's SHA-256, and kept under
 * noBackupFilesDir/translate. Nothing is bundled in the APK, and only model
 * files are downloaded: the note text never leaves the phone.
 */
@Singleton
class TranslationModelStore @Inject constructor(
    @ApplicationContext private val context: Context,
) {
    private val http: OkHttpClient by lazy {
        OkHttpClient.Builder()
            .connectTimeout(20, TimeUnit.SECONDS)
            .readTimeout(60, TimeUnit.SECONDS)
            .build()
    }

    private val root: File get() = File(context.noBackupFilesDir, "translate/models")

    /** One download at a time; a second caller for the same direction finds it done. */
    private val downloads = Mutex()

    @Volatile private var catalog: String? = null

    /** A direction that is on disk and complete. */
    data class Installed(val model: File, val srcVocab: File, val trgVocab: File, val shortlist: File) {
        fun bergamotConfig(): String =
            MozillaModelCatalog.bergamotConfig(model.path, srcVocab.path, trgVocab.path, shortlist.path)
    }

    /** The direction [from] -> [to] (Mozilla codes) if it is already downloaded. */
    fun installed(from: String, to: String): Installed? {
        val dir = File(root, "$from-$to")
        val ready = File(dir, READY).takeIf { it.isFile } ?: return null
        val names = ready.readLines().associate { line ->
            val (type, name) = line.split('\t', limit = 2).let { it[0] to it.getOrElse(1) { "" } }
            type to File(dir, name)
        }
        val model = names["model"] ?: return null
        val lex = names["lex"] ?: return null
        val src = names["srcvocab"] ?: return null
        val trg = names["trgvocab"] ?: return null
        return Installed(model, src, trg, lex).takeIf { listOf(model, lex, src, trg).all(File::isFile) }
    }

    /** [installed], downloading it from Mozilla first when it isn't there. */
    suspend fun ensure(from: String, to: String): Installed {
        installed(from, to)?.let { return it }
        return downloads.withLock {
            installed(from, to) ?: withContext(Dispatchers.IO) { download(from, to) }
        }
    }

    private fun download(from: String, to: String): Installed {
        val set = MozillaModelCatalog.pick(catalogJson(), from, to)
            ?: throw IOException("Mozilla has no $from-$to model")
        val dir = File(root, "$from-$to")
        val staging = File(root, ".$from-$to.part").apply { deleteRecursively(); mkdirs() }
        try {
            for (file in set.files.filter { it.fileType in WANTED }) fetch(file, File(staging, file.fileName))
            val vocabs = set.vocabs
            val lines = listOf(
                "model\t${set.model.fileName}",
                "lex\t${set.shortlist.fileName}",
                "srcvocab\t${vocabs[0].fileName}",
                "trgvocab\t${vocabs[1].fileName}",
            )
            File(staging, READY).writeText(lines.joinToString("\n") + "\n")
            dir.deleteRecursively()
            if (!staging.renameTo(dir)) throw IOException("could not move $from-$to models into place")
        } finally {
            staging.deleteRecursively()
        }
        Log.i(TAG, "downloaded $from-$to ${set.version}")
        return requireNotNull(installed(from, to))
    }

    private fun catalogJson(): String {
        catalog?.let { return it }
        val body = get(MozillaModelCatalog.RECORDS_URL) { it.readBytes() }.toString(Charsets.UTF_8)
        catalog = body
        return body
    }

    private fun fetch(file: MozillaModelCatalog.ModelFile, dest: File) {
        val digest = MessageDigest.getInstance("SHA-256")
        get(file.url) { input ->
            dest.outputStream().use { out ->
                val buffer = ByteArray(64 * 1024)
                while (true) {
                    val n = input.read(buffer)
                    if (n < 0) break
                    digest.update(buffer, 0, n)
                    out.write(buffer, 0, n)
                }
            }
        }
        val hash = digest.digest().joinToString("") { "%02x".format(it) }
        if (hash != file.sha256) {
            dest.delete()
            throw IOException("${file.fileName}: checksum mismatch")
        }
    }

    private fun <T> get(url: String, read: (java.io.InputStream) -> T): T {
        val request = Request.Builder().url(url).build()
        http.newCall(request).execute().use { response ->
            if (!response.isSuccessful) throw IOException("HTTP ${response.code} for $url")
            val body = response.body ?: throw IOException("empty body for $url")
            return body.byteStream().use(read)
        }
    }

    private companion object {
        const val TAG = "TranslationModelStore"
        const val READY = "ready.tsv"
        val WANTED = setOf("model", "lex", "vocab", "srcvocab", "trgvocab")
    }
}
