package com.nostrvault.service

import android.util.Log
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.remote.WebSocketClient
import com.nostrvault.relay.HavenBridge
import com.nostrvault.util.WalletTransaction
import kotlinx.coroutines.*
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.*
import java.net.URL
import java.net.URLDecoder
import javax.inject.Inject
import javax.inject.Singleton
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/**
 * NIP-47 Nostr Wallet Connect service.
 * Handles remote wallet interactions (pay invoice, get balance, make invoice)
 * via encrypted Nostr events over relays.
 *
 * Port of NWCService.swift.
 */
@Singleton
class NWCService @Inject constructor(
    private val configStore: ConfigStore,
) {
    companion object {
        private const val TAG = "NWCService"
        private const val REQUEST_KIND = 23194
        private const val RESPONSE_KIND = 23195
        private const val TIMEOUT_MS = 15_000L
    }

    private val json = Json { ignoreUnknownKeys = true }

    // ══════════════════════════════════════════════════════════════════
    // URI Parsing
    // ══════════════════════════════════════════════════════════════════

    data class NWCConnectionData(
        val relayURL: String,
        val secret: String,
        val pubkey: String,
    )

    fun parseURI(uri: String): NWCConnectionData? {
        val cleaned = uri
            .replace("nostr+walletconnect://", "")
            .replace("nostr+walletconnect:", "")

        val parts = cleaned.split("?", limit = 2)
        if (parts.size < 2) return null

        val pubkey = parts[0]
        val params = parts[1].split("&").associate { param ->
            val kv = param.split("=", limit = 2)
            if (kv.size == 2) {
                URLDecoder.decode(kv[0], "UTF-8") to URLDecoder.decode(kv[1], "UTF-8")
            } else {
                kv[0] to ""
            }
        }

        val relay = params["relay"] ?: return null
        val secret = params["secret"] ?: return null

        return NWCConnectionData(relayURL = relay, secret = secret, pubkey = pubkey)
    }

    // ══════════════════════════════════════════════════════════════════
    // Wallet operations
    // ══════════════════════════════════════════════════════════════════

    /**
     * Pay a Lightning invoice via NWC.
     * @return Preimage or "Success"
     */
    suspend fun payInvoice(bolt11: String): String = withContext(Dispatchers.IO) {
        val request = NWCRequest(
            method = "pay_invoice",
            params = NWCParams(invoice = bolt11),
        )
        val response = sendNWCRequest(request)

        val preimage = response.result?.get("preimage")
        if (preimage != null) {
            return@withContext extractStringValue(preimage)
        }
        response.error?.let { throw NWCException(it.message) }
        "Success"
    }

    /**
     * Get wallet balance in millisatoshis.
     */
    suspend fun getBalance(): Long = withContext(Dispatchers.IO) {
        val request = NWCRequest(method = "get_balance")
        val response = sendNWCRequest(request)

        val balance = response.result?.get("balance")
        if (balance != null) {
            return@withContext extractLongValue(balance)
        }
        response.error?.let { throw NWCException(it.message) }
        0L
    }

    /**
     * Create a Lightning invoice for receiving payments.
     * @return BOLT11 invoice string
     */
    suspend fun makeInvoice(
        amountMsats: Long,
        description: String? = null,
        expiry: Int? = null,
    ): String = withContext(Dispatchers.IO) {
        val request = NWCRequest(
            method = "make_invoice",
            params = NWCParams(
                amount = amountMsats,
                description = description,
                expiry = expiry,
            ),
        )
        val response = sendNWCRequest(request)

        val invoice = response.result?.get("invoice")
        if (invoice != null) {
            return@withContext extractStringValue(invoice)
        }
        response.error?.let { throw NWCException(it.message) }
        throw NWCException("No invoice in response")
    }

    /**
     * One page of the wallet's payment history, newest first (NIP-47
     * `list_transactions`). Throws [NWCWalletException] with
     * [NWCWalletException.isUnsupported] when the wallet or this connection
     * does not share history.
     */
    suspend fun listTransactions(limit: Int = 20, offset: Int = 0): List<WalletTransaction> =
        withContext(Dispatchers.IO) {
            val payload = buildJsonObject {
                put("method", "list_transactions")
                putJsonObject("params") {
                    put("limit", limit)
                    put("offset", offset)
                    put("unpaid", false)
                }
            }
            val response = sendNWCRequest(payload.toString())
            response.error?.let { throw NWCWalletException(it.code, it.message.ifBlank { it.code }) }
            val raw = response.result?.get("transactions") as? JsonArray ?: JsonArray(emptyList())
            WalletTransaction.merge(
                emptyList(),
                raw.mapNotNull { (it as? JsonObject)?.let(WalletTransaction::fromNip47) },
            )
        }

    // ══════════════════════════════════════════════════════════════════
    // Core NWC request/response
    // ══════════════════════════════════════════════════════════════════

    private suspend fun sendNWCRequest(request: NWCRequest): NWCResponse =
        sendNWCRequest(json.encodeToString(NWCRequest.serializer(), request))

    /** Sends one already-encoded NIP-47 request payload and awaits its reply. */
    private suspend fun sendNWCRequest(payloadJson: String): NWCResponse {
        val connectionUri = configStore.config.value.nwcURI
            ?: throw NWCException("No NWC connection configured")
        val connection = parseURI(connectionUri)
            ?: throw NWCException("Invalid NWC URI")

        // Derive pubkey from secret
        val localPubkey = HavenBridge.getPublicKey(connection.secret)
            ?: throw NWCException("Failed to derive public key")

        // Encrypt request payload
        val encrypted = NIP04Service.encrypt(payloadJson, connection.pubkey, connection.secret)
            ?: throw NWCException("Encryption failed")

        // Build kind 23194 event
        val tags = listOf(listOf("p", connection.pubkey))
        val eventJson = EventPublisher.buildUnsignedEvent(
            kind = REQUEST_KIND,
            content = encrypted,
            tags = tags,
            pubkey = localPubkey,
        )
        val signedJson = EventPublisher.signWithGoBackend(eventJson, connection.secret)
            ?: throw NWCException("Signing failed")

        val signedEvent = json.parseToJsonElement(signedJson).jsonObject
        val eventId = signedEvent["id"]?.jsonPrimitive?.contentOrNull ?: throw NWCException("No event ID")

        // Send via WebSocket and await response
        return suspendCancellableCoroutine { cont ->
            var isCompleted = false

            val nwcScope = CoroutineScope(Dispatchers.IO + SupervisorJob())
            val client = WebSocketClient(url = connection.relayURL, scope = nwcScope)
            val subId = "nwc-${eventId.take(8)}"
            nwcScope.launch {
                client.messages.collect { msg ->
                    if (isCompleted) return@collect
                    try {
                        val parsed = json.parseToJsonElement(msg).jsonArray
                        val type = parsed[0].jsonPrimitive.contentOrNull

                        when (type) {
                            "EVENT" -> {
                                if (parsed.size < 3) return@collect
                                val respEvent = parsed[2].jsonObject
                                val respKind = respEvent["kind"]?.jsonPrimitive?.intOrNull
                                if (respKind != RESPONSE_KIND) return@collect

                                val respContent = respEvent["content"]?.jsonPrimitive?.contentOrNull
                                    ?: return@collect

                                val decrypted = NIP04Service.decrypt(
                                    respContent, connection.pubkey, connection.secret
                                ) ?: return@collect

                                val response = json.decodeFromString<NWCResponse>(decrypted)
                                if (!isCompleted) {
                                    isCompleted = true
                                    client.disconnect()
                                    cont.resume(response)
                                }
                            }
                        }
                    } catch (_: Exception) {}
                }
            }

            client.connect()

            // Subscribe to responses
            val filter = """{"kinds":[$RESPONSE_KIND],"authors":["${connection.pubkey}"],"#e":["$eventId"],"limit":1}"""
            client.send("[\"REQ\",\"$subId\",$filter]")

            // Send request
            client.send("[\"EVENT\",$signedJson]")

            // Timeout
            nwcScope.launch {
                delay(TIMEOUT_MS)
                if (!isCompleted) {
                    isCompleted = true
                    client.disconnect()
                    cont.resumeWithException(NWCTimeoutException())
                }
            }

            cont.invokeOnCancellation {
                isCompleted = true
                client.disconnect()
                nwcScope.cancel()
            }
        }
    }

    // ══════════════════════════════════════════════════════════════════
    // Helpers
    // ══════════════════════════════════════════════════════════════════

    private fun extractStringValue(element: JsonElement): String {
        return when (element) {
            is JsonPrimitive -> element.contentOrNull ?: ""
            else -> element.toString()
        }
    }

    private fun extractLongValue(element: JsonElement): Long {
        return when (element) {
            is JsonPrimitive -> {
                element.longOrNull ?: element.doubleOrNull?.toLong()
                ?: element.contentOrNull?.toLongOrNull() ?: 0L
            }
            else -> 0L
        }
    }
}

// ── Request/Response types ────────────────────────────────────────

@Serializable
data class NWCRequest(
    val method: String,
    val params: NWCParams? = null,
)

@Serializable
data class NWCParams(
    val invoice: String? = null,
    val amount: Long? = null,
    val description: String? = null,
    val expiry: Int? = null,
)

@Serializable
data class NWCResponse(
    val result_type: String? = null,
    val result: Map<String, JsonElement>? = null,
    val error: NIP47Error? = null,
)

@Serializable
data class NIP47Error(
    val code: String = "OTHER",
    val message: String = "",
)

open class NWCException(message: String) : Exception(message)

/**
 * No reply within the timeout. The request was already published, so the
 * wallet may have acted on it — for pay_invoice, the payment may still settle.
 */
class NWCTimeoutException : NWCException("Request timed out")

/**
 * A NIP-47 error the wallet answered with, keeping its code so callers can
 * tell "this wallet does not do that" from a real failure.
 */
class NWCWalletException(val code: String, message: String) : NWCException(message) {
    /** The wallet (or this connection's permissions) does not offer the method. */
    val isUnsupported: Boolean get() = code in setOf("NOT_IMPLEMENTED", "RESTRICTED", "UNAUTHORIZED")
}
