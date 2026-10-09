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
    /** Signs a Nostr event as the owner, or returns null. Wired by NostrService. */
    @Volatile
    var signer: suspend (kind: Int, content: String, tags: List<List<String>>) -> String? = { _, _, _ -> null }

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

    /** The owner's current 10063, or null when it isn't known. Wired by NostrService. */
    @Volatile
    var ownerServerList: () -> List<String>? = { null }

    private val queue = HomeVaultQueue(File(context.filesDir, "home_vault_queue"))

    /**
     * Blobs a note was published for while only the home vault had them.
     * Each is pushed to the public servers until one takes it.
     */
    private val publicCopies = HomeVaultQueue(File(context.filesDir, "home_vault_public_copies"))
    private var publicJob: Job? = null
    private val publicLock = Mutex()

    /** Host a blob from this phone's relay on the public servers; true once one has it. Wired by BlossomService. */
    @Volatile
    var hostPublicly: suspend (sha256: String, contentType: String) -> Boolean = { _, _ -> false }
    // A failure that escapes a pass (a full disk while saving the queue) is
    // logged, never allowed to kill the app: a queue on disk would re-run
    // the same pass after every launch.
    private val scope = CoroutineScope(
        SupervisorJob() + Dispatchers.IO + CoroutineExceptionHandler { _, e -> Log.e(TAG, "home vault", e) },
    )
    private val drainLock = Mutex()
    private var retryJob: Job? = null

    private val client = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .writeTimeout(120, TimeUnit.SECONDS)
        .readTimeout(60, TimeUnit.SECONDS)
        .build()

    data class State(
        val waiting: Int = 0,
        /** Notes already out whose media no public server has yet. */
        val publicPending: Int = 0,
        val lastSentAt: Long? = null,
        val lastProblem: String? = null,
    )

    private val _state = MutableStateFlow(State(waiting = queue.size, publicPending = publicCopies.size))
    val state: StateFlow<State> = _state.asStateFlow()

    /** The chosen home vault's mesh npub, or null when there is none. */
    val homeVaultNpub: String? get() = configStore.config.value.homeVaultNpub

    /** The home vault to send to right now: none while another account is active. */
    private val activeVault: String? get() = homeVaultNpub?.takeIf { ownerIsActive() }

    init {
        if (queue.size > 0) scheduleRetry()
        if (publicCopies.size > 0) schedulePublicCopies()
    }

    /**
     * Make sure the home vault has [sha256] now: send what waits, then ask
     * it. Called while the owner is posting, so it may prompt the signer.
     */
    suspend fun ensureOnVault(sha256: String): Boolean {
        val npub = activeVault ?: return false
        return withTimeoutOrNull(ENSURE_TIMEOUT_MS) {
            drain(userInitiated = true)
            val base = FipsMediaRouter.ingressBase(npub) ?: return@withTimeoutOrNull false
            try {
                client.newCall(Request.Builder().url("$base/$sha256").head().build()).execute().use { it.isSuccessful }
            } catch (e: IOException) {
                false
            }
        } ?: false
    }

    /** Keep pushing [sha256] to the public servers until one has it. */
    fun needsPublicCopy(sha256: String, contentType: String) {
        if (publicCopies.addPublicCopy(sha256, safeType(contentType))) schedulePublicCopies()
    }

    /** Push the public copies every minute while any wait. One loop at a time. */
    private fun schedulePublicCopies() {
        if (publicJob?.isActive == true) return
        publicJob = scope.launch {
            while (isActive && publicCopies.size > 0) {
                publicPass(userInitiated = false)
                delay(RETRY_MS)
            }
        }
    }

    /**
     * One try at each due public copy, with the vault queue's backoff and
     * give-up rules. Each try signs an upload auth, so a background pass
     * skips them unless the signer is a local key; Send now does them all.
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
        val now = System.currentTimeMillis()
        val localSigner = signerIsLocal()
        var prompts = 0
        for (item in publicCopies.items()) {
            if (HomeVaultRules.expired(item, now)) {
                Log.w(TAG, "public copy of ${item.key.take(8)}: gave up after ${item.attempts} tries")
                publicCopies.remove(item.key)
                continue
            }
            if (!userInitiated && (item.nextAt > now || !localSigner)) continue
            if (!localSigner && prompts++ >= HomeVaultRules.PROMPTS_PER_TAP) continue
            val hosted = try {
                hostPublicly(item.key, item.contentType ?: "application/octet-stream")
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: Throwable) {
                Log.w(TAG, "public copy of ${item.key.take(8)}: ${e.message}")
                false
            }
            if (hosted) {
                publicCopies.remove(item.key)
                Log.i(TAG, "public copy of ${item.key.take(8)} is up")
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

    /** Also send this signed event to the home vault, if it is the owner's. */
    fun offerEvent(eventId: String, pubkey: String, eventJson: String) {
        if (activeVault == null || pubkey.isEmpty() || pubkey != ownerHex()) return
        // Off the caller's thread: postEvent runs on the main thread.
        scope.launch { if (queue.addEvent(eventId, eventJson)) drain() else full() }
    }

    /** Also send this blob to the home vault, copied from [source]. */
    fun offerBlob(sha256: String, contentType: String, source: File) =
        offer(sha256, contentType, source.length()) { source.copyTo(it, overwrite = true) }

    fun offerBlob(sha256: String, contentType: String, data: ByteArray) =
        offer(sha256, contentType, data.size.toLong()) { it.writeBytes(data) }

    /** Synchronous (the caller's source may be deleted next), and never throws into an upload. */
    private fun offer(sha256: String, contentType: String, byteCount: Long, writeTo: (File) -> Unit) {
        if (activeVault == null) return
        val queued = try {
            queue.addBlob(sha256, safeType(contentType), byteCount, writeTo = writeTo)
        } catch (e: Exception) {
            Log.w(TAG, "home vault: could not queue ${sha256.take(8)}: ${e.message}")
            false
        }
        if (queued) drainSoon() else full()
    }

    /**
     * The MIME type to store. Another app chose it (a share's
     * `ContentResolver.getType`), so one OkHttp can't parse is replaced
     * here, never handed to `toMediaType()` on a retry.
     */
    private fun safeType(contentType: String): String =
        contentType.takeIf { it.toMediaTypeOrNull() != null } ?: "application/octet-stream"

    private fun full() {
        Log.w(TAG, "home vault queue is full; not queued")
        problem(
            if (signerIsLocal()) "The queue is full; new media is not being sent"
            else "The queue is full; new media is not being sent. Tap Send now to approve what waits",
        )
    }

    fun drainSoon(userInitiated: Boolean = false) {
        scope.launch {
            drain(userInitiated)
            if (userInitiated) publicPass(userInitiated = true)
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
        val npub = activeVault ?: return@withLock
        val now = System.currentTimeMillis()
        queue.items().filter { HomeVaultRules.expired(it, now) }.forEach {
            Log.w(TAG, "home vault: gave up on ${it.type} ${it.key.take(8)} after ${it.attempts} tries")
            queue.remove(it.key)
        }
        val items = queue.items()
        if (items.isEmpty()) return@withLock publish()
        // Re-checked each pass: a stale or withdrawn list must not keep
        // sending to a vault the owner no longer lists. It waits instead.
        val listed = ownerServerList()
        if (listed != null && HomeVaultRules.candidates(listed, null).none { it == npub }) {
            problem("Home vault is not on the mesh now")
            scheduleRetry()
            return@withLock publish()
        }
        if (!FipsBridge.status().running) {
            problem("The mesh is off")
            scheduleRetry()
            return@withLock publish()
        }
        val base = FipsMediaRouter.ingressBase(npub)
        if (base == null) {
            problem("Home vault not reachable")
            scheduleRetry()
            return@withLock publish()
        }
        val localSigner = signerIsLocal()
        var prompts = 0
        for (item in items) {
            if (!userInitiated && item.nextAt > now) continue
            if (item.type == HomeVaultQueue.TYPE_BLOB && !localSigner) {
                // Each blob is one signer prompt; a tap approves a batch, not the whole queue.
                if (!userInitiated || prompts >= HomeVaultRules.PROMPTS_PER_TAP) {
                    problem("Your signer needs you: tap Send now")
                    continue
                }
                prompts++
            }
            val outcome = try {
                when (item.type) {
                    HomeVaultQueue.TYPE_BLOB -> sendBlob(base, item)
                    HomeVaultQueue.TYPE_EVENT -> sendEvent(base, item)
                    else -> HomeVaultSend.REJECTED
                }
            } catch (e: IOException) {
                // The vault, not the item: stop and try the lot later.
                Log.w(TAG, "home vault: ${item.type} ${item.key.take(8)}: ${e.message}")
                FipsMediaRouter.forget(npub)
                problem("Home vault not reachable")
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
            when (outcome) {
                HomeVaultSend.SENT -> {
                    queue.remove(item.key)
                    _state.value = _state.value.copy(lastSentAt = System.currentTimeMillis(), lastProblem = null)
                    Log.i(TAG, "home vault: sent ${item.type} ${item.key.take(8)} to ${npub.take(12)}")
                }
                HomeVaultSend.REJECTED -> {
                    queue.remove(item.key)
                    problem("The home vault refused a ${item.type}")
                }
                HomeVaultSend.RETRY -> {
                    val attempts = item.attempts + 1
                    queue.update(item.copy(attempts = attempts, nextAt = now + HomeVaultRules.backoffMs(attempts)))
                }
            }
        }
        if (queue.size > 0) scheduleRetry()
        publish()
    }

    private suspend fun sendBlob(base: String, item: HomeVaultQueue.Item): HomeVaultSend {
        val sha = item.key
        val file = queue.blobFile(sha)
        // Already there (sent before a crash, or uploaded on the kiosk itself).
        client.newCall(Request.Builder().url("$base/$sha").head().build()).execute().use {
            if (it.isSuccessful) return HomeVaultSend.SENT
        }
        if (!file.exists()) return HomeVaultSend.REJECTED
        // Signed per send, not when queued: Blossom auth expires.
        val auth = uploadAuth(sha) ?: run {
            problem("Could not sign the upload")
            return HomeVaultSend.RETRY
        }
        val type = item.contentType ?: "application/octet-stream"
        val mediaType = type.toMediaTypeOrNull() ?: return HomeVaultSend.REJECTED
        val request = Request.Builder()
            .url("$base/upload")
            .put(file.asRequestBody(mediaType))
            .header("Authorization", "Nostr $auth")
            .header("Content-Type", type)
            .build()
        return client.newCall(request).execute().use { response ->
            val outcome = HomeVaultRules.uploadOutcome(response.code)
            if (outcome != HomeVaultSend.SENT) {
                Log.w(TAG, "home vault upload ${sha.take(8)}: HTTP ${response.code} ${response.reason(200)}")
            }
            outcome
        }
    }

    private suspend fun uploadAuth(sha256: String): String? {
        val expiration = System.currentTimeMillis() / 1000 + 600
        val tags = listOf(
            listOf("t", "upload"),
            listOf("x", sha256),
            listOf("expiration", expiration.toString()),
        )
        val signed = try {
            signer(AUTH_KIND, "Upload to home vault", tags)
        } catch (e: Exception) {
            Log.w(TAG, "home vault: upload auth not signed: ${e.message}")
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
            Request.Builder().url(base.replaceFirst("http://", "ws://")).build(),
            listener,
        )
        return try {
            withTimeoutOrNull(EVENT_OK_TIMEOUT_MS) { answer.await() } ?: HomeVaultSend.RETRY
        } finally {
            socket.close(1000, null)
        }
    }

    private fun okFor(message: String, eventId: String): Pair<Boolean, String>? = runCatching {
        val parsed = Json.parseToJsonElement(message).jsonArray
        if (parsed.size < 3 || parsed[0].jsonPrimitive.contentOrNull != "OK") return null
        if (parsed[1].jsonPrimitive.contentOrNull != eventId) return null
        (parsed[2].jsonPrimitive.booleanOrNull ?: false) to (parsed.getOrNull(3)?.jsonPrimitive?.contentOrNull ?: "")
    }.getOrNull()

    /** Try again in a minute, for as long as something waits. One timer at a time. */
    private fun scheduleRetry() {
        if (retryJob?.isActive == true) return
        retryJob = scope.launch {
            while (isActive) {
                delay(RETRY_MS)
                if (queue.size == 0 || activeVault == null) break
                drain()
            }
        }
    }

    private fun problem(text: String) {
        _state.value = _state.value.copy(lastProblem = text)
    }

    private fun publish() {
        _state.value = _state.value.copy(waiting = queue.size, publicPending = publicCopies.size)
    }

    private fun Response.reason(max: Int): String =
        runCatching { body?.string()?.take(max) }.getOrNull().orEmpty()

    private companion object {
        const val TAG = "HomeVault"
        const val AUTH_KIND = 24242
        const val RETRY_MS = 60_000L
        const val EVENT_OK_TIMEOUT_MS = 15_000L
        const val ENSURE_TIMEOUT_MS = 60_000L
    }
}
