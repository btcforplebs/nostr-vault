package com.nostrvault.service

import android.util.Log
import com.nostrvault.data.remote.WebSocketClient
import com.nostrvault.fips.PulledInjection
import com.nostrvault.relay.HavenConfig
import com.nostrvault.relay.MacSync
import com.nostrvault.relay.RelayConfiguration
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.withTimeoutOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener

/**
 * Publish for me (sync pick 1, Logen 2026-11-12): "The vault sends your phone's posts. Exactly one device blasts each
 * note: the vault if it confirms within ~10 s, otherwise the phone."
 *
 * The phone hands its note to the owner's Mac on the mesh ([target]) on a publish connection: the Mac's dialed address
 * (never `?pulled=1`) with this device's mesh-key token ([com.nostrvault.fips.MeshKeySigner.publish], never the
 * account key). [VaultHandoffDecision] reads the answer. Twin of Apple's `VaultPublishHandoff.swift`.
 */
object VaultPublishHandoff {
    private const val TAG = "VaultPublishHandoff"

    /** How long a post waits for the vault before the phone sends it itself. */
    const val HOLD_MS = 10_000L

    /** How long the second-hand copy on this phone's relay waits for its OK. */
    const val LOCAL_OK_MS = 5_000L

    /**
     * The vault that sends this phone's posts: the owner's Mac on the mesh as dialed at relay start, the same one the
     * blast list names ([RelayConfiguration.blastrRelays]). Null when there is none, so posting is as before with no
     * delay.
     */
    fun target(config: HavenConfig, mesh: RelayConfiguration.MacMeshRelay? = RelayConfiguration.macMeshRelay): RelayConfiguration.MacMeshRelay? {
        if (!config.fipsMeshEnabled) return null
        val npub = MacSync.macMeshNpub(config) ?: return null
        return mesh?.takeIf { it.npub == npub }
    }

    /** The one gate: true when a vault sends this phone's posts. A "Send through my vault" switch hooks in here. */
    fun isEnabled(config: HavenConfig, mesh: RelayConfiguration.MacMeshRelay? = RelayConfiguration.macMeshRelay): Boolean =
        target(config, mesh) != null

    /**
     * Opens the vault at [url] with `Authorization: Nostr <token>`, waits for its first frame to be the publish notice
     * ([VaultHandoffDecision.PUBLISH_NOTICE]), only then sends [eventJson], and waits for its OK; all within [holdMs].
     * No token (no mesh key yet), a refused upgrade (403 for an unpaired device), a closed socket or any other first
     * frame (an older vault) fall back at once, and the note is never sent to such a vault. Never [url] in a log: its
     * path is the ingress token.
     */
    suspend fun handOff(
        url: String,
        eventId: String,
        eventJson: String,
        token: String?,
        holdMs: Long = HOLD_MS,
        client: OkHttpClient = WebSocketClient.sharedLocalhostClient,
    ): VaultHandoffDecision {
        val none = VaultHandoffDecision.decide(connected = false, sawPublishNotice = false, accepted = null, message = null, timedOut = false)
        if (token == null) return none
        val request = runCatching { Request.Builder().url(url).header("Authorization", "Nostr $token").build() }.getOrNull()
            ?: return none
        val answer = CompletableDeferred<VaultHandoffDecision>()
        val listener = object : WebSocketListener() {
            // OkHttp calls one listener's methods in order on one thread.
            private var sawNotice = false

            override fun onMessage(webSocket: WebSocket, text: String) {
                if (!sawNotice) {
                    if (!VaultHandoffDecision.isPublishNotice(text)) {
                        Log.i(TAG, "vault did not say it sends for this device; the phone sends ${eventId.take(8)}")
                        answer.complete(VaultHandoffDecision.decide(connected = true, sawPublishNotice = false, accepted = null, message = null, timedOut = false))
                        return
                    }
                    sawNotice = true
                    webSocket.send("[\"EVENT\",$eventJson]")
                    return
                }
                val (accepted, message) = VaultHandoffDecision.okAnswer(text, eventId) ?: return
                if (!accepted || message.isNotBlank()) Log.i(TAG, "vault will not send ${eventId.take(8)}: $message")
                answer.complete(VaultHandoffDecision.decide(connected = true, sawPublishNotice = true, accepted = accepted, message = message, timedOut = false))
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                Log.i(TAG, "vault publish connection failed (${response?.code ?: t.javaClass.simpleName}); the phone sends")
                answer.complete(none)
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                answer.complete(none)
            }
        }
        val socket = client.newWebSocket(request, listener)
        val decided = withTimeoutOrNull(holdMs) { answer.await() }
        if (decided == null) {
            Log.i(TAG, "vault did not confirm ${eventId.take(8)} within ${holdMs / 1000} s; the phone sends")
            socket.cancel()
            return VaultHandoffDecision.decide(connected = true, sawPublishNotice = false, accepted = null, message = null, timedOut = true)
        }
        socket.close(1000, null)
        return decided
    }

    /**
     * Keeps the vault-sent note on this phone: written to its own relay at [localUrl] marked second-hand
     * ([PulledInjection]), so the relay stores it and never blasts it. True when the relay took it (or held it).
     */
    suspend fun storeLocally(
        localUrl: String,
        eventId: String,
        eventJson: String,
        timeoutMs: Long = LOCAL_OK_MS,
        client: OkHttpClient = WebSocketClient.sharedLocalhostClient,
    ): Boolean {
        val request = runCatching { Request.Builder().url(PulledInjection.url(localUrl)).build() }.getOrNull() ?: return false
        val answer = CompletableDeferred<Boolean>()
        val listener = object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                webSocket.send("[\"EVENT\",$eventJson]")
            }

            override fun onMessage(webSocket: WebSocket, text: String) {
                val (accepted, message) = VaultHandoffDecision.okAnswer(text, eventId) ?: return
                answer.complete(accepted || message.startsWith("duplicate:"))
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                answer.complete(false)
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                answer.complete(false)
            }
        }
        val socket = client.newWebSocket(request, listener)
        val stored = withTimeoutOrNull(timeoutMs) { answer.await() } ?: false
        socket.close(1000, null)
        if (!stored) Log.w(TAG, "local copy of vault-sent ${eventId.take(8)} not confirmed; the relay syncs it from the vault")
        return stored
    }
}
