package com.nostrvault.ui.screens.dm

import android.content.Context
import android.net.Uri
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File

/**
 * A photo pasted, dropped or sent from the keyboard into a thread (iOS
 * PastesClipboardImage and the thread's drop target). The link handed over is
 * only readable for a while, so the photo is copied into the cache at once;
 * it then goes out with the next message like a picked one, through the same
 * Blossom upload with its location stripped.
 */
internal object DMPastedImage {
    private const val DIR = "dm_paste"

    /** Photo types a paste may carry, by the extension the copy is saved under. */
    private val typesByExtension = linkedMapOf(
        "jpg" to "image/jpeg",
        "png" to "image/png",
        "gif" to "image/gif",
        "webp" to "image/webp",
        "heic" to "image/heic",
        "heif" to "image/heif",
        "avif" to "image/avif",
    )

    /** The extension a copy of a [mimeType] photo is saved under, or null when it isn't one. */
    fun extensionFor(mimeType: String?): String? {
        val type = mimeType?.lowercase() ?: return null
        if (type == "image/jpg") return "jpg"
        return typesByExtension.entries.firstOrNull { it.value == type }?.key
    }

    /** The type of a pasted copy from its file name, or null when [fileName] isn't one. */
    fun mimeTypeFor(fileName: String): String? =
        typesByExtension[fileName.substringAfterLast('.', "").lowercase()]

    /** The type of [uri] when it is a pasted copy; the content resolver can't say for a file. */
    fun mimeType(uri: Uri): String? {
        if (!isPasted(uri)) return null
        return mimeTypeFor(uri.lastPathSegment.orEmpty())
    }

    /** The first of [items] whose type is a photo we can attach. */
    fun <T> firstPhoto(items: List<T>, typeOf: (T) -> String?): T? =
        items.firstOrNull { extensionFor(typeOf(it)) != null }

    private fun isPasted(uri: Uri): Boolean =
        uri.scheme == "file" && uri.path?.let { File(it).parentFile?.name } == DIR

    /** Copies the photo at [uri] into the cache, or returns null when it isn't a photo we can read. */
    suspend fun copy(context: Context, uri: Uri): Uri? = withContext(Dispatchers.IO) {
        try {
            val ext = extensionFor(context.contentResolver.getType(uri)) ?: return@withContext null
            val dir = File(context.cacheDir, DIR).apply { mkdirs() }
            val file = File.createTempFile("paste_", ".$ext", dir)
            val input = context.contentResolver.openInputStream(uri)
            if (input == null) {
                file.delete()
                return@withContext null
            }
            file.outputStream().use { out -> input.use { it.copyTo(out) } }
            Uri.fromFile(file)
        } catch (_: Exception) {
            null
        }
    }

    /** Deletes [uri] when it is a pasted copy; a picked photo is the owner's own and stays. */
    fun discard(uri: Uri?) {
        if (uri == null || !isPasted(uri)) return
        uri.path?.let { File(it).delete() }
    }
}
