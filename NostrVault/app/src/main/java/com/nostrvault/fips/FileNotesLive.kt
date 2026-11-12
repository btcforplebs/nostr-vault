package com.nostrvault.fips

import android.util.Log
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.isActive
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import java.util.concurrent.TimeUnit
import javax.inject.Inject
import javax.inject.Singleton

/**
 * The live `/files` subscription on the home vault (RESEARCH/NV_MEDIA_LIVE_FILE_NOTES_PLAN.md §1 "Live"): while a
 * Media tab collects [events], one REQ `{"kinds":[1063,5],"#p":[owner]}` stays open after EOSE, AUTHed with this
 * device's mesh key ([MeshKeySigner.fileNotes]), never the account key. A drop (sleep, the mesh going away) asks
 * again from the caller's last `created_at` less [FileNotesState.RESUBSCRIBE_OVERLAP]. With no home vault, or another
 * account active, it waits: the Media tab's server listing carries it alone, as before.
 */
@Singleton
class FileNotesLive @Inject constructor(private val sender: HomeVaultSender) {
    /** The mesh door for a vault, or null while unreachable; swapped in tests. */
    internal var ingress: (npub: String) -> String? = { npub -> if (FipsBridge.status().running) FipsMediaRouter.ingressBase(npub) else null }

    /** Signs a `/files` event with the mesh key; swapped in tests. */
    internal var sign: (kind: Int, tags: List<List<String>>) -> String? = { kind, tags -> MeshKeySigner.fileNotes(kind, tags) }

    internal var client: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        // Open after EOSE, quiet for as long as nothing is uploaded: no read limit, pings keep it honest.
        .readTimeout(0, TimeUnit.MILLISECONDS)
        .pingInterval(30, TimeUnit.SECONDS)
        .build()

    internal var retryMs: (attempt: Int) -> Long = { attempt -> (5_000L shl attempt.coerceIn(0, 4)).coerceAtMost(60_000L) }

    /** The owner's `/files` events, as the room sends them, for as long as this is collected. [since] is read on each (re)subscribe. */
    fun events(since: () -> Long?): Flow<JsonObject> = flow {
        var failures = 0
        while (currentCoroutineContext().isActive) {
            val npub = sender.homeVaultNpub
            val owner = sender.ownerHex()
            if (npub == null || !sender.ownerIsActive() || !FileNote.isHex64(owner)) {
                delay(IDLE_MS)
                continue
            }
            val url = ingress(npub)?.let(FileNote::filesUrl)
            if (url == null) {
                delay(retryMs(failures++))
                continue
            }
            val socket = FilesSocket.open(client, url, npub, sign)
            try {
                if (socket.auth()) {
                    failures = 0
                    socket.subscribe(SUB_ID, FileNote.liveFilter(owner, since())) { emit(it) }
                } else {
                    Log.w(TAG, "files: AUTH not taken by ${npub.take(12)}")
                }
            } finally {
                socket.close()
            }
            delay(retryMs(failures++))
        }
    }.flowOn(Dispatchers.IO)

    private companion object {
        const val TAG = "FileNotesLive"
        const val SUB_ID = "files-live"
        const val IDLE_MS = 30_000L
    }
}

/**
 * One websocket to a vault's `/files`, used one step at a time: AUTH, then a query, a publish, or a live subscription.
 * Every message lands in one channel, and each step reads it until its own answer.
 */
internal class FilesSocket private constructor(
    private val url: String,
    private val vaultNpub: String?,
    private val sign: (kind: Int, tags: List<List<String>>) -> String?,
) {
    private val messages = Channel<JsonArray>(Channel.UNLIMITED)
    private val challenge = CompletableDeferred<String>()
    private lateinit var socket: WebSocket

    private val listener = object : WebSocketListener() {
        override fun onMessage(webSocket: WebSocket, text: String) {
            val msg = runCatching { Json.parseToJsonElement(text) as? JsonArray }.getOrNull() ?: return
            if (msg.word(0) == "AUTH") msg.word(1)?.let { challenge.complete(it) } else messages.trySend(msg)
        }

        override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) = ended()

        override fun onClosed(webSocket: WebSocket, code: Int, reason: String) = ended()

        override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
            webSocket.close(1000, null)
            ended()
        }
    }

    private fun ended() {
        messages.close()
        challenge.cancel()
    }

    /** NIP-42 with the mesh key, on the vault's challenge: true once the room says OK. */
    suspend fun auth(timeoutMs: Long = STEP_TIMEOUT_MS): Boolean {
        val chal = withTimeoutOrNull(timeoutMs) { runCatching { challenge.await() }.getOrNull() } ?: return false
        val signed = sign(FileNote.AUTH_KIND, FileNote.authTags(FileNote.authRelayUrl(vaultNpub, url), chal)) ?: return false
        val id = idOf(signed) ?: return false
        if (!socket.send("[\"AUTH\",$signed]")) return false
        return ok(id, timeoutMs)?.first == true
    }

    /** `EVENT` and its `OK`: (accepted, message), or null on no answer. */
    suspend fun publish(eventJson: String, timeoutMs: Long = STEP_TIMEOUT_MS): Pair<Boolean, String>? {
        val id = idOf(eventJson) ?: return null
        if (!socket.send("[\"EVENT\",$eventJson]")) return null
        return ok(id, timeoutMs)
    }

    /** Every event up to EOSE for [filter], or null when the room closed it or did not answer. */
    suspend fun query(subId: String, filter: JsonObject, timeoutMs: Long = STEP_TIMEOUT_MS): List<JsonObject>? {
        if (!socket.send("[\"REQ\",\"$subId\",$filter]")) return null
        val out = mutableListOf<JsonObject>()
        val done = withTimeoutOrNull(timeoutMs) {
            for (msg in messages) {
                if (msg.word(1) != subId) continue
                when (msg.word(0)) {
                    "EVENT" -> (msg.getOrNull(2) as? JsonObject)?.let(out::add)
                    "EOSE" -> return@withTimeoutOrNull true
                    "CLOSED" -> return@withTimeoutOrNull false
                }
            }
            false
        }
        socket.send("[\"CLOSE\",\"$subId\"]")
        return if (done == true) out else null
    }

    /** A live REQ: each event to [onEvent], until the room closes it or the socket drops. */
    suspend fun subscribe(subId: String, filter: JsonObject, onEvent: suspend (JsonObject) -> Unit) {
        if (!socket.send("[\"REQ\",\"$subId\",$filter]")) return
        for (msg in messages) {
            if (msg.word(1) != subId) continue
            when (msg.word(0)) {
                "EVENT" -> (msg.getOrNull(2) as? JsonObject)?.let { onEvent(it) }
                "CLOSED" -> return
            }
        }
    }

    fun close() {
        socket.close(1000, null)
        ended()
    }

    private suspend fun ok(id: String, timeoutMs: Long): Pair<Boolean, String>? = withTimeoutOrNull(timeoutMs) {
        for (msg in messages) {
            if (msg.word(0) != "OK" || msg.word(1) != id) continue
            val accepted = (msg.getOrNull(2) as? JsonPrimitive)?.booleanOrNull ?: false
            return@withTimeoutOrNull accepted to (msg.word(3) ?: "")
        }
        null
    }

    companion object {
        const val STEP_TIMEOUT_MS = 15_000L

        fun open(client: OkHttpClient, url: String, vaultNpub: String?, sign: (Int, List<List<String>>) -> String?): FilesSocket {
            val s = FilesSocket(url, vaultNpub, sign)
            s.socket = client.newWebSocket(Request.Builder().url(url).build(), s.listener)
            return s
        }

        fun idOf(eventJson: String): String? = runCatching {
            (Json.parseToJsonElement(eventJson) as JsonObject)["id"]?.jsonPrimitive?.contentOrNull
        }.getOrNull()?.takeIf { it.isNotEmpty() }

        private fun JsonArray.word(i: Int): String? = (getOrNull(i) as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull
    }
}
