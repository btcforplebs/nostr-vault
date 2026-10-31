package com.nostrvault.ui.screens

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.service.BlossomService
import com.nostrvault.service.MediaCacheService
import com.nostrvault.service.MediaSaveService
import com.nostrvault.service.NostrService
import com.nostrvault.service.deleteEverywhereLeftover
import com.nostrvault.service.deleteOwnEvents
import com.nostrvault.ui.notification.ErrorStyle
import com.nostrvault.ui.notification.NotificationManager
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
class MediaViewerViewModel @Inject constructor(
    private val mediaSaveService: MediaSaveService,
    private val notificationManager: NotificationManager,
    private val blossomService: BlossomService,
    private val configStore: ConfigStore,
    private val nostrService: NostrService,
    private val mediaCacheService: MediaCacheService,
) : ViewModel() {

    private val _mirrorStatus = MutableStateFlow<Map<String, Boolean>>(emptyMap())
    val mirrorStatus = _mirrorStatus.asStateFlow()

    private val _isCheckingMirrors = MutableStateFlow(false)
    val isCheckingMirrors = _isCheckingMirrors.asStateFlow()

    val totalMirrors: Int
        get() = configStore.config.value.activeBlossomMirrors.size

    /** The blob the viewer is showing, so a late push result doesn't re-check another page. */
    private var currentSha: String? = null

    fun checkMirrors(sha256: String) {
        currentSha = sha256
        viewModelScope.launch {
            _isCheckingMirrors.value = true
            _mirrorStatus.value = emptyMap()
            try {
                val status = withContext(Dispatchers.IO) {
                    blossomService.checkMirrorStatus(sha256)
                }
                _mirrorStatus.value = status
            } finally {
                _isCheckingMirrors.value = false
            }
        }
    }

    /** The blob being pushed right now, or null. */
    private val _pushingSha = MutableStateFlow<String?>(null)
    val pushingSha = _pushingSha.asStateFlow()

    /**
     * Upload the blob to the servers the last check found without it (all of
     * them when nothing has been checked yet), then report what actually
     * happened and re-check.
     */
    fun pushToMirrors(sha256: String) {
        if (_pushingSha.value != null) return
        // The status map belongs to the page on screen, which is this blob.
        val missing = if (currentSha == sha256) _mirrorStatus.value.filterValues { !it }.keys else emptySet()
        viewModelScope.launch {
            _pushingSha.value = sha256
            val result = try {
                withContext(Dispatchers.IO) {
                    blossomService.pushLocalToMirrors(sha256, only = missing.ifEmpty { null })
                }
            } finally {
                _pushingSha.value = null
            }
            announcePush(result)
            if (currentSha == sha256) checkMirrors(sha256)
        }
    }

    private fun announcePush(result: BlossomService.MirrorPushResult) {
        when (result) {
            is BlossomService.MirrorPushResult.AllAccepted -> notificationManager.showToast(result.message)
            is BlossomService.MirrorPushResult.Partial -> notificationManager.showError(result.message, ErrorStyle.WARNING)
            else -> notificationManager.showError(result.message)
        }
    }

    /**
     * What a delete left behind, shown in the viewer until tapped. A failure
     * that timed out with the viewer was gone before anyone could read it.
     */
    private val _deleteLeftover = MutableStateFlow<String?>(null)
    val deleteLeftover = _deleteLeftover.asStateFlow()

    fun dismissDeleteLeftover() {
        _deleteLeftover.value = null
    }

    /**
     * Report a failed delete: in the viewer's own banner when [sticky], so it
     * stays until tapped, otherwise as a longer-lived warning pill.
     */
    private fun reportLeftover(message: String, sticky: Boolean) {
        if (sticky) _deleteLeftover.value = message
        else notificationManager.showError(message, ErrorStyle.WARNING, autoDismissMs = 6_000L)
    }

    /** Delete the blob from all external mirrors; the local copy is kept. [onDone] runs after. */
    fun deleteFromMirrors(item: BlossomMediaItem, sticky: Boolean = false, onDone: () -> Unit = {}) {
        if (item.sha256.isEmpty()) {
            notificationManager.showError("No hash for this item")
            return
        }
        _deleteLeftover.value = null
        viewModelScope.launch {
            val report = withContext(Dispatchers.IO) { blossomService.deleteFromMirrors(item.sha256) }
            when {
                report.allDeleted -> notificationManager.showToast("Deleted from mirrors")
                report.failed.isEmpty() -> notificationManager.showError("No mirrors to delete from")
                else -> reportLeftover(deleteEverywhereLeftover(localDeleted = true, mirrors = report)!!, sticky)
            }
            checkMirrors(item.sha256)
            onDone()
        }
    }

    /** Each Blossom server's answer per blob, for "Couldn't reach N servers". */
    val mirrorPresence = blossomService.mirrorPresence

    fun backupSummary(sha256: String, presence: Map<String, Map<String, com.nostrvault.service.BlobPresence>>) =
        blossomService.backupSummary(sha256, presence)

    /** Bumped after a save or cache, so the source badge reads the disk again. */
    private val _sourceVersion = MutableStateFlow(0)
    val sourceVersion = _sourceVersion.asStateFlow()

    /**
     * The hash each Save to Vault stored its bytes under, by the item's own
     * hash. A server may serve bytes that hash differently from what it
     * listed; the badge still reads On phone after the save.
     */
    private val savedShas = SavedVaultHashes()

    /**
     * Where the viewer's copy of [item] lives. Port of iOS
     * `MediaCacheService.getSource(for:)`. Reads the disk, so off the main thread.
     */
    suspend fun source(item: BlossomMediaItem): MediaCacheService.MediaSource = withContext(Dispatchers.IO) {
        val hashes = listOfNotNull(item.sha256.ifEmpty { null }, savedShas.savedHash(item))
        viewerMediaSource(
            inVault = item.isLocal || hashes.any { mediaCacheService.isInLocalBlossom(it) },
            cached = mediaCacheService.isCached(item.displayUrl),
        )
    }

    private val _savingSha = MutableStateFlow<String?>(null)
    /** The blob Save to Vault is working on, or null. */
    val savingSha = _savingSha.asStateFlow()

    private val _cachingSha = MutableStateFlow<String?>(null)
    /** The blob Cache Locally is downloading, or null. */
    val cachingSha = _cachingSha.asStateFlow()

    /** Store a file that is not on the phone in the vault, then back it up. iOS `SourceIndicatorView.saveToVault`. */
    fun saveToVault(item: BlossomMediaItem) {
        if (_savingSha.value != null) return
        viewModelScope.launch {
            _savingSha.value = viewerItemKey(item)
            try {
                val result = withContext(Dispatchers.IO) { blossomService.saveUrlToVault(item.displayUrl) }
                if (result.outcome == BlossomService.VaultSave.FAILED) {
                    notificationManager.showError(result.outcome.message)
                } else {
                    result.savedSha?.let { savedShas.record(item, it) }
                    notificationManager.showToast(result.outcome.message)
                    _sourceVersion.value++
                    if (currentSha == item.sha256) checkMirrors(item.sha256)
                }
            } finally {
                _savingSha.value = null
            }
        }
    }

    /** Keep a temporary copy on the phone. iOS `SourceIndicatorView.cacheMedia`. */
    fun cacheLocally(item: BlossomMediaItem) {
        if (_cachingSha.value != null) return
        viewModelScope.launch {
            _cachingSha.value = viewerItemKey(item)
            try {
                val data = withContext(Dispatchers.IO) { mediaCacheService.fetchData(item.displayUrl) }
                if (data == null) notificationManager.showError("Could not cache this file")
                _sourceVersion.value++
            } finally {
                _cachingSha.value = null
            }
        }
    }

    /** How many of your loaded posts link [sha256]; Delete everywhere offers to delete them too. */
    fun postsUsing(sha256: String): Int =
        if (sha256.isEmpty()) 0 else nostrService.ownEvents(referencingBlob = sha256).size

    /**
     * Delete everywhere (local + mirrors) and report each place. [onDone] gets
     * true only when nothing is left anywhere, so the viewer can close; on a
     * partial delete it stays open with the places named. With [deletePosts],
     * first ask relays to delete your posts that link it (iOS "Delete file and post").
     */
    fun deleteEverywhere(
        item: BlossomMediaItem,
        sticky: Boolean = false,
        deletePosts: Boolean = false,
        onDone: (allGone: Boolean) -> Unit,
    ) {
        if (item.sha256.isEmpty()) {
            notificationManager.showError("No hash for this item")
            return
        }
        _deleteLeftover.value = null
        viewModelScope.launch {
            // Posts first: if they can't be deleted (signing failed), keep the
            // file too rather than leave them showing a broken image.
            if (deletePosts && nostrService.deleteOwnEvents(referencingBlob = item.sha256) == 0) {
                notificationManager.showError("Couldn't delete the post, so the file was kept. Try again.")
                onDone(false)
                return@launch
            }
            val (localOk, report) = withContext(Dispatchers.IO) {
                val local = async { blossomService.deleteFromLocal(item.sha256) }
                val mirrors = async { blossomService.deleteFromMirrors(item.sha256) }
                local.await() to mirrors.await()
            }
            val leftover = deleteEverywhereLeftover(localDeleted = localOk, mirrors = report)
            if (leftover == null) {
                notificationManager.showToast("Deleted everywhere")
            } else {
                reportLeftover(leftover, sticky)
                // The cloud badge caches each server's answer for the session;
                // ask again so it stops showing the pre-delete count.
                checkMirrors(item.sha256)
            }
            onDone(leftover == null)
        }
    }

    /** Returns the best public Blossom URL for [item] — external mirror preferred over local. */
    fun blossomLink(item: BlossomMediaItem): String =
        publicBlossomLink(item, configStore.config.value.activeBlossomMirrors)

    fun saveToGallery(item: BlossomMediaItem) {
        viewModelScope.launch {
            val result = withContext(Dispatchers.IO) {
                if (item.localFile != null) {
                    mediaSaveService.saveToGallery(item.localFile, item.mimeType)
                } else {
                    mediaSaveService.saveToGallery(item.displayUrl, item.mimeType)
                }
            }
            if (result.isSuccess) {
                notificationManager.showToast("Saved to gallery")
            } else {
                notificationManager.showError("Save failed: ${result.exceptionOrNull()?.message}")
            }
        }
    }
}
