package com.nostrvault.service

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.util.Log
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.model.FeedNote
import com.nostrvault.data.model.MediaUploadOutcomeMessage
import com.nostrvault.data.model.QueuedMediaPost
import com.nostrvault.ui.notification.NotificationManager
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Posts whose media is saved on this device but not yet on any outside
 * Blossom server. See [QueuedMediaPost] for why they wait instead of failing.
 *
 * Retries whenever there is a reason to think a server might now answer: the
 * app comes to the foreground ([MainActivity.onStart]), a network becomes
 * available, and every minute while anything is waiting. The queue is on disk,
 * so a relaunch keeps it. Port of `MediaPostQueue.swift`.
 */
@Singleton
class MediaPostQueue @Inject constructor(
    @ApplicationContext private val context: Context,
    private val configStore: ConfigStore,
    private val blossomService: BlossomService,
    private val nostrService: NostrService,
    private val feedService: FeedService,
    private val notificationManager: NotificationManager,
) {
    companion object {
        private const val TAG = "MediaPostQueue"
        private const val FILE_NAME = "queued_media_posts.json"
        private const val RETRY_INTERVAL_MS = 60_000L
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val serializer = ListSerializer(QueuedMediaPost.serializer())
    private val file get() = File(context.filesDir, FILE_NAME)

    private val _posts = MutableStateFlow<List<QueuedMediaPost>>(emptyList())
    val posts: StateFlow<List<QueuedMediaPost>> = _posts.asStateFlow()

    private val started = AtomicBoolean(false)
    private val retrying = AtomicBoolean(false)
    private var timerJob: Job? = null
    private val diskLock = Any()

    init {
        loadFromDisk()
    }

    // region Lifecycle

    /** Idempotent. Called at launch and on enqueue. */
    fun start() {
        if (!started.compareAndSet(false, true)) {
            retryAll("start")
            return
        }
        try {
            val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            cm.registerDefaultNetworkCallback(object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) {
                    retryAll("network")
                }
            })
        } catch (e: Exception) {
            log("could not watch the network (${e.message}); relying on foreground and timer retries", Log.WARN)
        }
        updateTimer()
        retryAll("launch")
    }

    @Synchronized
    private fun updateTimer() {
        if (_posts.value.isEmpty()) {
            timerJob?.cancel()
            timerJob = null
        } else if (timerJob?.isActive != true) {
            timerJob = scope.launch {
                while (isActive) {
                    delay(RETRY_INTERVAL_MS)
                    if (_posts.value.isEmpty()) break
                    retryAll("timer")
                }
            }
        }
    }

    // endregion

    // region Queue

    fun enqueue(post: QueuedMediaPost) {
        _posts.update { it + post }
        saveToDisk()
        log("queued post ${post.id.take(8)} with ${post.pendingMedia.size} attachment(s) waiting for an outside server")
        updateTimer()
        start()
    }

    fun discard(id: String) {
        _posts.update { list -> list.filterNot { it.id == id } }
        saveToDisk()
        updateTimer()
        log("discarded waiting post ${id.take(8)}")
    }

    /**
     * Try every waiting post once. Posts are sent one at a time, oldest first,
     * so they reach relays in the order they were written.
     */
    fun retryAll(reason: String) {
        if (_posts.value.isEmpty()) return
        if (!retrying.compareAndSet(false, true)) return
        scope.launch {
            try {
                log("retrying ${_posts.value.size} waiting post(s) — $reason")
                for (id in _posts.value.sortedBy { it.createdAt }.map { it.id }) {
                    // The servers are the same for every post; if one could not
                    // be sent, the rest won't be either this round.
                    if (!attempt(id)) break
                }
            } catch (e: Exception) {
                log("retry round failed: ${e.message}", Log.ERROR)
            } finally {
                retrying.set(false)
                updateTimer()
            }
        }
    }

    /** One attempt at one post. Returns true if it was sent (or is gone). */
    private suspend fun attempt(id: String): Boolean {
        var post = _posts.value.firstOrNull { it.id == id } ?: return true

        val activeNpub = configStore.config.value.activeOrOwnerNpub()
        if (activeNpub != post.accountNpub) {
            log("waiting post ${id.take(8)} belongs to another account — holding it until that account is active")
            return false
        }

        post = post.copy(attempts = post.attempts + 1, lastAttempt = System.currentTimeMillis())
        update(post)

        for ((index, item) in post.media.withIndex()) {
            if (item.url != null) continue
            val sha256 = item.sha256 ?: continue
            val url = blossomService.hostLocalBlob(sha256, item.mimeType ?: "application/octet-stream")
                ?: return false
            post = post.copy(media = post.media.toMutableList().also { it[index] = item.copy(url = url) })
            // Persist each hosted URL at once, so a crash between two
            // attachments doesn't upload the first one again.
            update(post)
        }

        val assembled = post.assembled() ?: return false

        // The account may have been switched while the media uploaded.
        if (configStore.config.value.activeOrOwnerNpub() != post.accountNpub) {
            log("waiting post ${id.take(8)}: account changed during upload — holding it")
            return false
        }
        val event = nostrService.signEventAsync(kind = 1, content = assembled.content, tags = assembled.tags)
        if (event == null) {
            log("waiting post ${id.take(8)}: media is hosted but signing failed — will retry", Log.ERROR)
            return false
        }

        // Same publish as the composer (minus its 5 s undo countdown: the user
        // already pressed Post, possibly long ago).
        feedService.emitOptimisticNote(
            FeedNote.fromEvent(
                id = event.id,
                pubkey = event.pubkey,
                content = assembled.content,
                tags = assembled.tags,
                createdAt = event.createdAt,
                kind = 1,
            )
        )
        nostrService.postEvent(event)
        _posts.update { list -> list.filterNot { it.id == id } }
        saveToDisk()
        log("sent waiting post ${id.take(8)} as ${event.id.take(8)} after ${post.attempts} attempt(s)")
        withContext(Dispatchers.Main) {
            notificationManager.showToast(MediaUploadOutcomeMessage.SENT)
        }
        return true
    }

    private fun update(post: QueuedMediaPost) {
        var found = false
        _posts.update { list ->
            list.map { if (it.id == post.id) { found = true; post } else it }
        }
        if (found) saveToDisk()
    }

    // endregion

    // region Disk

    private fun loadFromDisk() {
        synchronized(diskLock) {
            val f = file
            if (!f.exists()) return
            try {
                _posts.value = json.decodeFromString(serializer, f.readText())
            } catch (e: Exception) {
                // Never drop a user's post silently: keep the unreadable file aside.
                val aside = File(f.parentFile, "$FILE_NAME.unreadable-${System.currentTimeMillis()}")
                val moved = f.renameTo(aside) ||
                    runCatching { f.copyTo(aside, overwrite = false); true }.getOrDefault(false)
                log(
                    "could not read the waiting-post queue (${e.message}); " +
                        if (moved) "kept it at ${aside.name}" else "could NOT copy it aside (${f.name} will be overwritten on next save)",
                    Log.ERROR,
                )
            }
        }
    }

    private fun saveToDisk() {
        synchronized(diskLock) {
            try {
                val f = file
                val tmp = File(f.parentFile, "$FILE_NAME.tmp")
                tmp.writeText(json.encodeToString(serializer, _posts.value))
                if (!tmp.renameTo(f)) {
                    f.delete()
                    tmp.renameTo(f)
                }
            } catch (e: Exception) {
                log("could not save the waiting-post queue: ${e.message}", Log.ERROR)
            }
        }
    }

    // endregion

    private fun log(message: String, priority: Int = Log.INFO) {
        Log.println(priority, TAG, message)
    }
}
