package com.nostrvault.ui.screens

import android.net.Uri
import android.util.Log
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.nostrvault.service.MediaPrivacy
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.service.*
import com.nostrvault.ui.notification.ErrorStyle
import com.nostrvault.ui.notification.NotificationManager
import com.nostrvault.ui.theme.*
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.serialization.json.Json
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.File
import java.util.concurrent.TimeUnit
import javax.inject.Inject

/**
 * Media gallery showing personal blossom content from local and external blossoms.
 * Port of MediaTabView.swift.
 */

@HiltViewModel
class MediaGalleryViewModel @Inject constructor(
    private val configStore: ConfigStore,
    private val nostrService: NostrService,
    private val statsService: StatsService,
    val mediaCacheService: MediaCacheService,
    private val blossomService: BlossomService,
    private val notificationManager: NotificationManager,
    blobNoteIndexStore: com.nostrvault.data.local.BlobNoteIndexStore,
) : ViewModel() {

    private val _isLoading = MutableStateFlow(false)
    val isLoading = _isLoading.asStateFlow()

    private val _isUploading = MutableStateFlow(false)
    val isUploading = _isUploading.asStateFlow()

    private val _mediaItems = MutableStateFlow<List<BlossomMediaItem>>(emptyList())
    val mediaItems = _mediaItems.asStateFlow()

    private val json = Json { ignoreUnknownKeys = true }

    private val httpClient = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(10, TimeUnit.SECONDS)
        .build()

    init {
        loadBlossomMedia()
        // Auto-Mirror Media: pull own media from the mirrors (iOS triggerAutoMirrorIfEnabled).
        if (configStore.config.value.autoMirrorMedia) blossomService.runMirror()
    }

    fun refresh() {
        blossomService.forgetMirrorPresence()
        loadBlossomMedia()
    }

    /** hash → author of the note that posted the blob, where one has been seen. */
    val blobAuthors = blobNoteIndexStore.authors

    /** The pubkey a tile's Report Media / Block User acts on, or null to hide them. */
    fun moderationTarget(sha256: String, authors: Map<String, String>): String? =
        mediaModerationTarget(authors[sha256.lowercase()], nostrService.ownerHexPubkey, nostrService.activeHexPubkey)

    /**
     * NIP-56 report of a blob's author. A blob has no event to name, so it is
     * a user report, as iOS's UGCReportingDialog sends with no event id. The
     * caller also blocks, as reporting does everywhere else in the app.
     */
    fun reportAuthor(pubkey: String, reason: String, description: String) {
        nostrService.reportUser(pubkey, reason, description.ifBlank { null })
    }

    /** Each Blossom server's answer per blob; the tile badges read this. */
    val mirrorPresence = blossomService.mirrorPresence

    /** The user's outside Blossom servers, so badges re-check when one is added. */
    val blossomMirrors = configStore.config
        .map { it.activeBlossomMirrors }
        .distinctUntilChanged()
        .stateIn(viewModelScope, SharingStarted.Eagerly, configStore.config.value.activeBlossomMirrors)

    fun backupSummary(sha256: String, presence: Map<String, Map<String, BlobPresence>>): BlossomBackupSummary? =
        blossomService.backupSummary(sha256, presence)

    /** Asks the servers about [sha256] once per session (or after a refresh). */
    suspend fun checkBackup(sha256: String) {
        blossomService.checkMirrorPresence(sha256)
    }

    private val _busySha = MutableStateFlow<String?>(null)
    /** The blob being saved or mirrored from the menu right now, or null. */
    val busySha = _busySha.asStateFlow()

    /**
     * Uploads a file already on this phone to the servers not known to have
     * it, then re-checks so the badge shows the new count. Port of iOS
     * `MediaBackupActions.mirrorMissing`.
     */
    fun mirrorMissing(item: BlossomMediaItem) {
        if (_busySha.value != null) return
        viewModelScope.launch {
            _busySha.value = item.sha256
            try {
                val result = blossomService.pushToMissing(item.sha256)
                when (result) {
                    null -> notificationManager.showToast("Already on all your Blossom servers")
                    is BlossomService.MirrorPushResult.AllAccepted -> notificationManager.showToast(result.message)
                    is BlossomService.MirrorPushResult.Partial -> notificationManager.showError(result.message, ErrorStyle.WARNING)
                    else -> notificationManager.showError(result.message)
                }
            } finally {
                _busySha.value = null
            }
        }
    }

    /**
     * Stores a file that is only on outside servers in the vault on this
     * phone, then uploads it to any server that lacks it. Port of iOS
     * `MediaBackupActions.saveToVault`.
     */
    fun saveToVault(item: BlossomMediaItem) {
        if (_busySha.value != null) return
        viewModelScope.launch {
            _busySha.value = item.sha256
            try {
                val outcome = blossomService.saveUrlToVault(item.displayUrl).outcome
                if (outcome == BlossomService.VaultSave.FAILED) {
                    notificationManager.showError(outcome.message)
                    return@launch
                }
                notificationManager.showToast(outcome.message)
                loadBlossomMedia()
            } finally {
                _busySha.value = null
            }
        }
    }

    private fun loadBlossomMedia() {
        viewModelScope.launch {
            _isLoading.value = true
            try {
                withContext(Dispatchers.IO) {
                    val items = mutableMapOf<String, BlossomMediaItem>()

                    // 1. Scan local blossom directory
                    loadLocalBlossomFiles(items)

                    // 2. Fetch from local relay via BUD-04
                    val pubkey = nostrService.ownerHexPubkey
                    if (pubkey.isNotEmpty()) {
                        try {
                            val localBlobs = statsService.fetchBlobList(pubkey)
                            mergeBlobs(items, localBlobs, source = null)
                        } catch (e: Exception) {
                            Log.w(TAG, "Local relay blob list failed: ${e.message}")
                        }

                        // 3. Fetch from external mirrors in parallel
                        val mirrors = configStore.config.value.activeBlossomMirrors
                        coroutineScope {
                            mirrors.map { mirror ->
                                async {
                                    try {
                                        fetchMirrorBlobList(mirror, pubkey) to mirror
                                    } catch (e: Exception) {
                                        Log.w(TAG, "Mirror list from $mirror failed: ${e.message}")
                                        null
                                    }
                                }
                            }.awaitAll().filterNotNull().forEach { (blobs, source) ->
                                mergeBlobs(items, blobs, source = source)
                            }
                        }
                    }

                    _mediaItems.value = items.values
                        .filter { it.isImage || it.isVideo || it.isAudio || it.mimeType == null }
                        .sortedByDescending { it.sortTime }
                        .toList()
                }
            } finally {
                _isLoading.value = false
            }
        }
    }

    private fun loadLocalBlossomFiles(items: MutableMap<String, BlossomMediaItem>) {
        val config = configStore.config.value
        val blossomDir = config.relayDataDir?.let { File(it, config.blossomPath) } ?: return
        if (!blossomDir.exists()) return

        blossomDir.listFiles()?.forEach { file ->
            if (!file.isFile) return@forEach
            val hash = file.nameWithoutExtension
            if (hash.length != 64 || !hash.all { it in "0123456789abcdef" }) return@forEach

            val fileType = statsService.detectFileType(file)

            items[hash] = BlossomMediaItem(
                sha256 = hash,
                displayUrl = file.absolutePath,
                localFile = file,
                mimeType = when (fileType) {
                    FileType.IMAGE -> "image"
                    FileType.VIDEO -> "video"
                    else -> null
                },
                size = file.length(),
                uploaded = null,
                lastModified = file.lastModified(),
                isLocal = true,
            )
        }
    }

    private fun mergeBlobs(
        items: MutableMap<String, BlossomMediaItem>,
        blobs: List<BlobDescriptor>,
        source: String?,
    ) {
        for (blob in blobs) {
            val hash = blob.sha256 ?: continue
            val existing = items[hash]
            if (existing != null) {
                // Merge metadata from server into existing local item
                items[hash] = existing.copy(
                    uploaded = blob.uploaded ?: existing.uploaded,
                    mimeType = blob.type ?: existing.mimeType,
                    size = blob.size ?: existing.size,
                )
            } else {
                // Remote-only item
                val url = blob.url ?: source?.let { "$it/$hash" } ?: continue
                items[hash] = BlossomMediaItem(
                    sha256 = hash,
                    displayUrl = url,
                    localFile = null,
                    mimeType = blob.type,
                    size = blob.size,
                    uploaded = blob.uploaded,
                    lastModified = null,
                    isLocal = false,
                )
            }
        }
    }

    private fun fetchMirrorBlobList(mirror: String, pubkey: String): List<BlobDescriptor> {
        val request = Request.Builder()
            .url("$mirror/list/$pubkey")
            .get()
            .build()

        val response = httpClient.newCall(request).execute()
        if (!response.isSuccessful) return emptyList()

        val body = response.body?.string() ?: return emptyList()
        return json.decodeFromString<List<BlobDescriptor>>(body)
    }

    /**
     * Uploads every picked file in turn (iOS photo picker and file importer
     * both allow several), then reloads once.
     */
    fun uploadMedia(uris: List<Uri>, contentResolver: android.content.ContentResolver) {
        if (_isUploading.value || uris.isEmpty()) return
        viewModelScope.launch {
            _isUploading.value = true
            try {
                var anySaved = false
                for (uri in uris) {
                    if (uploadOne(uri, contentResolver)) anySaved = true
                }
                if (anySaved) refresh()
            } finally {
                _isUploading.value = false
            }
        }
    }

    /**
     * Port of iOS `handlePasteFromClipboard`: an image on the clipboard is
     * uploaded like a picked file; an http(s) link is downloaded into the
     * vault; anything else says why nothing happened.
     */
    fun pasteFromClipboard(context: android.content.Context) {
        val clipboard = context.getSystemService(android.content.Context.CLIPBOARD_SERVICE)
            as? android.content.ClipboardManager
        val item = clipboard?.primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0)
        val uri = item?.uri
        if (uri != null) {
            uploadMedia(listOf(uri), context.contentResolver)
            return
        }
        val text = item?.text?.toString()?.trim()
        if (text.isNullOrEmpty()) {
            notificationManager.showError("Clipboard is empty or contains unsupported content", ErrorStyle.WARNING)
            return
        }
        val url = pastedMediaUrl(text)
        if (url == null) {
            notificationManager.showError("Clipboard does not contain a valid URL or image", ErrorStyle.WARNING)
            return
        }
        if (_isUploading.value) return
        viewModelScope.launch {
            _isUploading.value = true
            val filename = url.substringBefore('?').substringBefore('#')
                .substringAfterLast('/').ifEmpty { "pasted-media" }
            val uploadId = notificationManager.addUpload(filename)
            try {
                if (blossomService.mirrorUrlToLocal(url) != null) {
                    notificationManager.markUploadSuccess(uploadId)
                    refresh()
                } else {
                    notificationManager.markUploadFailed(uploadId, "Failed to paste media")
                }
            } finally {
                _isUploading.value = false
            }
        }
    }

    /** True when the file reached the vault. Progress and failure go to the upload notification. */
    private suspend fun uploadOne(uri: Uri, contentResolver: android.content.ContentResolver): Boolean {
        val filename = uri.lastPathSegment ?: "media"
        val uploadId = notificationManager.addUpload(filename)
        // Stream the picked media to a temp file instead of readBytes() — a
        // large video pulled fully into a ByteArray OOM-kills low-RAM devices
        // before the upload even starts. The File-based upload path streams
        // from disk (file.asRequestBody) end to end.
        var tempFile: File? = null
        try {
            tempFile = withContext(Dispatchers.IO) {
                val f = File.createTempFile("upload_", null, mediaCacheService.cacheDirectory)
                val copied = contentResolver.openInputStream(uri)?.use { input ->
                    f.outputStream().use { output -> input.copyTo(output, 64 * 1024) }
                    true
                } ?: false
                if (copied) f else { f.delete(); null }
            } ?: run {
                notificationManager.markUploadFailed(uploadId, "Could not read file")
                return false
            }

            val contentType = contentResolver.getType(uri) ?: "application/octet-stream"
            if (!withContext(Dispatchers.IO) { MediaPrivacy.removeLocation(tempFile!!, contentType) }) {
                notificationManager.markUploadFailed(uploadId, MediaPrivacy.FAILURE_MESSAGE)
                return false
            }
            val sha256 = withContext(Dispatchers.IO) {
                blossomService.computeSHA256(tempFile!!)
            }

            notificationManager.updateUploadProgress(uploadId, 0.3f)

            val resultUrl = withContext(Dispatchers.IO) {
                // Vault save: local storage counts as success even if mirrors are down.
                blossomService.uploadAndMirror(tempFile!!, sha256, contentType, allowLocalFallback = true)
            }

            notificationManager.updateUploadProgress(uploadId, 1.0f)

            return if (resultUrl != null || blossomService.localBlossomURL() != null) {
                notificationManager.markUploadSuccess(uploadId)
                true
            } else {
                notificationManager.markUploadFailed(uploadId, "Upload failed")
                false
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Log.e(TAG, "Upload failed", e)
            notificationManager.markUploadFailed(uploadId, e.message ?: "Upload failed")
            return false
        } finally {
            tempFile?.let { withContext(NonCancellable + Dispatchers.IO) { it.delete() } }
        }
    }

    companion object {
        private const val TAG = "MediaGalleryVM"
    }
}
