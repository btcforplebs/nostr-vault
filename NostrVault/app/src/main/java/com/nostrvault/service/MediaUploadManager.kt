package com.nostrvault.service

import android.content.ContentResolver
import android.net.Uri
import android.util.Log
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.ui.notification.NotificationManager
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.File
import java.util.concurrent.atomic.AtomicInteger
import javax.inject.Inject
import javax.inject.Singleton

/**
 * App-scoped media upload coordinator. Owns the "pick/share a file → Blossom"
 * pipeline so it can be driven from both the media gallery UI and the system
 * share sheet (ACTION_SEND), and so an upload survives the gallery screen being
 * closed.
 *
 * Uploads are SERIALIZED: each upload signs a BUD-02 auth event, and external
 * signers (Amber NIP-55) process one signing request at a time — concurrent
 * uploads would collide. Sharing multiple images therefore uploads them one by
 * one.
 */
@Singleton
class MediaUploadManager @Inject constructor(
    private val blossomService: BlossomService,
    private val notificationManager: NotificationManager,
    private val mediaCacheService: MediaCacheService,
    private val configStore: ConfigStore,
) {
    companion object {
        private const val TAG = "MediaUploadManager"
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val uploadMutex = Mutex()
    private val pending = AtomicInteger(0)

    private val _isUploading = MutableStateFlow(false)
    val isUploading: StateFlow<Boolean> = _isUploading.asStateFlow()

    private val _uploadCompleted = MutableSharedFlow<Unit>(extraBufferCapacity = 1)
    /** Emits after each successful upload so observers (e.g. the gallery) can refresh. */
    val uploadCompleted: SharedFlow<Unit> = _uploadCompleted.asSharedFlow()

    /**
     * Upload one media item from a content URI. Fire-and-forget — progress and the
     * final result are surfaced via [NotificationManager]. Multiple calls queue and
     * run serially.
     */
    fun upload(uri: Uri, contentResolver: ContentResolver) {
        pending.incrementAndGet()
        _isUploading.value = true
        scope.launch {
            try {
                uploadMutex.withLock { runUpload(uri, contentResolver) }
            } finally {
                if (pending.decrementAndGet() == 0) _isUploading.value = false
            }
        }
    }

    private suspend fun runUpload(uri: Uri, contentResolver: ContentResolver) {
        val filename = uri.lastPathSegment ?: "media"
        val uploadId = notificationManager.addUpload(filename)
        // Stream the source to a temp file rather than readBytes() — a large video
        // pulled fully into a ByteArray OOM-kills low-RAM devices. The File upload
        // path streams from disk end to end.
        var tempFile: File? = null
        try {
            tempFile = run {
                val f = File.createTempFile("upload_", null, mediaCacheService.cacheDirectory)
                val copied = contentResolver.openInputStream(uri)?.use { input ->
                    f.outputStream().use { output -> input.copyTo(output, 64 * 1024) }
                    true
                } ?: false
                if (copied) f else { f.delete(); null }
            } ?: run {
                notificationManager.markUploadFailed(uploadId, "Could not read file")
                return
            }

            val contentType = contentResolver.getType(uri) ?: "application/octet-stream"
            val sha256 = blossomService.computeSHA256(tempFile)

            notificationManager.updateUploadProgress(uploadId, 0.3f)

            val resultUrl = blossomService.uploadAndMirror(tempFile, sha256, contentType)

            notificationManager.updateUploadProgress(uploadId, 1.0f)

            val localBase = blossomService.localBlossomURL()
            val isLocalOnly = resultUrl != null && localBase != null && resultUrl.startsWith(localBase)
            val hasMirrors = configStore.config.value.activeBlossomMirrors.isNotEmpty()

            when {
                resultUrl != null && !isLocalOnly -> {
                    notificationManager.markUploadSuccess(uploadId)
                    _uploadCompleted.tryEmit(Unit)
                }
                isLocalOnly -> {
                    notificationManager.markUploadSuccess(uploadId)
                    if (hasMirrors) notificationManager.showToast("Saved locally — mirrors unavailable")
                    _uploadCompleted.tryEmit(Unit)
                }
                else -> {
                    notificationManager.markUploadFailed(uploadId, "Upload failed — relay not running")
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Upload failed", e)
            notificationManager.markUploadFailed(uploadId, e.message ?: "Upload failed")
        } finally {
            tempFile?.let { withContext(NonCancellable) { it.delete() } }
        }
    }
}
