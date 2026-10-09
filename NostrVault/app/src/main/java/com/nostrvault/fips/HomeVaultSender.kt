package com.nostrvault.fips

import android.content.Context
import android.util.Base64
import android.util.Log
import com.nostrvault.data.local.ConfigStore
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.CompletableDeferred
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
import okhttp3.MediaType.Companion.toMediaType
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

    private val queue = HomeVaultQueue(File(context.filesDir, "home_vault_queue"))
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val drainLock = Mutex()
    private var retryJob: Job? = null

    private val client = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .writeTimeout(120, TimeUnit.SECONDS)
        .readTimeout(60, TimeUnit.SECONDS)
        .build()

    data class State(
        val waiting: Int = 0,
        val lastSentAt: Long? = null,
        val lastProblem: String? = null,
    )

    private val _state = MutableStateFlow(State(waiting = queue.size))
    val state: StateFlow<State> = _state.asStateFlow()

    /** The chosen home vault's mesh npub, or null when there is none. */
    val homeVaultNpub: String? get() = configStore.config.value.homeVaultNpub

    init {
        if (queue.size > 0) scheduleRetry()
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
        if (homeVaultNpub == null || pubkey.isEmpty() || pubkey != ownerHex()) return
        if (queue.addEvent(eventId, eventJson)) drainSoon()
    }

    /** Also send this blob to the home vault, copied from [source]. */
    fun offerBlob(sha256: String, contentType: String, source: File) {
        if (homeVaultNpub == null) return
        if (queue.addBlob(sha256, contentType) { source.copyTo(it, overwrite = true) }) drainSoon()
    }

    fun offerBlob(sha256: String, contentType: String, data: ByteArray) {
        if (homeVaultNpub == null) return
        if (queue.addBlob(sha256, contentType) { it.writeBytes(data) }) drainSoon()
    }

    fun drainSoon() {
        scope.launch { drain() }
    }

    /** Send what waits, oldest first, stopping at the first that can't go yet. */
    suspend fun drain() = drainLock.withLock {
        publish()
        val npub = homeVaultNpub ?: return@withLock
        val items = queue.items()
        if (items.isEmpty()) return@withLock
        if (!FipsBridge.status().running) {
            problem("The mesh is off")
            scheduleRetry()
            return@withLock
        }
        val base = FipsMediaRouter.ingressBase(npub)
        if (base == null) {
            problem("Home vault not reachable")
            scheduleRetry()
            return@withLock
        }
        for (item in items) {
            val outcome = try {
                when (item.type) {
                    HomeVaultQueue.TYPE_BLOB -> sendBlob(base, item)
                    HomeVaultQueue.TYPE_EVENT -> sendEvent(base, item)
                    else -> HomeVaultSend.REJECTED
                }
            } catch (e: IOException) {
                Log.w(TAG, "home vault: ${item.type} ${item.key.take(8)}: ${e.message}")
                FipsMediaRouter.forget(npub)
                HomeVaultSend.RETRY
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
                    problem("Home vault not reachable")
                    scheduleRetry()
                    break
                }
            }
        }
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
        val request = Request.Builder()
            .url("$base/upload")
            .put(file.asRequestBody(type.toMediaType()))
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
                if (queue.size == 0 || homeVaultNpub == null) break
                drain()
            }
        }
    }

    private fun problem(text: String) {
        _state.value = _state.value.copy(lastProblem = text)
    }

    private fun publish() {
        _state.value = _state.value.copy(waiting = queue.size)
    }

    private fun Response.reason(max: Int): String =
        runCatching { body?.string()?.take(max) }.getOrNull().orEmpty()

    private companion object {
        const val TAG = "HomeVault"
        const val AUTH_KIND = 24242
        const val RETRY_MS = 60_000L
        const val EVENT_OK_TIMEOUT_MS = 15_000L
    }
}
