package com.nostrvault.service

import android.content.Context
import android.util.Log
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.model.Draft
import com.nostrvault.data.model.DraftEvents
import com.nostrvault.data.model.DraftStore
import com.nostrvault.data.remote.WebSocketClient
import com.nostrvault.relay.HavenBridge
import com.nostrvault.relay.RelayForegroundService
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import java.io.File
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Manages locally saved note drafts with file-based persistence.
 *
 * Drafts are stored as JSON on disk for offline access. When the relay
 * becomes available, queued drafts are synced as kind 31234 parameterized
 * replaceable events to the /private endpoint, and the relay's drafts are
 * pulled back and merged in, so a draft saved on iOS or the Mac shows here.
 * iOS: DraftService.swift.
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
    /** Every saved draft on the device, for every account. */
    val allDrafts: StateFlow<List<Draft>> = _drafts.asStateFlow()

    /** The active account's drafts (iOS `draftsForActiveAccount`). */
    val drafts: StateFlow<List<Draft>> = combine(_drafts, configStore.activeAccountHexPubkey) { all, account ->
        DraftEvents.forAccount(all, account)
    }.stateIn(scope, SharingStarted.Eagerly, emptyList())

    private val fetchMutex = kotlinx.coroutines.sync.Mutex()

    /** IDs of drafts that haven't been synced to the relay yet. */
    private val pendingSyncQueue = java.util.Collections.synchronizedSet(mutableSetOf<String>())

    /**
     * Coordinates of drafts deleted here whose kind 5 the relay hasn't
     * confirmed. Kept on disk and sent when the relay is next ready (iOS
     * pendingDeletes); until then a fetch must not bring the draft back.
     */
    private val pendingDeletes = java.util.Collections.synchronizedSet(mutableSetOf<String>())

    /** Ids deleted this run. A fetch already in flight may still return them. */
    private val deletedThisRun = java.util.Collections.synchronizedSet(mutableSetOf<String>())

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
        val owner = draft.pubkey.ifEmpty { configStore.activeAccountHexPubkey.value }
        val updated = draft.copy(pubkey = owner, updatedAt = System.currentTimeMillis())
        val current = _drafts.value.toMutableList()
        val idx = current.indexOfFirst { it.id == updated.id }
        if (idx >= 0) {
            current[idx] = updated
        } else {
            current.add(0, updated)
        }
        _drafts.value = current
        deletedThisRun.remove(updated.id)
        persistToDisk(current)
        pendingSyncQueue.add(updated.id)
        trySyncDraft(updated)
    }

    /**
     * Delete a draft by ID. Removes from disk and attempts relay deletion.
     */
    fun deleteDraft(draftId: String) {
        val current = _drafts.value.toMutableList()
        val owner = current.firstOrNull { it.id == draftId }?.pubkey?.ifEmpty { null }
            ?: configStore.activeAccountHexPubkey.value
        current.removeAll { it.id == draftId }
        _drafts.value = current
        deletedThisRun.add(draftId)
        pendingSyncQueue.remove(draftId)
        val coordinate = DraftEvents.coordinate(owner, draftId)
        if (owner.isNotEmpty()) pendingDeletes.add(coordinate)
        persistToDisk(current)
        if (owner.isNotEmpty()) tryDeleteFromRelay(coordinate)
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
                pendingDeletes.clear()
                pendingDeletes.addAll(store.pendingDeletes)
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to load drafts from disk", e)
        }
    }

    private fun persistToDisk(drafts: List<Draft>) {
        scope.launch {
            try {
                val store = DraftStore(drafts = drafts, pendingDeletes = synchronized(pendingDeletes) { pendingDeletes.toList() })
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
        // Signing uses the active account: another account's draft waits
        // until that account is active again.
        if (draft.pubkey.isNotEmpty() && draft.pubkey != configStore.activeAccountHexPubkey.value) return

        scope.launch {
            try {
                // iOS's tag shape, so iOS and the Mac read reply and quote back.
                val event = nostrService.signEventAsync(
                    kind = DraftEvents.KIND,
                    content = draft.content,
                    tags = DraftEvents.tags(draft),
                )
                if (event != null && postToPrivateRelay(event)) {
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
    private fun tryDeleteFromRelay(coordinate: String) {
        if (!RelayForegroundService.readyForConnections.value) return
        if (configStore.config.value.useExternalRelay) return // see trySyncDraft
        scope.launch { sendDelete(coordinate) }
    }

    /** Sends one queued delete; it leaves the queue only once the relay says OK. */
    private suspend fun sendDelete(coordinate: String) {
        // Signed by the active account, so another account's delete waits for it.
        if (!coordinate.startsWith("${DraftEvents.KIND}:${configStore.activeAccountHexPubkey.value}:")) return
        try {
            val event = nostrService.signEventAsync(kind = 5, content = "", tags = listOf(listOf("a", coordinate)))
            if (event != null && postToPrivateRelay(event)) {
                pendingDeletes.remove(coordinate)
                persistToDisk(_drafts.value)
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to delete draft $coordinate from relay", e)
        }
    }

    /**
     * Posts [event] to the local /private relay and waits for its OK (iOS
     * postEventToPrivateRelayConfirmed). False when it was refused or the
     * relay didn't answer in 5s.
     */
    private suspend fun postToPrivateRelay(event: NostrEvent): Boolean {
        val config = configStore.config.value
        if (config.useExternalRelay) return false // see trySyncDraft
        val privateUrl = config.localRelayURL("private") ?: return false
        return try {
            coroutineScope {
                val client = WebSocketClient(url = privateUrl, scope = this, autoReconnect = false)
                try {
                    withTimeoutOrNull(5_000) {
                        // Listen before connecting; the flow does not replay.
                        val answer = async(start = CoroutineStart.UNDISPATCHED) {
                            client.messages.mapNotNull { okFor(it, event.id) }.first()
                        }
                        client.connect()
                        client.connectionState.first { it == WebSocketClient.ConnectionState.CONNECTED }
                        client.send("[\"EVENT\",${serializeEvent(event)}]")
                        answer.await()
                    } ?: false
                } finally {
                    client.disconnect()
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to post to /private relay", e)
            false
        }
    }

    /** `["OK", id, accepted, …]` for [eventId]: whether it was accepted; null for any other message. */
    private fun okFor(message: String, eventId: String): Boolean? = runCatching {
        val arr = json.parseToJsonElement(message).jsonArray
        if (arr.getOrNull(0)?.jsonPrimitive?.contentOrNull != "OK") return@runCatching null
        if (arr.getOrNull(1)?.jsonPrimitive?.contentOrNull != eventId) return@runCatching null
        arr.getOrNull(2)?.jsonPrimitive?.contentOrNull == "true"
    }.getOrNull()

    /**
     * When the relay becomes ready, flush any pending drafts that haven't
     * been synced yet.
     */
    private fun observeRelayReady() {
        scope.launch {
            RelayForegroundService.readyForConnections
                .filter { it }
                .collect {
                    // Deletes first, so the fetch can't bring a deleted draft back (iOS order).
                    synchronized(pendingDeletes) { pendingDeletes.toList() }.forEach { sendDelete(it) }
                    flushPendingQueue()
                    fetchFromRelay()
                }
        }
    }

    /**
     * Pull the active account's drafts from /private and merge them in:
     * the newer copy of each wins, local-only drafts stay. The relay asks
     * for NIP-42 AUTH before it answers a query, as on iOS. Also called when
     * the composer or the Drafts screen opens.
     */
    fun refreshFromRelay() {
        scope.launch { fetchFromRelay() }
    }

    private suspend fun fetchFromRelay() {
        if (!RelayForegroundService.readyForConnections.value) return
        val config = configStore.config.value
        if (config.useExternalRelay) return // see trySyncDraft
        val url = config.localRelayURL("private") ?: return
        val account = configStore.activeAccountHexPubkey.value
        if (account.isEmpty()) return
        if (!fetchMutex.tryLock()) return
        try {
            val fetched = queryDrafts(url, account) ?: return
            if (configStore.activeAccountHexPubkey.value != account) return
            val deleted = synchronized(pendingDeletes) { pendingDeletes.map(DraftEvents::idOf) }.toSet() +
                synchronized(deletedThisRun) { deletedThisRun.toSet() }
            val before = _drafts.value
            // update, not read-then-write: an autosave landing meanwhile is kept.
            val merged = _drafts.updateAndGet { DraftEvents.merge(it, fetched, deleted) }
            if (merged != before) persistToDisk(merged)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to fetch drafts from relay", e)
        } finally {
            fetchMutex.unlock()
        }
    }

    /** The account's kind 31234 events on [url], or null if the relay didn't answer in time. */
    private suspend fun queryDrafts(url: String, account: String): List<Draft>? = coroutineScope {
        val client = WebSocketClient(url = url, scope = this, autoReconnect = false)
        val found = java.util.Collections.synchronizedList(mutableListOf<Draft>())
        val subId = "drafts-${java.util.UUID.randomUUID().toString().take(8)}"
        val req = "[\"REQ\",\"$subId\",{\"kinds\":[${DraftEvents.KIND}],\"authors\":[\"$account\"]}]"
        try {
            withTimeoutOrNull(10_000) {
                val done = CompletableDeferred<Unit>()
                val authId = java.util.concurrent.atomic.AtomicReference<String?>(null)
                // Undispatched: the relay's AUTH challenge can arrive as soon as it connects.
                val collector = launch(start = CoroutineStart.UNDISPATCHED) {
                    client.messages.collect { msg ->
                        val arr = runCatching { json.parseToJsonElement(msg).jsonArray }.getOrNull() ?: return@collect
                        when (arr.getOrNull(0)?.jsonPrimitive?.contentOrNull) {
                            "AUTH" -> {
                                val challenge = arr.getOrNull(1)?.jsonPrimitive?.contentOrNull ?: return@collect
                                launch { authenticate(client, url, challenge, authId) }
                            }
                            // Ask again once the relay has taken the AUTH: sent
                            // together, the REQ can be checked before it lands.
                            "OK" -> if (authId.get() != null && arr.getOrNull(1)?.jsonPrimitive?.contentOrNull == authId.get()) {
                                client.send(req)
                            }
                            "EVENT" -> {
                                if (arr.getOrNull(1)?.jsonPrimitive?.contentOrNull != subId) return@collect
                                val obj = arr.getOrNull(2)?.jsonObject ?: return@collect
                                if (!HavenBridge.verifyEvent(obj.toString())) return@collect
                                val pubkey = obj["pubkey"]?.jsonPrimitive?.contentOrNull ?: return@collect
                                if (pubkey != account || obj["kind"]?.jsonPrimitive?.contentOrNull != "${DraftEvents.KIND}") return@collect
                                val tags = obj["tags"]?.jsonArray?.map { t -> t.jsonArray.map { it.jsonPrimitive.contentOrNull ?: "" } }
                                    ?: emptyList()
                                DraftEvents.fromEvent(
                                    content = obj["content"]?.jsonPrimitive?.contentOrNull ?: "",
                                    pubkey = pubkey,
                                    tags = tags,
                                    createdAt = obj["created_at"]?.jsonPrimitive?.longOrNull ?: return@collect,
                                )?.let { found.add(it) }
                            }
                            "EOSE" -> if (arr.getOrNull(1)?.jsonPrimitive?.contentOrNull == subId) done.complete(Unit)
                            // "auth-required:" before AUTH lands; the REQ is sent again after it.
                            "CLOSED" -> {
                                val reason = arr.getOrNull(2)?.jsonPrimitive?.contentOrNull.orEmpty()
                                if (!reason.startsWith("auth-required")) done.complete(Unit)
                            }
                        }
                    }
                }
                launch {
                    client.connectionState.first { it == WebSocketClient.ConnectionState.CONNECTED }
                    client.send(req)
                }
                client.connect()
                done.await()
                collector.cancel()
                synchronized(found) { found.toList() }
            }
        } finally {
            client.disconnect()
        }
    }

    /** NIP-42: sign the challenge as the owner and send it, noting its id in [authId] first so its OK is recognised. */
    private suspend fun authenticate(
        client: WebSocketClient,
        url: String,
        challenge: String,
        authId: java.util.concurrent.atomic.AtomicReference<String?>,
    ) {
        val auth = nostrService.signEventAsync(
            kind = 22242,
            content = "",
            tags = listOf(listOf("relay", url), listOf("challenge", challenge)),
            forceOwner = true,
        ) ?: return
        authId.set(auth.id)
        client.send("[\"AUTH\",${serializeEvent(auth)}]")
    }

    private fun flushPendingQueue() {
        val ids = synchronized(pendingSyncQueue) { pendingSyncQueue.toList() }
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
    private fun serializeEvent(event: NostrEvent): String = EventPublisher.serializeSignedEvent(event)
}
