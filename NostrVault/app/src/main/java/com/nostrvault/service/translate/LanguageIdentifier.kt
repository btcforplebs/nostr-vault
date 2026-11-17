package com.nostrvault.service.translate

import android.content.Context
import android.util.Log
import java.io.File

/**
 * fastText's lid.176 language ID (176 languages, 0.9 MB, bundled as an asset
 * by build_translate_android.sh). fastText loads from a file path, so the
 * asset is copied to noBackupFilesDir once.
 */
internal class LanguageIdentifier(private val context: Context) {

    private var handle = 0L
    private var failed = false

    /** Call from one thread at a time. Null when the model or the .so is missing. */
    fun identify(text: String): Guess? {
        val model = load() ?: return null
        return Guess.parse(BergamotNative.identify(model, text))
    }

    private fun load(): Long? {
        if (handle != 0L) return handle
        if (failed || !BergamotNative.isAvailable) return null
        return runCatching {
            val file = File(context.noBackupFilesDir, "translate/$ASSET_NAME")
            // Stored uncompressed (noCompress "ftz"), so the APK's copy has a
            // length to compare with after an app update.
            val size = runCatching { context.assets.openFd(ASSET).use { it.length } }.getOrNull()
            if (!file.isFile || (size != null && file.length() != size)) {
                file.parentFile?.mkdirs()
                val part = File(file.path + ".part")
                context.assets.open(ASSET).use { input -> part.outputStream().use { input.copyTo(it) } }
                if (!part.renameTo(file)) error("could not place $ASSET_NAME")
            }
            BergamotNative.loadLanguageId(file.path).also { handle = it }
        }.onFailure {
            failed = true
            Log.w("LanguageIdentifier", "language ID unavailable", it)
        }.getOrNull()
    }

    /** fastText's top label and its probability. */
    data class Guess(val label: String, val probability: Double) {
        companion object {
            /** "de 0.973" -> Guess("de", 0.973); "" or junk -> null. */
            fun parse(raw: String?): Guess? {
                val parts = raw?.trim()?.split(' ') ?: return null
                if (parts.size != 2 || parts[0].isEmpty()) return null
                val p = parts[1].toDoubleOrNull() ?: return null
                return Guess(parts[0], p)
            }
        }
    }

    private companion object {
        const val ASSET_NAME = "lid.176.ftz"
        const val ASSET = "translate/$ASSET_NAME"
    }
}
