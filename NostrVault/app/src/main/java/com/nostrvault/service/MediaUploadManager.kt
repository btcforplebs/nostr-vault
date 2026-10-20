package com.nostrvault.service

import android.content.ContentResolver
import android.content.Context
import android.net.Uri
import android.util.Log
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.ui.notification.NotificationManager
import dagger.hilt.android.qualifiers.ApplicationContext
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
    @ApplicationContext private val context: Context,
    private val blossomService: BlossomService,
    private val notificationManager: NotificationManager,
    private val mediaCacheService: MediaCacheService,
    private val configStore: ConfigStore,
) {
    companion object {
        private const val TAG = "MediaUploadManager"
        const val REFUSED_MESSAGE = "That file can't be uploaded"
    }

    /**
     * Whether a URI another app shared may be read for an upload: only another
     * app's content provider ([isReadableShare]). The provider is looked up so
     * one of ours is refused whatever its name.
     */
    fun acceptsShare(uri: Uri): Boolean {
        val host = shareHost(uri.authority)
        val owner = host?.let { runCatching { context.packageManager.resolveContentProvider(it, 0)?.packageName }.getOrNull() }
        return isReadableShare(uri.scheme, uri.authority, owner, context.packageName)
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
        // Checked here too, so no caller can hand us one of our own files.
        if (!acceptsShare(uri)) {
            Log.w(TAG, "Refused a shared URI that is not another app's content")
            notificationManager.showError(REFUSED_MESSAGE)
            return
        }
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
            if (!MediaPrivacy.removeLocation(tempFile, contentType)) {
                notificationManager.markUploadFailed(uploadId, MediaPrivacy.FAILURE_MESSAGE)
                return
            }
            val sha256 = blossomService.computeSHA256(tempFile)

            notificationManager.updateUploadProgress(uploadId, 0.3f)

            // Vault save: local storage counts as success even if mirrors are down.
            val resultUrl = blossomService.uploadAndMirror(tempFile, sha256, contentType, allowLocalFallback = true)

            notificationManager.updateUploadProgress(uploadId, 1.0f)

            val localBase = blossomService.localBlossomURL()
            // A public external Blossom (Nostr Vault for Mac on a domain) is
            // not "local only" even though its URL is localBase.
            val isLocalOnly = resultUrl != null && localBase != null && resultUrl.startsWith(localBase) &&
                com.nostrvault.relay.isPrivateNetworkURL(localBase)
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

/**
 * Whether a shared URI may be read for an upload. Only `content://` from
 * another app's provider: a `file://` URI, or one naming a provider of ours,
 * is opened with this app's own permissions, so any app could have us upload
 * our private files (the config, with its keys) to Blossom. [providerPackage]
 * is who the system says owns the authority, or null when it can't see it
 * (another app's provider can be hidden by package visibility).
 */
internal fun isReadableShare(scheme: String?, authority: String?, providerPackage: String?, ownPackage: String): Boolean {
    if (!scheme.equals("content", ignoreCase = true)) return false
    val host = shareHost(authority) ?: return false
    val own = ownPackage.lowercase()
    if (host == own || host.startsWith("$own.")) return false
    return providerPackage != ownPackage
}

/** The provider part of an authority, without a cross-profile `userId@` prefix. */
internal fun shareHost(authority: String?): String? =
    authority?.substringAfterLast('@')?.trim()?.lowercase()?.takeIf { it.isNotEmpty() }

/**
 * The URIs in a share's `EXTRA_STREAM`: one or a list, as the sender put it.
 * Anything that isn't a [Uri] is dropped rather than cast, so a malformed
 * share (a list of path strings) can't crash the app.
 */
internal fun sharedStreamUris(stream: Any?): List<Uri> = when (stream) {
    is Uri -> listOf(stream)
    is Iterable<*> -> stream.filterIsInstance<Uri>()
    else -> emptyList()
}
