package com.nostrvault.ui.components

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.nostrvault.service.BlossomService
import com.nostrvault.service.MediaCacheService
import com.nostrvault.service.MediaSaveService
import com.nostrvault.service.deleteEverywhereLeftover
import com.nostrvault.service.deleteOwnEvents
import com.nostrvault.ui.screens.DeleteScope
import com.nostrvault.ui.theme.*
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import javax.inject.Inject

@HiltViewModel
class FeedMediaMirrorViewModel @Inject constructor(
    private val blossomService: BlossomService,
    private val mediaCacheService: MediaCacheService,
    private val mediaSaveService: MediaSaveService,
    private val nostrService: com.nostrvault.service.NostrService,
    private val notificationManager: com.nostrvault.ui.notification.NotificationManager,
    @dagger.hilt.android.qualifiers.ApplicationContext private val appContext: android.content.Context,
) : ViewModel() {

    enum class SaveState { Idle, Saving, Saved }

    private val _saveState = MutableStateFlow(SaveState.Idle)
    val saveState = _saveState.asStateFlow()

    /** The URL on screen; a save that finishes after the user paged away leaves the new page's state alone. */
    private var openUrl: String? = null

    /**
     * Save the media on screen to the device gallery (MediaStore, no storage
     * permission on Android 10+). The lane gets one short line for it.
     * Port of iOS FeedMediaViewer.saveToPhotosTapped().
     */
    fun saveToGallery(url: String) {
        if (_saveState.value != SaveState.Idle) return
        viewModelScope.launch {
            _saveState.value = SaveState.Saving
            // Feed videos are recognised by extension, so that names the type
            // when the server only says application/octet-stream.
            val hint = if (isVideoUrl(url)) MediaSaveService.mimeTypeForExtension(url) else null
            // A blossom: link saves the file that hashed to it, not a URL.
            val result = if (com.nostrvault.data.model.BlossomUri.isUri(url)) {
                com.nostrvault.service.BlossomUriLoader.file(appContext, url)
                    ?.let { mediaSaveService.saveToGallery(it, hint) }
                    ?: Result.failure(Exception("Media unavailable"))
            } else {
                mediaSaveService.saveToGallery(url, hint)
            }
            if (openUrl == url) {
                _saveState.value = if (result.isSuccess) SaveState.Saved else SaveState.Idle
            }
            if (result.isSuccess) notificationManager.showToast("Saved to gallery") else notificationManager.showError("Couldn't save to gallery")
        }
    }

    sealed interface MirrorState {
        data object Idle : MirrorState
        data object Mirroring : MirrorState
        data object Mirrored : MirrorState
        data class Failed(val message: String) : MirrorState
    }

    private val _state = MutableStateFlow<MirrorState>(MirrorState.Idle)
    val state = _state.asStateFlow()

    /** False when there's no local relay to back media up to — hides the button entirely. */
    val canMirror: Boolean get() = blossomService.localBlossomURL() != null

    /**
     * Called when a media URL is opened in the viewer. If the URL is hash-based and
     * the blob is already in the local Blossom store, start in the "Mirrored" state;
     * otherwise offer the mirror action. Mirrors iOS FeedMediaViewer.updateMirrorStatus().
     */
    fun onOpen(url: String) {
        openUrl = url
        _saveState.value = SaveState.Idle
        val hash = extractSha256(url)
        _state.value = if (hash != null && mediaCacheService.isInLocalBlossom(hash)) {
            MirrorState.Mirrored
        } else {
            MirrorState.Idle
        }
    }

    fun mirror(url: String) {
        if (_state.value is MirrorState.Mirroring) return
        viewModelScope.launch {
            _state.value = MirrorState.Mirroring
            val sha = withContext(Dispatchers.IO) { blossomService.mirrorUrlToLocal(url) }
            _state.value = if (sha != null) MirrorState.Mirrored else MirrorState.Failed("Mirror failed")
        }
    }

    private val _deleting = MutableStateFlow(false)
    /** True while a delete from the long-press bar is running. */
    val deleting = _deleting.asStateFlow()

    /** How many of your loaded posts link the blob at [url]; Delete everywhere offers to delete them too. */
    fun postsUsing(url: String): Int =
        extractSha256(url)?.let { nostrService.ownEvents(referencingBlob = it).size } ?: 0

    /** Whether [url] names a Blossom blob, so the long-press delete bar can act on it. */
    fun canDelete(url: String): Boolean = extractSha256(url) != null

    /**
     * Delete from the long-press bar. Port of iOS FeedMediaViewer
     * deleteFromMirrorsTapped / deleteEverywhereTapped, with Android's
     * per-server report: the lane names anything left behind, [onDone] runs
     * once the result is in, and [onAllGone] runs only when Delete everywhere
     * left nothing, so the viewer closes then and stays open otherwise.
     */
    fun delete(
        url: String,
        scope: DeleteScope,
        deletePosts: Boolean,
        onDone: () -> Unit,
        onAllGone: () -> Unit,
    ) {
        fun onMessage(message: String, ok: Boolean) {
            if (ok) notificationManager.showToast(message) else notificationManager.showError(message)
            onDone()
        }
        val sha = extractSha256(url) ?: return onMessage("Could not extract hash from URL", ok = false)
        if (_deleting.value) return
        viewModelScope.launch {
            _deleting.value = true
            try {
                when (scope) {
                    DeleteScope.MIRRORS -> {
                        val report = withContext(Dispatchers.IO) { blossomService.deleteFromMirrors(sha) }
                        refreshCloudBadges(sha)
                        when {
                            report.allDeleted -> onMessage("Deleted from mirrors", ok = true)
                            report.failed.isEmpty() -> onMessage("No mirrors to delete from", ok = true)
                            else -> onMessage(deleteEverywhereLeftover(localDeleted = true, mirrors = report)!!, ok = false)
                        }
                    }
                    DeleteScope.EVERYWHERE -> {
                        // Posts first: if they can't be deleted (signing failed),
                        // keep the file too rather than leave them broken.
                        if (deletePosts && nostrService.deleteOwnEvents(referencingBlob = sha) == 0) {
                            onMessage("Couldn't delete the post, so the file was kept. Try again.", ok = false)
                            return@launch
                        }
                        val (localOk, report) = withContext(Dispatchers.IO) {
                            val local = async { blossomService.deleteFromLocal(sha) }
                            val mirrors = async { blossomService.deleteFromMirrors(sha) }
                            local.await() to mirrors.await()
                        }
                        refreshCloudBadges(sha)
                        val leftover = deleteEverywhereLeftover(localDeleted = localOk, mirrors = report)
                        onMessage(leftover ?: "Deleted everywhere", ok = leftover == null)
                        if (leftover == null) onAllGone()
                    }
                }
                if (openUrl == url) onOpen(url)
            } finally {
                _deleting.value = false
            }
        }
    }

    /**
     * The cloud badges cache each server's answer for the session; ask again
     * after a delete so they stop showing the pre-delete count. iOS
     * FeedMediaViewer does the same through BlossomBackupStore.refresh.
     */
    private suspend fun refreshCloudBadges(sha: String) {
        blossomService.checkMirrorPresence(sha, force = true)
    }

    /** Extract a 64-hex sha256 from a Blossom-style URL, or null. Mirrors iOS extractSHA256FromURL(). */
    private fun extractSha256(url: String): String? {
        val last = url.substringAfterLast('/').substringBefore('?').substringBefore('#')
        val bare = last.substringBeforeLast('.')
        if (bare.length == 64 && bare.all { it.isDigit() || it in 'a'..'f' || it in 'A'..'F' }) {
            return bare.lowercase()
        }
        return Regex("[a-fA-F0-9]{64}").find(url)?.value?.lowercase()
    }
}
