package com.nostrvault.fips

import android.content.Context
import android.util.Base64
import android.util.Log
import com.nostrvault.data.local.ConfigStore
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineExceptionHandler
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.MediaType.Companion.toMediaTypeOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.asRequestBody
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import java.io.File
import java.io.IOException
import java.util.concurrent.TimeUnit
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Sends the owner's posts and media to their home vault over the FIPS mesh.
 *
 * The home vault is another device of the owner's (a kiosk phone) that lists
 * `fipsmesh://<npub>/` in the owner's 10063. While one is chosen, every event
 * the owner publishes and every blob they upload is also sent there: blobs
 * as a Blossom `PUT /upload`, events as `EVENT` on its relay websocket, both
 * through the same loopback ingress the mesh reader uses. The vault accepts
 * only what the owner's key signed, and passes notes on to the regular relays.
 *
 * This phone keeps its own copy and its normal publishing; the home vault is
 * an extra destination. What can't be sent waits in [HomeVaultQueue] and goes
 * when the vault is reachable again.
 */
@Singleton
class HomeVaultSender @Inject constructor(
    @ApplicationContext context: Context,
    private val configStore: ConfigStore,
) {
    private val filesDir: File = context.filesDir
    /** Signs a Nostr event as the owner, or returns null. Wired by NostrService. */
    @Volatile
    var signer: suspend (kind: Int, content: String, tags: List<List<String>>) -> String? = { _, _, _ -> null }

    /** This phone's mesh-key Blossom token for one blob on one vault ([MeshKeySigner.blossom]); swapped in tests. */
    internal var meshToken: (verb: MeshKeyAuth.Verb, sha256: String, receiver: String, content: String, lifetimeS: Long, size: Long?) -> String? =
        { verb, sha, receiver, content, lifetime, size -> MeshKeySigner.blossom(verb, listOf(sha), listOf(receiver), content, lifetime, size) }

    /** Signs a `/files` event (1063, its kind 5, the AUTH) with this device's mesh key, never the owner's; swapped in tests. */
    internal var fileNoteSign: (kind: Int, tags: List<List<String>>) -> String? = { kind, tags -> MeshKeySigner.fileNotes(kind, tags) }

    /** The owner's hex pubkey. Wired by NostrService. */
    @Volatile
    var ownerHex: () -> String = { "" }

    /**
     * Whether the owner is the active account. The home vault is the owner's
     * (picked from their 10063, signed for with their key), so nothing is
     * offered or sent while another account is active. Wired by NostrService.
     */
    @Volatile
    var ownerIsActive: () -> Boolean = { false }

    /**
     * Whether signing as the owner needs no human (a local key, not Amber or
     * a bunker). A background retry must not prompt for every queued blob.
     * Wired by NostrService.
     */
    @Volatile
    var signerIsLocal: () -> Boolean = { false }

    private val queue = HomeVaultQueue(File(context.filesDir, "home_vault_queue"))

    /** One queue for the mobile vault and per Mac in My Devices ([MeshSendTargets]), each sent on its own. */
    private val macQueues = java.util.concurrent.ConcurrentHashMap<String, HomeVaultQueue>()
    private val macQueueRoot get() = File(filesDir, "mesh_send_queue")
    private fun macQueue(npub: String) = macQueues.getOrPut(npub) { HomeVaultQueue(File(macQueueRoot, npub)) }

    /**
     * Where the owner's new notes and media go right now, each with its queue: the home vault,
     * then each Mac. None while another account is active.
     */
    internal fun lanes(): List<Pair<MeshSendTarget, HomeVaultQueue>> {
        if (!ownerIsActive()) return emptyList()
        return MeshSendTargets.of(configStore.config.value).map { t ->
            t to (if (t.role == DeviceRole.HOME_VAULT) queue else macQueue(t.npub))
        }
    }

    /**
     * What waits, across the home vault and every Mac queue on disk. From disk, not the config: at
     * launch the config may not be loaded yet, and a queue left by a removed Mac goes on its next pass.
     */
    private fun waitingCount(): Int =
        queue.size + (macQueueRoot.listFiles()?.filter { it.isDirectory }?.sumOf { macQueue(it.name).size } ?: 0)

    /**
     * Blobs a note was published for while only the home vault had them.
     * Each is pushed to the public servers until one takes it.
     */
    private val publicCopies = HomeVaultQueue(File(context.filesDir, "home_vault_public_copies"))
    private var publicJob: Job? = null
    private val publicLock = Mutex()

    /**
     * Upload a blob from this phone's relay to [server] only, with the given
     * owner-signed auth; true once that server has it. Wired by BlossomService.
     */
    @Volatile
    var hostPublicly: suspend (sha256: String, contentType: String, server: String, auth: String) -> Boolean =
        { _, _, _, _ -> false }

    /** One user pass (Send now) at a time, so the prompt cap is per tap. */
    private val userPassRunning = java.util.concurrent.atomic.AtomicBoolean(false)
    // A failure that escapes a pass (a full disk while saving the queue) is
    // logged, never allowed to kill the app: a queue on disk would re-run
    // the same pass after every launch.
    private val scope = CoroutineScope(
        SupervisorJob() + Dispatchers.IO + CoroutineExceptionHandler { _, e -> Log.e(TAG, "home vault", e) },
    )
    internal val drainLock = Mutex()
    private var retryJob: Job? = null

    private val client = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .writeTimeout(120, TimeUnit.SECONDS)
        .readTimeout(60, TimeUnit.SECONDS)
        .build()

    /**
     * For [ensureOnVault], with the composer waiting: a whole-call limit,
     * since a coroutine timeout cannot interrupt a blocking `execute()`.
     */
    internal val ensureClient = client.newBuilder().callTimeout(ENSURE_CALL_TIMEOUT_S, TimeUnit.SECONDS).build()

    data class State(
        val waiting: Int = 0,
        /** Notes already out whose media no public server has yet. */
        val publicPending: Int = 0,
        val lastSentAt: Long? = null,
        val lastProblem: String? = null,
    )

    private val _state = MutableStateFlow(State(publicPending = publicCopies.size))
    val state: StateFlow<State> = _state.asStateFlow()

    /** The chosen home vault's mesh npub, or null when there is none. */
    val homeVaultNpub: String? get() = configStore.config.value.homeVaultNpub

    /** The home vault to send to right now: none while another account is active. */
    private val activeVault: String? get() = homeVaultNpub?.takeIf { ownerIsActive() }

    init {
        publish()
        if (_state.value.waiting > 0) scheduleRetry()
        if (publicCopies.size > 0) schedulePublicCopies()
    }

    /**
     * Make sure the home vault has [sha256] now: send that one blob, or ask
     * the vault for it. Called while the owner is posting, so it may prompt
     * the signer. Each call is bounded by [ensureClient]'s whole-call limit.
     */
    suspend fun ensureOnVault(sha256: String): Boolean {
        val npub = activeVault ?: return false
        // The composer is waiting: a background pass already holding the
        // lock (minutes, with a long queue) means "not now", and the post
        // waits as it would have without a home vault.
        if (withTimeoutOrNull(ENSURE_LOCK_WAIT_MS) { drainLock.lock() } == null) {
            Log.w(TAG, "home vault busy; not confirming ${sha256.take(8)} for this post")
            return false
        }
        return try {
            // One signed "get" for this blob on this vault, before the retries: it covers every check below.
            val check = checkAuth(sha256, npub)
            // Right after launch or a network change the mesh link to the
            // vault is still coming up and the first tries are reset: keep
            // trying for a while rather than fall back on the first one.
            val deadline = System.currentTimeMillis() + ENSURE_LINK_WAIT_MS
            var confirmed: Boolean? = null
            while (confirmed == null) {
                confirmed = try {
                    confirmOnce(npub, sha256, check)
                } catch (e: IOException) {
                    FipsMediaRouter.forget(npub)
                    if (System.currentTimeMillis() + ENSURE_RETRY_MS > deadline) throw e
                    Log.i(TAG, "home vault: ${sha256.take(8)} not confirmed yet (${e.message}); retrying")
                    delay(ENSURE_RETRY_MS)
                    null
                }
            }
            confirmed
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Throwable) {
            Log.w(TAG, "home vault: could not confirm ${sha256.take(8)}: ${e.message}")
            false
        } finally {
            drainLock.unlock()
            publish()
        }
    }

    private suspend fun confirmOnce(npub: String, sha256: String, check: String?): Boolean {
        val base = FipsMediaRouter.ingressBase(npub) ?: return false
        val item = queue.items().firstOrNull { it.key == sha256 && it.type == HomeVaultQueue.TYPE_BLOB }
        if (item != null) {
            val outcome = sendBlob(base, item, queue, npub, ensureClient, check)
            record(item, outcome, npub, System.currentTimeMillis(), queue, DeviceRole.HOME_VAULT)
            return outcome == HomeVaultSend.SENT
        }
        return ensureClient.newCall(VaultCheck.request(base, sha256, check)).execute().use { it.isSuccessful }
    }

    /**
     * Keep pushing [sha256] to [server], the one the published note names,
     * until it has it. False when the queue is full: then the note must not
     * be published under that URL.
     */
    fun needsPublicCopy(sha256: String, contentType: String, server: String): Boolean {
        val queued = try {
            publicCopies.addPublicCopy(sha256, safeType(contentType), server)
        } catch (e: Exception) {
            Log.w(TAG, "public copy of ${sha256.take(8)} not queued: ${e.message}")
            false
        }
        if (queued) schedulePublicCopies()
        publish()
        return queued
    }

    /**
     * Push the public copies every minute while any wait and a pass can do
     * something. With an external signer or another account active it stops;
     * Send now, a new copy and the next launch start it again.
     */
    private fun schedulePublicCopies() {
        if (publicJob?.isActive == true) return
        publicJob = scope.launch {
            while (isActive && publicCopies.size > 0 && ownerIsActive() && signerIsLocal()) {
                publicPass(userInitiated = false)
                delay(RETRY_MS)
            }
        }
    }

    /**
     * One try at each due public copy, with the vault queue's backoff,
     * give-up and signer rules. The auth is the owner's (the blob and the
     * note are theirs), so nothing runs while another account is active.
     */
    private suspend fun publicPass(userInitiated: Boolean) {
        try {
            publicPassLocked(userInitiated)
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Throwable) {
            Log.e(TAG, "public copy pass failed", e)
        }
    }

    private suspend fun publicPassLocked(userInitiated: Boolean) = publicLock.withLock {
        if (!ownerIsActive()) return@withLock
        val now = System.currentTimeMillis()
        val gaveUp = publicCopies.items().filter { HomeVaultRules.expired(it, now) }
        gaveUp.forEach {
            Log.w(TAG, "public copy of ${it.key.take(8)} on ${it.server}: gave up after ${it.attempts} tries")
            publicCopies.remove(it.key)
        }
        if (gaveUp.isNotEmpty()) {
            problem("Gave up copying ${gaveUp.size} published ${if (gaveUp.size == 1) "file" else "files"} to your media servers; other apps can't show ${if (gaveUp.size == 1) "it" else "them"}")
        }
        val selection = HomeVaultRules.select(
            publicCopies.items(), now, userInitiated, signerIsLocal(), needsSignature = { true },
        )
        if (selection.heldForSigner) problem("Your signer needs you: tap Send now")
        for (item in selection.toTry) {
            val server = item.server
            val sha = HomeVaultQueue.shaOf(item.key)
            val hosted = if (server == null) {
                false
            } else {
                val auth = uploadAuth(sha, "Upload Blob")
                if (auth == null) {
                    false
                } else {
                    try {
                        hostPublicly(sha, item.contentType ?: "application/octet-stream", server, auth)
                    } catch (e: kotlinx.coroutines.CancellationException) {
                        throw e
                    } catch (e: Throwable) {
                        Log.w(TAG, "public copy of ${item.key.take(8)}: ${e.message}")
                        false
                    }
                }
            }
            if (hosted) {
                publicCopies.remove(item.key)
                Log.i(TAG, "public copy of ${item.key.take(8)} is up on $server")
            } else {
                val attempts = item.attempts + 1
                publicCopies.update(item.copy(attempts = attempts, nextAt = now + HomeVaultRules.backoffMs(attempts)))
            }
        }
        publish()
    }

    suspend fun setHomeVault(npub: String?) {
        configStore.updateAsync { it.copy(homeVaultNpub = npub) }
        if (npub == null) {
            // Nowhere to send it: what waited was for that vault.
            queue.clear()
            publish()
        } else {
            drainSoon()
        }
    }

    /** A deleted blob is not sent anywhere it still waits to go: home vault, Macs, public copies (§4.3). */
    fun forgetBlob(sha256: String) {
        val queues = lanes().map { it.second }
        scope.launch { queues.forEach { it.dropDeleted(sha256 = sha256.lowercase()) } }
    }

    /**
     * Tell the home vault's `/files` that this device has [sha256] on [servers] (none: the vault holds it), so every
     * open Media tab of the owner's shows it (RESEARCH/NV_MEDIA_LIVE_FILE_NOTES_PLAN.md gap 1). The home vault's lane
     * only, and only while the owner is active: the note's `p` is the owner. Signed when sent, with the mesh key.
     */
    fun offerFileNote(sha256: String, contentType: String, size: Long, servers: List<String>) =
        queueFileNote(HomeVaultQueue.FileNoteDraft(HomeVaultQueue.FileNoteDraft.ADD, sha256.lowercase(), safeType(contentType), size, servers))

    /** Tell `/files` the owner deleted [sha256] everywhere: a kind 5 for every note naming it, sent when the vault is reachable. */
    fun offerFileNoteDelete(sha256: String) =
        queueFileNote(HomeVaultQueue.FileNoteDraft(HomeVaultQueue.FileNoteDraft.DELETE, sha256.lowercase(), "application/octet-stream", 0))

    private fun queueFileNote(draft: HomeVaultQueue.FileNoteDraft) {
        if (activeVault == null || !FileNote.isHex64(draft.sha256)) return
        scope.launch {
            val queued = try {
                queue.addFileNote(draft)
            } catch (e: Exception) {
                Log.w(TAG, "home vault: could not queue file note ${draft.sha256.take(8)}: ${e.message}")
                false
            }
            if (queued) drain() else full()
        }
    }

    /** Also send this signed event to the home vault and each Mac taking notes, if it is the owner's. */
    fun offerEvent(eventId: String, pubkey: String, eventJson: String) {
        if (pubkey.isEmpty() || pubkey != ownerHex()) return
        val queues = lanes().map { it.second }
        if (queues.isEmpty()) return
        // Off the caller's thread: postEvent runs on the main thread.
        // A signed delete takes back the notes it names that still wait: they are never sent
        // (device sync map §4.3). The delete itself is queued like any note.
        val deleted = HomeVaultQueue.deletedEventIds(eventJson)
        scope.launch {
            if (deleted.isNotEmpty()) queues.forEach { it.dropDeleted(eventIds = deleted) }
            val queued = queues.map { q ->
                try {
                    q.addEvent(eventId, eventJson)
                } catch (e: Exception) {
                    Log.w(TAG, "home vault: could not queue event ${eventId.take(8)}: ${e.message}")
                    false
                }
            }
            val (drainNow, someFull) = MeshSendTargets.afterQueueing(queued)
            if (drainNow) drain()
            if (someFull) full()
        }
    }

    /** Also send this blob to the home vault, copied from [source]. */
    /**
     * Also send this blob to the home vault, copied from [source]. Queued
     * only: the upload calls [drainSoon] once it is done, so a background
     * pass is not holding the lock while the post asks [ensureOnVault].
     */
    fun offerBlob(sha256: String, contentType: String, source: File) =
        offer(sha256, contentType, source.length()) { source.copyTo(it, overwrite = true) }

    fun offerBlob(sha256: String, contentType: String, data: ByteArray) =
        offer(sha256, contentType, data.size.toLong()) { it.writeBytes(data) }

    /** Synchronous (the caller's source may be deleted next), and never throws into an upload. */
    private fun offer(sha256: String, contentType: String, byteCount: Long, writeTo: (File) -> Unit) {
        val queues = lanes().map { it.second }
        if (queues.isEmpty()) return
        val queued = queues.map { q ->
            try {
                q.addBlob(sha256, safeType(contentType), byteCount, writeTo = writeTo)
            } catch (e: Exception) {
                Log.w(TAG, "home vault: could not queue ${sha256.take(8)}: ${e.message}")
                false
            }
        }
        // The timer, not a drain: the caller drains once its upload is done,
        // and this covers an upload that throws before it gets there.
        val (retry, someFull) = MeshSendTargets.afterQueueing(queued)
        if (retry) scheduleRetry()
        if (someFull) full()
        publish()
    }

    /**
     * The MIME type to store. Another app chose it (a share's
     * `ContentResolver.getType`), so one OkHttp can't parse is replaced
     * here, never handed to `toMediaType()` on a retry.
     */
    internal fun safeType(contentType: String): String =
        contentType.takeIf { it.toMediaTypeOrNull() != null } ?: "application/octet-stream"

    private fun full() {
        Log.w(TAG, "home vault queue is full; not queued")
        problem(
            if (signerIsLocal()) "The queue is full; new media is not being sent"
            else "The queue is full; new media is not being sent. Tap Send now to approve what waits",
        )
    }

    fun drainSoon(userInitiated: Boolean = false) {
        if (!userInitiated) {
            scope.launch { drain() }
            return
        }
        // A second tap while one pass runs adds nothing: the cap is per tap.
        if (!userPassRunning.compareAndSet(false, true)) return
        scope.launch {
            try {
                drain(userInitiated = true)
                publicPass(userInitiated = true)
                schedulePublicCopies()
            } finally {
                userPassRunning.set(false)
            }
        }
    }

    /**
     * Send what is due, oldest first. An item that comes back RETRY waits
     * its own backoff and the rest go on; only an unreachable vault stops
     * the pass. [userInitiated] (Send now) ignores backoff and may prompt
     * an external signer; a background pass never does.
     */
    suspend fun drain(userInitiated: Boolean = false) {
        try {
            drainPass(userInitiated)
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Throwable) {
            // Queue bookkeeping (a full disk) failed outside any one item.
            Log.e(TAG, "home vault pass failed", e)
            problem("Could not update the queue")
        }
    }

    private suspend fun drainPass(userInitiated: Boolean) = drainLock.withLock {
        publish()
        val lanes = lanes()
        dropRemovedMacQueues(lanes)
        for ((target, q) in lanes) drainLane(target.npub, q, target.role, userInitiated)
        publish()
    }

    /** A Mac or phone taken out of My Devices: what waited for it has nowhere to go. */
    private fun dropRemovedMacQueues(lanes: List<Pair<MeshSendTarget, HomeVaultQueue>>) {
        // Only against a loaded config: before it loads it lists no Mac at all, and every
        // queue would go (Tron, #1025). A loaded one always names its owner.
        if (configStore.config.value.ownerNpub.isBlank() || !ownerIsActive()) return
        // Every own-queue lane (Macs and phones), not only Macs: a phone's queue was wiped each pass.
        val macs = lanes.filter { it.first.role != DeviceRole.HOME_VAULT }.map { it.first.npub }.toSet()
        macQueueRoot.listFiles()?.filter { it.isDirectory && it.name !in macs }?.forEach { dir ->
            macQueues.remove(dir.name)?.clear()
            dir.deleteRecursively()
        }
    }

    /** One device's queue. Only an unreachable device stops its own pass. */
    private suspend fun drainLane(npub: String, queue: HomeVaultQueue, role: DeviceRole, userInitiated: Boolean) {
        val label = MeshSendTargets.label(role)
        val now = System.currentTimeMillis()
        val gaveUp = queue.items().filter { HomeVaultRules.expired(it, now, HomeVaultRules.isLane(role)) }
        gaveUp.forEach {
            Log.w(TAG, "home vault: gave up on ${it.type} ${it.key.take(8)} after ${it.attempts} tries")
            queue.remove(it.key)
        }
        if (gaveUp.isNotEmpty()) {
            problem("Gave up sending ${gaveUp.size} ${if (gaveUp.size == 1) "item" else "items"} to ${MeshSendTargets.destination(role)}")
        }
        val items = queue.items()
        if (items.isEmpty()) return
        if (!FipsBridge.status().running) {
            problem("The mesh is off")
            scheduleRetry()
            return
        }
        val base = FipsMediaRouter.ingressBase(npub)
        if (base == null) {
            problem("$label not reachable")
            scheduleRetry()
            return
        }
        // Nothing on a mesh lane waits for a signer (mesh key; see needsOwnerSignature): only backoff selects.
        val selection = HomeVaultRules.select(
            items, now, userInitiated, signerIsLocal(),
            needsSignature = HomeVaultRules::needsOwnerSignature,
        )
        if (selection.heldForSigner) problem("Your signer needs you: tap Send now")
        for (item in selection.toTry) {
            val outcome = try {
                when (item.type) {
                    HomeVaultQueue.TYPE_BLOB -> sendBlob(base, item, queue, npub)
                    HomeVaultQueue.TYPE_EVENT -> sendEvent(base, item)
                    HomeVaultQueue.TYPE_FILE_NOTE ->
                        if (role == DeviceRole.HOME_VAULT) sendFileNote(base, item, npub) else HomeVaultSend.REJECTED
                    else -> HomeVaultSend.REJECTED
                }
            } catch (e: IOException) {
                // The vault, not the item: stop and try the lot later.
                Log.w(TAG, "home vault: ${item.type} ${item.key.take(8)}: ${e.message}")
                FipsMediaRouter.forget(npub)
                problem("$label not reachable")
                break
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: Throwable) {
                // Anything else is this item's fault and would fail every
                // time; dropping it keeps one bad entry from blocking or
                // crashing every launch.
                Log.e(TAG, "home vault: dropping ${item.type} ${item.key.take(8)}", e)
                HomeVaultSend.REJECTED
            }
            record(item, outcome, npub, now, queue, role)
        }
        if (queue.size > 0) scheduleRetry()
    }

    /** Apply one send's outcome to the queue. */
    internal fun record(item: HomeVaultQueue.Item, outcome: HomeVaultSend, npub: String, now: Long, queue: HomeVaultQueue, role: DeviceRole) {
        when (outcome) {
            HomeVaultSend.SENT -> {
                queue.remove(item.key)
                _state.value = _state.value.copy(lastSentAt = System.currentTimeMillis(), lastProblem = null)
                Log.i(TAG, "home vault: sent ${item.type} ${item.key.take(8)} to ${npub.take(12)}")
            }
            HomeVaultSend.REJECTED -> {
                queue.remove(item.key)
                problem("${MeshSendTargets.destination(role).replaceFirstChar { it.uppercase() }} refused a ${item.type}")
            }
            HomeVaultSend.RETRY -> {
                queue.update(HomeVaultRules.afterRetry(item, now, HomeVaultRules.isLane(role)))
            }
        }
    }

    /** One blob to [receiver] (the vault's mesh npub) through [base]. */
    internal suspend fun sendBlob(
        base: String,
        item: HomeVaultQueue.Item,
        queue: HomeVaultQueue,
        receiver: String,
        http: OkHttpClient = client,
        check: String? = null,
    ): HomeVaultSend {
        val sha = item.key
        val file = queue.blobFile(sha)
        // Already there (sent before a crash, or uploaded on the kiosk itself).
        // A bunker or Amber is never asked for a mesh send: without a local key the mesh key is the only form.
        val meshOnly = HomeVaultRules.meshKeyOnly(item, signerIsLocal())
        http.newCall(VaultCheck.request(base, sha, check ?: checkAuth(sha, receiver, meshOnly))).execute().use {
            if (it.isSuccessful) return HomeVaultSend.SENT
        }
        if (!file.exists()) return HomeVaultSend.REJECTED
        val type = item.contentType ?: "application/octet-stream"
        val mediaType = type.toMediaTypeOrNull() ?: return HomeVaultSend.REJECTED
        // Signed per send, not when queued: Blossom auth expires. This phone's mesh key for this vault
        // (docs/MESH_COPY_V2_CONTRACT.md §2.1); the owner's form only without one (TODO(mesh-key)).
        val meshAuth = meshToken(MeshKeyAuth.Verb.UPLOAD, sha, receiver, "Upload to my vault", MeshKeyAuth.BLOSSOM_LIFETIME_S, file.length())
        // A mesh-key-only item (feed Mirror) waits for this device's mesh key rather than sign as the owner.
        if (meshAuth == null && meshOnly) {
            problem("This phone has no mesh key yet")
            return HomeVaultSend.RETRY
        }
        val auth = meshAuth ?: uploadAuth(sha) ?: run {
            problem("Could not sign the upload")
            return HomeVaultSend.RETRY
        }
        fun put(auth: String) = Request.Builder()
            .url("$base/upload")
            .put(file.asRequestBody(mediaType))
            .header("Authorization", "Nostr $auth")
            .header("Content-Type", type)
            .build()
        val (outcome, ownerRetry) = http.newCall(put(auth)).execute().use { response ->
            val outcome = HomeVaultRules.uploadOutcome(response.code)
            if (outcome != HomeVaultSend.SENT) {
                Log.w(TAG, "home vault upload ${sha.take(8)}: HTTP ${response.code} ${response.reason(200)}")
            }
            outcome to (meshAuth != null && MeshKeyAuth.retriesWithOwnerForm(response))
        }
        // A vault without the paired set yet (an older build, or the box before havend passes it) turns the device
        // form down: one retry with the owner's form while vaults accept it. A vault that has its set says so
        // (X-Mesh-Devices), and its refusal stands. TODO(mesh-key).
        if (!ownerRetry || meshOnly) return outcome
        val ownerAuth = uploadAuth(sha) ?: return outcome
        Log.w(TAG, "home vault did not take the device key for ${sha.take(8)}, sent with the owner's")
        return http.newCall(put(ownerAuth)).execute().use { HomeVaultRules.uploadOutcome(it.code) }
    }

    private suspend fun uploadAuth(sha256: String, content: String = "Upload to home vault"): String? {
        val expiration = System.currentTimeMillis() / 1000 + 600
        val tags = listOf(
            listOf("t", "upload"),
            listOf("x", sha256),
            listOf("expiration", expiration.toString()),
        )
        return signedAuth(tags, content, "upload")
    }

    /**
     * The owner's "get" for the "already on the vault" check, or null. Only with a local signer:
     * Amber or a bunker would be asked once more per blob for a check that, unsigned, still works on
     * the relay port My Devices reach. Only the mesh door needs it (#1050), for a sender the vault
     * does not list (Tod, Tron #1048 #2).
     */
    private suspend fun checkAuth(sha256: String, receiver: String, meshKeyOnly: Boolean = false): String? {
        // This phone's mesh key first, for this vault: a HEAD does not spend it. The owner's form only without a
        // mesh key (TODO(mesh-key)), and never for a mesh-key-only item (an unsigned check still works on the relay port).
        meshToken(MeshKeyAuth.Verb.GET, sha256, receiver, "Check my vault", VaultCheck.AUTH_LIFETIME_S, null)?.let { return it }
        if (meshKeyOnly || !signerIsLocal()) return null
        return signedAuth(VaultCheck.authTags(sha256, System.currentTimeMillis() / 1000), "Check home vault", "check")
    }

    private suspend fun signedAuth(tags: List<List<String>>, content: String, what: String): String? {
        val signed = try {
            // A random suffix keeps two auths for the same blob signed in the
            // same second apart: the vault takes each auth id once, and a
            // repeat id is a 403, which drops the item.
            signer(AUTH_KIND, "$content ${java.util.UUID.randomUUID().toString().take(8)}", tags)
        } catch (e: Exception) {
            Log.w(TAG, "home vault: $what auth not signed: ${e.message}")
            null
        } ?: return null
        return Base64.encodeToString(signed.toByteArray(), Base64.NO_WRAP)
    }

    /** `EVENT` on the vault's relay websocket; waits for its `OK`. */
    private suspend fun sendEvent(base: String, item: HomeVaultQueue.Item): HomeVaultSend {
        val eventJson = item.eventJson ?: return HomeVaultSend.REJECTED
        val answer = CompletableDeferred<HomeVaultSend>()
        val listener = object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                webSocket.send("[\"EVENT\",$eventJson]")
            }

            override fun onMessage(webSocket: WebSocket, text: String) {
                okFor(text, item.key)?.let { (accepted, message) ->
                    if (!accepted) Log.w(TAG, "home vault refused event ${item.key.take(8)}: $message")
                    answer.complete(HomeVaultRules.eventOutcome(accepted, message))
                }
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                Log.w(TAG, "home vault websocket: ${t.message}")
                answer.complete(HomeVaultSend.RETRY)
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                answer.complete(HomeVaultSend.RETRY)
            }
        }
        val socket = client.newWebSocket(
            // Marked second-hand: the vault stores the note and does not blast it again; this
            // device published it (haven-go isSecondHandConn, device sync map §4.5).
            Request.Builder().url(PulledInjection.url(base.replaceFirst("http://", "ws://"))).build(),
            listener,
        )
        return try {
            withTimeoutOrNull(EVENT_OK_TIMEOUT_MS) { answer.await() } ?: HomeVaultSend.RETRY
        } finally {
            socket.close(1000, null)
        }
    }

    /**
     * One file note to the vault's `/files` (plan gap 1). An add signs the 1063 now, with the mesh key. A delete
     * AUTHs (reads need it), asks `#x` for every note naming the blob, then signs one kind 5 for them all; none left
     * is done. Accepted or `duplicate:` is done, `restricted:` (this device unpaired, an account key) is dropped,
     * anything else waits ([HomeVaultRules.eventOutcome]).
     */
    internal suspend fun sendFileNote(base: String, item: HomeVaultQueue.Item, vaultNpub: String, http: OkHttpClient = client): HomeVaultSend {
        val draft = item.fileNote ?: return HomeVaultSend.REJECTED
        val owner = ownerHex().lowercase()
        val url = FileNote.filesUrl(base) ?: return HomeVaultSend.REJECTED
        val note = when (draft.action) {
            HomeVaultQueue.FileNoteDraft.ADD ->
                FileNote.tags(draft.sha256, draft.mime, draft.size, owner, draft.servers) ?: return HomeVaultSend.REJECTED
            HomeVaultQueue.FileNoteDraft.DELETE ->
                if (!FileNote.isHex64(draft.sha256) || !FileNote.isHex64(owner)) return HomeVaultSend.REJECTED else null
            else -> return HomeVaultSend.REJECTED
        }
        val socket = FilesSocket.open(http, url, vaultNpub, fileNoteSign)
        try {
            val (kind, tags) = if (note != null) {
                FileNote.KIND to note
            } else {
                if (!socket.auth()) return HomeVaultSend.RETRY
                val filter = buildJsonObject {
                    put("kinds", buildJsonArray { add(JsonPrimitive(FileNote.KIND)) })
                    put("#x", buildJsonArray { add(JsonPrimitive(draft.sha256)) })
                    put("#p", buildJsonArray { add(JsonPrimitive(owner)) })
                }
                val found = socket.query("files-del", filter) ?: return HomeVaultSend.RETRY
                val ids = found.mapNotNull { FileNote.parse(it)?.takeIf { n -> n.sha256 == draft.sha256 }?.id }
                // Nothing names it: nothing to take back.
                FileNote.DELETION_KIND to (FileNoteDeletion.tags(ids, draft.sha256, owner) ?: return HomeVaultSend.SENT)
            }
            // No mesh key yet (the engine makes it): try again later, never the owner's signer.
            val signed = fileNoteSign(kind, tags) ?: return HomeVaultSend.RETRY
            val (accepted, message) = socket.publish(signed) ?: return HomeVaultSend.RETRY
            if (!accepted) Log.w(TAG, "home vault /files refused a ${draft.action} for ${draft.sha256.take(8)}: $message")
            return HomeVaultRules.eventOutcome(accepted, message)
        } finally {
            socket.close()
        }
    }

    private fun okFor(message: String, eventId: String): Pair<Boolean, String>? = runCatching {
        val parsed = Json.parseToJsonElement(message).jsonArray
        if (parsed.size < 3 || parsed[0].jsonPrimitive.contentOrNull != "OK") return null
        if (parsed[1].jsonPrimitive.contentOrNull != eventId) return null
        (parsed[2].jsonPrimitive.booleanOrNull ?: false) to (parsed.getOrNull(3)?.jsonPrimitive?.contentOrNull ?: "")
    }.getOrNull()

    /**
     * Try again in a minute, for as long as something waits. One timer at a time. Between tries, look at who the mesh
     * is connected to: a device that just came into reach gets what waits on its lane now, not at the end of its
     * backoff (Logen 2026-11-13).
     */
    internal fun scheduleRetry() {
        if (retryJob?.isActive == true) return
        retryJob = scope.launch {
            var peers = connectedPeers()
            var sinceDrain = 0L
            while (isActive) {
                delay(REACH_CHECK_MS)
                sinceDrain += REACH_CHECK_MS
                val lanes = lanes()
                if (lanes.none { it.second.size > 0 }) break
                val now = connectedPeers()
                val newly = HomeVaultRules.newlyInReach(now, peers)
                peers = now
                var woke = false
                // Under the drain lock: a pass in flight must not have its tries written back over.
                if (newly.isNotEmpty()) drainLock.withLock {
                    for ((target, q) in lanes) {
                        if (!HomeVaultRules.isLane(target.role) || target.npub !in newly) continue
                        val due = HomeVaultRules.wokenOnReach(q.items())
                        due.forEach { q.update(it) }
                        if (due.isNotEmpty()) {
                            Log.i(TAG, "home vault: ${target.npub.take(12)} came into reach, retrying its lane now")
                            woke = true
                        }
                    }
                }
                if (woke || sinceDrain >= RETRY_MS) {
                    sinceDrain = 0
                    drain()
                }
            }
        }
    }

    private fun connectedPeers(): Set<String> =
        runCatching { FipsBridge.status().peers.toSet() }.getOrDefault(emptySet())

    /** The mesh door for [npub], or null while the mesh is off or the device is not reachable; swapped in tests. */
    internal var meshIngress: (npub: String) -> String? =
        { npub -> if (FipsBridge.status().running) FipsMediaRouter.ingressBase(npub) else null }

    internal fun problem(text: String) {
        _state.value = _state.value.copy(lastProblem = text)
    }

    internal fun publish() {
        _state.value = _state.value.copy(waiting = waitingCount(), publicPending = publicCopies.size)
    }

    private fun Response.reason(max: Int): String =
        runCatching { body?.string()?.take(max) }.getOrNull().orEmpty()

    private companion object {
        const val TAG = "HomeVault"
        const val AUTH_KIND = 24242
        const val RETRY_MS = 60_000L
        const val REACH_CHECK_MS = 10_000L
        const val EVENT_OK_TIMEOUT_MS = 15_000L
        const val ENSURE_CALL_TIMEOUT_S = 45L
        const val ENSURE_LOCK_WAIT_MS = 10_000L
        const val ENSURE_LINK_WAIT_MS = 30_000L
        const val ENSURE_RETRY_MS = 3_000L
    }
}
