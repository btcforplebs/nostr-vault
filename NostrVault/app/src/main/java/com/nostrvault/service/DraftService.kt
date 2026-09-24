package com.nostrvault.service

import android.content.Context
import android.util.Log
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.model.Draft
import com.nostrvault.data.model.DraftStore
import com.nostrvault.relay.RelayForegroundService
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.File
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Manages locally saved note drafts with file-based persistence.
 *
 * Drafts are stored as JSON on disk for offline access. When the relay
 * becomes available, queued drafts can be synced as kind 31234
 * parameterized replaceable events to the /private endpoint.
 */
@Singleton
class DraftService @Inject constructor(
    @ApplicationContext private val context: Context,
    private val configStore: ConfigStore,
    private val nostrService: NostrService,
) {
    companion object {
        private const val TAG = "DraftService"
        private const val DRAFTS_FILENAME = "drafts.json"
    }

    private val json = Json { ignoreUnknownKeys = true; prettyPrint = true }
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    private val _drafts = MutableStateFlow<List<Draft>>(emptyList())
    val drafts: StateFlow<List<Draft>> = _drafts.asStateFlow()

    /** IDs of drafts that haven't been synced to the relay yet. */
    private val pendingSyncQueue = mutableSetOf<String>()

    init {
        loadFromDisk()
        observeRelayReady()
    }

    // ── Public API ────────────────────────────────────────────────

    /**
     * Save or update a draft. If a draft with the same ID exists it is replaced.
     * Persists to disk immediately.
     */
    fun saveDraft(draft: Draft) {
        val updated = draft.copy(updatedAt = System.currentTimeMillis())
        val current = _drafts.value.toMutableList()
        val idx = current.indexOfFirst { it.id == updated.id }
        if (idx >= 0) {
            current[idx] = updated
        } else {
            current.add(0, updated)
        }
        _drafts.value = current
        persistToDisk(current)
        pendingSyncQueue.add(updated.id)
        trySyncDraft(updated)
    }

    /**
     * Delete a draft by ID. Removes from disk and attempts relay deletion.
     */
    fun deleteDraft(draftId: String) {
        val current = _drafts.value.toMutableList()
        current.removeAll { it.id == draftId }
        _drafts.value = current
        persistToDisk(current)
        pendingSyncQueue.remove(draftId)
        tryDeleteFromRelay(draftId)
    }

    /**
     * Find a draft by ID.
     */
    fun findDraft(draftId: String): Draft? {
        return _drafts.value.find { it.id == draftId }
    }

    /**
     * Reload drafts from disk (e.g. after account switch).
     */
    fun reload() {
        loadFromDisk()
    }

    // ── Persistence ───────────────────────────────────────────────

    private fun draftsFile(): File = File(context.filesDir, DRAFTS_FILENAME)

    private fun loadFromDisk() {
        try {
            val file = draftsFile()
            if (file.exists()) {
                val store: DraftStore = json.decodeFromString(file.readText())
                _drafts.value = store.drafts.sortedByDescending { it.updatedAt }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to load drafts from disk", e)
        }
    }

    private fun persistToDisk(drafts: List<Draft>) {
        scope.launch {
            try {
                val store = DraftStore(drafts = drafts)
                draftsFile().writeText(json.encodeToString(store))
            } catch (e: Exception) {
                Log.e(TAG, "Failed to persist drafts to disk", e)
            }
        }
    }

    // ── Relay Sync ────────────────────────────────────────────────

    /**
     * Attempt to sync a single draft to the /private relay endpoint
     * as a kind 31234 parameterized replaceable event.
     */
    private fun trySyncDraft(draft: Draft) {
        if (!RelayForegroundService.readyForConnections.value) return
        // Drafts are plaintext. The embedded /private relay is owner-only; an
        // external relay may not be, so drafts stay queued on the device.
        if (configStore.config.value.useExternalRelay) return

        scope.launch {
            try {
                val tags = buildList {
                    add(listOf("d", draft.id))
                    draft.replyToId?.let { add(listOf("reply", it)) }
                    draft.rootId?.let { add(listOf("root", it)) }
                    draft.quoteId?.let { add(listOf("q", it)) }
                    draft.quotePubkey?.let { add(listOf("qp", it)) }
                }

                val event = nostrService.signEvent(
                    kind = 31234,
                    content = draft.content,
                    tags = tags,
                )
                if (event != null) {
                    postToPrivateRelay(serializeEvent(event))
                    pendingSyncQueue.remove(draft.id)
                }
            } catch (e: Exception) {
                Log.e(TAG, "Failed to sync draft ${draft.id} to relay", e)
            }
        }
    }

    /**
     * Delete a draft from the relay by publishing a kind 5 deletion event
     * referencing the draft's d-tag.
     */
    private fun tryDeleteFromRelay(draftId: String) {
        if (!RelayForegroundService.readyForConnections.value) return
        if (configStore.config.value.useExternalRelay) return // see trySyncDraft

        scope.launch {
            try {
                val tags = listOf(
                    listOf("a", "31234:${configStore.activeAccountHexPubkey.value}:$draftId"),
                )
                val event = nostrService.signEvent(kind = 5, content = "", tags = tags)
                if (event != null) {
                    postToPrivateRelay(serializeEvent(event))
                }
            } catch (e: Exception) {
                Log.e(TAG, "Failed to delete draft $draftId from relay", e)
            }
        }
    }

    /**
     * Post raw event JSON to the local /private relay endpoint.
     */
    private suspend fun postToPrivateRelay(eventJson: String) {
        val config = configStore.config.value
        if (config.useExternalRelay) return // see trySyncDraft
        val privateUrl = config.localRelayURL("private") ?: return
        try {
            val client = nostrService.connectToRelay(privateUrl, onMessage = {})
            client?.send("[\"EVENT\",$eventJson]")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to post to /private relay", e)
        }
    }

    /**
     * When the relay becomes ready, flush any pending drafts that haven't
     * been synced yet.
     */
    private fun observeRelayReady() {
        scope.launch {
            RelayForegroundService.readyForConnections
                .filter { it }
                .collect {
                    flushPendingQueue()
                }
        }
    }

    private fun flushPendingQueue() {
        val ids = pendingSyncQueue.toList()
        for (id in ids) {
            val draft = _drafts.value.find { it.id == id }
            if (draft != null) {
                trySyncDraft(draft)
            } else {
                pendingSyncQueue.remove(id)
            }
        }
    }

    /**
     * Serialize a NostrEvent to JSON string for WebSocket transmission.
     */
    private fun serializeEvent(event: NostrEvent): String {
        val tagsJson = event.tags.joinToString(",") { tag ->
            "[${tag.joinToString(",") { "\"$it\"" }}]"
        }
        return buildString {
            append("{")
            append("\"id\":\"${event.id}\",")
            append("\"pubkey\":\"${event.pubkey}\",")
            append("\"created_at\":${event.createdAt},")
            append("\"kind\":${event.kind},")
            append("\"tags\":[$tagsJson],")
            append("\"content\":\"${event.content.replace("\"", "\\\"").replace("\n", "\\n")}\",")
            append("\"sig\":\"${event.sig}\"")
            append("}")
        }
    }
}
