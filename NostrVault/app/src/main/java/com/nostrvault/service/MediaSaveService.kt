package com.nostrvault.service

import android.content.ContentValues
import android.content.Context
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.util.Log
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.File
import java.util.concurrent.TimeUnit
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Saves media (images/videos) to the device gallery via MediaStore.
 */
@Singleton
class MediaSaveService @Inject constructor(
    @ApplicationContext private val context: Context,
) {
    companion object {
        private const val TAG = "MediaSaveService"

        /**
         * The type to file a download under. A caller's image/video hint wins,
         * then the server's Content-Type, then the URL's extension. Blossom
         * servers often answer `application/octet-stream`, and trusting that
         * (or defaulting to JPEG) would file a video as a broken photo.
         * Null when the hint names something the gallery cannot hold (audio,
         * a document).
         */
        internal fun resolveMimeType(hint: String?, contentType: String?, url: String): String? {
            fun clean(type: String?): String? = type?.substringBefore(';')?.trim()?.lowercase()?.ifEmpty { null }
            fun media(type: String?): String? = clean(type)?.takeIf { it.startsWith("image/") || it.startsWith("video/") }
            val cleanHint = clean(hint)
            if (cleanHint != null && media(cleanHint) == null && cleanHint != "application/octet-stream") return null
            return media(cleanHint) ?: media(contentType) ?: mimeTypeForExtension(url) ?: "image/jpeg"
        }

        /** image/video type for a URL's file extension, or null when it has none we know. */
        internal fun mimeTypeForExtension(url: String): String? {
            val ext = url.substringBefore('?').substringBefore('#')
                .substringAfterLast('/').substringAfterLast('.', "").lowercase()
            return when (ext) {
                "jpg", "jpeg" -> "image/jpeg"
                "png" -> "image/png"
                "gif" -> "image/gif"
                "webp" -> "image/webp"
                "heic" -> "image/heic"
                "avif" -> "image/avif"
                "mp4", "m4v" -> "video/mp4"
                "mov" -> "video/quicktime"
                "webm" -> "video/webm"
                "mkv" -> "video/x-matroska"
                else -> null
            }
        }

        internal fun extensionForMimeType(mimeType: String): String {
            val type = mimeType.substringBefore(';').trim().lowercase()
            return when (type) {
                "image/jpeg" -> "jpg"
                "image/png" -> "png"
                "image/gif" -> "gif"
                "image/webp" -> "webp"
                "image/heic" -> "heic"
                "image/avif" -> "avif"
                "video/mp4" -> "mp4"
                "video/quicktime" -> "mov"
                "video/webm" -> "webm"
                "video/x-matroska" -> "mkv"
                "audio/mpeg", "audio/mp3" -> "mp3"
                "audio/mp4", "audio/x-m4a" -> "m4a"
                "audio/aac" -> "aac"
                "audio/wav", "audio/x-wav" -> "wav"
                "audio/ogg" -> "ogg"
                "audio/opus" -> "opus"
                "audio/flac" -> "flac"
                else -> when {
                    type.startsWith("video/") -> "mp4"
                    type.startsWith("audio/") -> "mp3"
                    else -> "jpg"
                }
            }
        }
    }

    private val httpClient = OkHttpClient.Builder()
        .connectTimeout(30, TimeUnit.SECONDS)
        .readTimeout(60, TimeUnit.SECONDS)
        .build()

    /**
     * Save a local file to the device gallery.
     */
    suspend fun saveToGallery(file: File, mimeType: String?): Result<Unit> = withContext(Dispatchers.IO) {
        try {
            file.inputStream().use { input ->
                saveStream(input, file.name, mimeType ?: guessMimeType(file.name))
            }
        } catch (e: Exception) {
            Log.e(TAG, "Save file to gallery failed", e)
            Result.failure(e)
        }
    }

    /**
     * Download from a URL and save to the device gallery.
     * Streams the body straight to MediaStore — never buffers the whole (possibly
     * large video) blob in memory, which would OOM low-RAM devices.
     */
    suspend fun saveToGallery(url: String, mimeType: String?): Result<Unit> = withContext(Dispatchers.IO) {
        try {
            val request = Request.Builder().url(url).get().build()
            httpClient.newCall(request).execute().use { response ->
                if (!response.isSuccessful) {
                    return@withContext Result.failure(Exception("Download failed: ${response.code}"))
                }
                val body = response.body
                    ?: return@withContext Result.failure(Exception("Empty response"))
                val contentType = resolveMimeType(mimeType, response.header("Content-Type"), url)
                    ?: return@withContext Result.failure(Exception("Only photos and videos can be saved to the gallery"))
                val filename = url.substringAfterLast('/').take(12)
                body.byteStream().use { input -> saveStream(input, filename, contentType) }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Save URL to gallery failed", e)
            Result.failure(e)
        }
    }

    private fun saveStream(input: java.io.InputStream, filename: String, mimeType: String): Result<Unit> {
        val isVideo = mimeType.startsWith("video")
        val extension = extensionForMimeType(mimeType)
        val collection = if (isVideo) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
            } else {
                MediaStore.Video.Media.EXTERNAL_CONTENT_URI
            }
        } else {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
            } else {
                MediaStore.Images.Media.EXTERNAL_CONTENT_URI
            }
        }

        val displayName = "NostrVault_${System.currentTimeMillis()}.$extension"

        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, displayName)
            put(MediaStore.MediaColumns.MIME_TYPE, mimeType)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val subdir = if (isVideo) Environment.DIRECTORY_MOVIES else Environment.DIRECTORY_PICTURES
                put(MediaStore.MediaColumns.RELATIVE_PATH, "$subdir/NostrVault")
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
        }

        val resolver = context.contentResolver
        val uri = resolver.insert(collection, values)
            ?: return Result.failure(Exception("Failed to create MediaStore entry"))

        return try {
            resolver.openOutputStream(uri)?.use { input.copyTo(it) }
                ?: return Result.failure(Exception("Failed to open output stream"))

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                values.clear()
                values.put(MediaStore.MediaColumns.IS_PENDING, 0)
                resolver.update(uri, values, null, null)
            }
            Result.success(Unit)
        } catch (e: Exception) {
            resolver.delete(uri, null, null)
            Result.failure(e)
        }
    }

    private fun guessMimeType(filename: String): String = mimeTypeForExtension(filename) ?: "image/jpeg"
}
