package com.nostrvault.fips

import com.nostrvault.data.remote.WebSocketClient
import com.nostrvault.relay.HavenBridge
import com.nostrvault.service.EventPublisher
import com.nostrvault.service.NIP44Service
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.intOrNull
import java.security.SecureRandom

/**
 * Sends and receives the pairing hello and ack (kind 21195, docs/MESH_PAIRING_CONTRACT.md §3) on the finder relays.
 * Twin of iOS `MeshPairingHello.swift`.
 *
 * With [MeshKeySigner] (the copy start and Blossom over the mesh) the only readers of the mesh nsec outside the engine
 * (Tron T2): read per call, never logged, never kept, never handed to the UI, and it signs kind 21195 only, through no
 * general signing function. Everything it hands
 * back is the sender's mesh pubkey and the decrypted plaintext; the session ([MeshPairingSession],
 * [MeshPairingJoiner]) judges that.
 */
class MeshPairingHello(
    relays: List<String>,
    private val scope: CoroutineScope,
) {
    private val clients = relays.map { it.trim() }.filter { it.isNotEmpty() }.distinct()
        .map { WebSocketClient(url = it, scope = scope) }
    private val subId = SUB_PREFIX + ByteArray(6).also { SecureRandom().nextBytes(it) }.joinToString("") { "%02x".format(it) }
    private val jobs = mutableListOf<Job>()
    private val seen = java.util.Collections.synchronizedSet(mutableSetOf<String>())

    /** The last event sent, signed: resent byte for byte, since a changed hello aborts the other side (Tron 3). */
    @Volatile private var lastSent: String? = null
    @Volatile private var opened = false

    /** This device's mesh pubkey (hex), or null while it has no mesh key. */
    fun ownHex(): String? = withKey { _, pub -> pub }

    /**
     * Listen for kind 21195 addressed to this device's mesh key. [onMessage] gets the sender's mesh pubkey (hex,
     * signature checked) and the decrypted content, on the main thread. -> false when there is no mesh key.
     */
    fun open(onMessage: (sender: String, plaintext: String) -> Unit): Boolean {
        if (opened) return true
        val own = ownHex() ?: return false
        opened = true
        val req = "[\"REQ\",\"$subId\",{\"kinds\":[${MeshPairing.HELLO_KIND}],\"#p\":[\"$own\"],\"since\":${now() - SINCE_SLACK_S}}]"
        for (client in clients) {
            // Collected before the REQ goes out: messages has no replay.
            jobs += scope.launch(Dispatchers.Default, start = CoroutineStart.UNDISPATCHED) {
                client.messages.collect { message ->
                    if (!message.contains(subId)) return@collect
                    val (sender, ciphertext, id) = eventFor(message, subId, own, HavenBridge::verifyEvent) ?: return@collect
                    if (!seen.add(id)) return@collect
                    val plaintext = withKey { sec, _ -> NIP44Service.decrypt(ciphertext, sender, sec) } ?: return@collect
                    withContext(Dispatchers.Main) { onMessage(sender, plaintext) }
                }
            }
            // On first open and every reconnect: the REQ, and whatever this side last sent.
            jobs += scope.launch(Dispatchers.Default) {
                client.connectionState.collect { state ->
                    if (state != WebSocketClient.ConnectionState.CONNECTED) return@collect
                    client.send(req)
                    lastSent?.let { client.send(eventFrame(it)) }
                }
            }
            client.connect()
        }
        return true
    }

    /**
     * Sign [plaintext] NIP-44 encrypted to [toHex] as a kind 21195 from this device's mesh key, and send it to every
     * finder relay (and again on each reconnect). -> false when there is no key or it could not be signed.
     */
    fun send(toHex: String, plaintext: String): Boolean {
        val signed = withKey { sec, pub ->
            val content = NIP44Service.encrypt(plaintext, toHex, sec) ?: return@withKey null
            val unsigned = EventPublisher.buildUnsignedEvent(pub, MeshPairing.HELLO_KIND, content, listOf(listOf("p", toHex)))
            EventPublisher.signWithGoBackend(unsigned, sec)
        } ?: return false
        lastSent = signed
        resend()
        return true
    }

    /** The last event again, the same bytes, to every relay that is connected. */
    fun resend() {
        val event = lastSent ?: return
        clients.forEach { if (it.connectionState.value == WebSocketClient.ConnectionState.CONNECTED) it.send(eventFrame(event)) }
    }

    fun close() {
        jobs.forEach { it.cancel() }
        jobs.clear()
        clients.forEach { client ->
            if (client.connectionState.value == WebSocketClient.ConnectionState.CONNECTED) client.send("[\"CLOSE\",\"$subId\"]")
            client.disconnect()
        }
        lastSent = null
        opened = false
    }

    /** The mesh key for one call: read, used, dropped. Never logged (Tron T2). */
    private fun <T> withKey(block: (secretHex: String, pubkeyHex: String) -> T?): T? = MeshKeySigner.withKey(block)

    companion object {
        const val SUB_PREFIX = "nvpair-"
        /** The REQ reaches back this far, so a hello sent while this side was dialing is still read. */
        const val SINCE_SLACK_S = 30L
        /** How often an unanswered hello or ack is sent again (the same bytes). */
        const val RESEND_EVERY_MS = 10_000L

        private val json = Json { ignoreUnknownKeys = true }

        private fun now() = System.currentTimeMillis() / 1000

        private fun eventFrame(event: String) = "[\"EVENT\",$event]"

        /**
         * A relay message → (sender hex, NIP-44 content, event id) when it is an `EVENT` under [subId] carrying a kind
         * 21195 addressed to [ownHex], from someone else, whose id and signature [verify] accepts. Null otherwise.
         */
        fun eventFor(message: String, subId: String, ownHex: String, verify: (String) -> Boolean): Triple<String, String, String>? {
            val array = runCatching { json.parseToJsonElement(message) as? JsonArray }.getOrNull() ?: return null
            if (array.size < 3) return null
            if ((array[0] as? JsonPrimitive)?.content != "EVENT" || (array[1] as? JsonPrimitive)?.content != subId) return null
            val event = array[2] as? JsonObject ?: return null
            fun str(key: String) = (event[key] as? JsonPrimitive)?.takeIf { it.isString }?.content
            if ((event["kind"] as? JsonPrimitive)?.intOrNull != MeshPairing.HELLO_KIND) return null
            val sender = str("pubkey")?.lowercase()?.takeIf { it.length == 64 } ?: return null
            if (sender == ownHex) return null
            val content = str("content") ?: return null
            val id = str("id") ?: return null
            val tags = event["tags"] as? JsonArray ?: return null
            val toUs = tags.any { tag ->
                val t = tag as? JsonArray ?: return@any false
                t.size >= 2 && (t[0] as? JsonPrimitive)?.content == "p" && (t[1] as? JsonPrimitive)?.content?.lowercase() == ownHex
            }
            if (!toUs) return null
            if (!verify(event.toString())) return null
            return Triple(sender, content, id)
        }
    }
}
