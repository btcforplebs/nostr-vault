package com.nostrvault.ui.screens.dm

import com.nostrvault.service.HeapCap
import android.content.Context
import android.net.Uri
import com.nostrvault.service.BlossomService
import com.nostrvault.service.DMFile
import com.nostrvault.service.GifStrip
import com.nostrvault.service.MediaPrivacy
import com.nostrvault.service.media.ImageCompressor
import com.nostrvault.service.uploadLocked
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.io.IOException

/**
 * A photo for a NIP-17 DM, locked (DM privacy, Tron 2026-11-14; web #2075 dm-photo.js + dm-file.js):
 * cleaned (a GIF keeps only its frames, timing and loop count; anything else loses where it was
 * taken), encrypted with a fresh key, and the ciphertext uploaded as it is. The kind 15 message
 * for [com.nostrvault.service.DMService.sendMessage] comes back.
 */
object DMLockedPhoto {
    /** A picked photo before it's cleaned, as the web (dm-photo.js MAX_PHOTO). */
    const val MAX_PHOTO = 50L * 1024 * 1024
    const val TOO_BIG = "That photo is too big to send (at most 50 MB)."
    const val UNREADABLE = "Couldn't read that photo."

    class Unsendable(message: String) : Exception(message)

    /** Throws [Unsendable] for a photo that can't be read, [com.nostrvault.ui.screens.dm.DMPhotoUploadException] when no server took it. */
    suspend fun prepare(context: Context, uri: Uri, blossom: BlossomService): DMFile.Message {
        val (bytes, type) = withContext(Dispatchers.IO) { clean(context, uri) }
        val enc = withContext(Dispatchers.Default) { DMFile.encrypt(bytes) }
        val url = blossom.uploadLocked(enc.cipher, enc.x) ?: throw DMPhotoUploadException()
        return DMFile.fileMessage(url, enc, type)
    }

    /**
     * Sends [text] (if any) as a kind 14, then the photo or video locked as a kind 15 one second later so
     * it sorts below them (web dms.js sendMessage). [onWordsSent] runs once the words are out, so a
     * failed photo doesn't hand back words that already went.
     */
    suspend fun send(
        context: Context,
        uri: Uri,
        text: String,
        recipient: String,
        blossom: BlossomService,
        dmService: com.nostrvault.service.DMService,
        onWordsSent: () -> Unit = {},
    ) {
        // A video is locked the same way, compressed first (DMLockedVideo).
        val file = if (isVideo(context, uri)) DMLockedVideo.prepare(context, uri, blossom) else prepare(context, uri, blossom)
        var after = 0L
        if (text.isNotEmpty()) {
            dmService.sendMessage(recipient, text, false)
            onWordsSent()
            after = System.currentTimeMillis() / 1000 + 1
        }
        dmService.sendMessage(recipient, "", false, com.nostrvault.service.DMFileSend(file, after))
    }

    /** Whether [uri] is a video (locked too, compressed first: [DMLockedVideo]). */
    fun isVideo(context: Context, uri: Uri): Boolean =
        DMVideo.isVideoMime(context.contentResolver.getType(uri) ?: DMPastedImage.mimeType(uri))

    /** The bytes to lock and their type. */
    internal fun clean(context: Context, uri: Uri): Pair<ByteArray, String> {
        val resolver = context.contentResolver
        var temp = File.createTempFile("dm_lock_", ".tmp", context.cacheDir)
        try {
            val input = resolver.openInputStream(uri) ?: throw Unsendable(UNREADABLE)
            val size = try {
                input.use { copyCapped(it, temp) }
            } catch (e: IOException) {
                throw Unsendable(UNREADABLE)
            }
            if (size > HeapCap.of(MAX_PHOTO)) throw Unsendable(HeapCap.tooBigHere(MAX_PHOTO) ?: TOO_BIG)
            val head = temp.inputStream().use { s -> ByteArray(4).also { s.read(it) } }
            // A GIF by its own header, never by its type: a JPEG renamed .gif would otherwise go up as it is.
            if (GifStrip.isGif(head)) {
                val clean = try { GifStrip.strip(temp.readBytes()) } catch (e: GifStrip.NotAGif) { throw Unsendable(UNREADABLE) }
                return clean to "image/gif"
            }
            // Shrunk as Apple and web do for a DM (here 2048 px JPEG 82, no metadata, as every Android upload).
            val out = ImageCompressor.replacing(temp, resolver.getType(uri) ?: DMPastedImage.mimeType(uri) ?: "image/jpeg",
                ImageCompressor.Quality.STANDARD, context.cacheDir)
            temp = out.file
            val type = out.mimeType
            if (!MediaPrivacy.removeLocation(temp, type)) throw Unsendable(UNREADABLE)
            return temp.readBytes() to type
        } finally {
            temp.delete()
        }
    }

    /** Copies at most [MAX_PHOTO] + 1 bytes: the size, or more than the cap when it was bigger. */
    private fun copyCapped(input: java.io.InputStream, to: File): Long {
        var total = 0L
        to.outputStream().use { out ->
            val buf = ByteArray(64 * 1024)
            while (true) {
                val n = input.read(buf)
                if (n < 0) break
                total += n
                if (total > MAX_PHOTO) return total
                out.write(buf, 0, n)
            }
        }
        return total
    }
}

/** Strips a GIF [file] to its frames in place: true when it was a GIF, false when it was a broken one, null otherwise. */
internal fun stripGifInPlace(file: File): Boolean? {
    val head = file.inputStream().use { s -> ByteArray(4).also { s.read(it) } }
    if (!GifStrip.isGif(head)) return null
    return try {
        file.writeBytes(GifStrip.strip(file.readBytes()))
        true
    } catch (e: GifStrip.NotAGif) {
        false
    }
}
