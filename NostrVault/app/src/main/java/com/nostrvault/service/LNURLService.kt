package com.nostrvault.service

import android.util.Log
import com.nostrvault.util.LightningPayTarget
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.decodeFromJsonElement
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.IOException
import java.net.URLEncoder
import java.util.concurrent.TimeUnit

/**
 * LNURL protocol service.
 * Resolves Lightning Addresses (LUD-16) and raw LNURLs (LUD-06)
 * to fetch payment invoices with optional Nostr zap support.
 *
 * Port of LNURLService.swift.
 */
object LNURLService {

    private const val TAG = "LNURLService"

    private val json = Json { ignoreUnknownKeys = true }
    private val client = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(10, TimeUnit.SECONDS)
        .build()

    // ══════════════════════════════════════════════════════════════════
    // Address resolution
    // ══════════════════════════════════════════════════════════════════

    /**
     * Resolve a Lightning Address (user@domain.com) to LNURL pay response.
     * LUD-16: https://domain.com/.well-known/lnurlp/user
     */
    suspend fun resolveAddress(lud16: String): LNURLPayResponse = withContext(Dispatchers.IO) {
        val parts = lud16.lowercase().split("@")
        if (parts.size != 2) throw LNURLError.InvalidAddress

        val username = URLEncoder.encode(parts[0], "UTF-8")
        val domain = parts[1]
        val url = "https://$domain/.well-known/lnurlp/$username"

        fetchPayResponse(url)
    }

    /**
     * Resolve a raw LNURL (bech32-encoded) to LNURL pay response.
     * LUD-06: Decode bech32 to get HTTPS URL.
     */
    suspend fun resolveRawLNURL(lnurl: String): LNURLPayResponse = withContext(Dispatchers.IO) {
        val cleaned = lnurl.removePrefix("lnurl:").removePrefix("LNURL:")
        val decoded = Bech32.decodeLNURL(cleaned)
            ?: throw LNURLError.InvalidAddress

        fetchPayResponse(decoded)
    }

    // ══════════════════════════════════════════════════════════════════
    // Invoice fetching
    // ══════════════════════════════════════════════════════════════════

    /**
     * Fetch a Lightning invoice from a LNURL callback.
     * @param callback The callback URL from LNURLPayResponse
     * @param amountMsat Amount in millisatoshis
     * @param zapRequest Optional NIP-57 zap request event JSON
     * @param comment Optional LUD-12 comment, only when the service allows one
     * @return BOLT11 invoice string
     */
    suspend fun fetchInvoice(
        callback: String,
        amountMsat: Long,
        zapRequest: String? = null,
        comment: String? = null,
    ): String = withContext(Dispatchers.IO) {
        val urlBuilder = StringBuilder(callback)
        urlBuilder.append(if (callback.contains("?")) "&" else "?")
        urlBuilder.append("amount=$amountMsat")

        if (!comment.isNullOrEmpty()) {
            urlBuilder.append("&comment=${URLEncoder.encode(comment, "UTF-8")}")
        }

        zapRequest?.let { zap ->
            val encoded = URLEncoder.encode(zap, "UTF-8")
            urlBuilder.append("&nostr=$encoded")
        }

        val request = Request.Builder()
            .url(urlBuilder.toString())
            .get()
            .build()

        val response = client.newCall(request).execute()
        val body = response.body?.string()
        // A service that refuses says why (`{"status":"ERROR","reason":…}`),
        // often with a 200; that reason is the only useful explanation.
        serviceError(body)?.let { throw it }
        if (!response.isSuccessful) {
            throw LNURLError.NetworkError("HTTP ${response.code}")
        }

        body ?: throw LNURLError.InvalidResponse
        val parsed = json.decodeFromString<LNURLCallbackResponse>(body)
        parsed.pr ?: throw LNURLError.InvalidInvoice
    }

    // ══════════════════════════════════════════════════════════════════
    // Wallet send box: any LNURL, pay or withdraw
    // ══════════════════════════════════════════════════════════════════

    /**
     * Resolves whatever the user pasted — address, bech32 LNURL or LUD-17
     * link — to the pay or withdraw request behind it.
     */
    suspend fun resolve(target: LightningPayTarget): LNURLResolved = withContext(Dispatchers.IO) {
        val url = when (target) {
            is LightningPayTarget.Invoice -> throw LNURLError.InvalidAddress
            is LightningPayTarget.Address -> {
                val parts = target.address.split("@")
                if (parts.size != 2) throw LNURLError.InvalidAddress
                "https://${parts[1]}/.well-known/lnurlp/${parts[0]}"
            }
            is LightningPayTarget.Lnurl -> Bech32.decodeLNURL(target.bech32) ?: throw LNURLError.InvalidAddress
            is LightningPayTarget.LnurlUrl -> target.url
        }
        val httpUrl = url.toHttpUrlOrNull() ?: throw LNURLError.InvalidAddress
        Log.d(TAG, "Resolving $httpUrl")

        val request = Request.Builder().url(httpUrl).get().build()
        val (code, body) = try {
            client.newCall(request).execute().use { it.code to it.body?.string() }
        } catch (e: IOException) {
            throw LNURLError.NetworkError(e.message ?: "unreachable")
        }
        serviceError(body)?.let { throw it }
        val obj = body?.let { runCatching { json.parseToJsonElement(it) as? JsonObject }.getOrNull() }
        if (code != 200 || obj == null) throw LNURLError.InvalidResponse

        val host = httpUrl.host
        when ((obj["tag"] as? JsonPrimitive)?.content) {
            "payRequest" -> LNURLResolved.Pay(
                runCatching { json.decodeFromJsonElement<LNURLPayResponse>(obj) }
                    .getOrElse { throw LNURLError.InvalidResponse },
                host,
            )
            "withdrawRequest" -> LNURLResolved.Withdraw(
                runCatching { json.decodeFromJsonElement<LNURLWithdrawResponse>(obj) }
                    .getOrElse { throw LNURLError.InvalidResponse },
                host,
            )
            else -> throw LNURLError.ServiceError(
                "This link isn't a payment or a withdrawal, so the wallet can't use it."
            )
        }
    }

    /** LUD-03 step two: hand the service an invoice of ours to pay. */
    suspend fun submitWithdraw(withdraw: LNURLWithdrawResponse, invoice: String) = withContext(Dispatchers.IO) {
        val url = withdraw.callback.toHttpUrlOrNull()?.newBuilder()
            ?.addQueryParameter("k1", withdraw.k1)
            ?.addQueryParameter("pr", invoice)
            ?.build()
            ?: throw LNURLError.InvalidResponse
        val request = Request.Builder().url(url).get().build()
        val body = try {
            client.newBuilder().readTimeout(15, TimeUnit.SECONDS).build()
                .newCall(request).execute().use { it.body?.string() }
        } catch (e: IOException) {
            throw LNURLError.NetworkError(e.message ?: "unreachable")
        }
        val obj = body?.let { runCatching { json.parseToJsonElement(it) as? JsonObject }.getOrNull() }
        val status = (obj?.get("status") as? JsonPrimitive)?.content
        if (!status.equals("OK", ignoreCase = true)) {
            val reason = (obj?.get("reason") as? JsonPrimitive)?.content
            throw LNURLError.ServiceError(reason ?: "The service did not accept the withdrawal.")
        }
    }

    /** The service's own `{"status":"ERROR","reason":…}`, if that is what came back. */
    private fun serviceError(body: String?): LNURLError.ServiceError? {
        val obj = body?.let { runCatching { json.parseToJsonElement(it) as? JsonObject }.getOrNull() } ?: return null
        val status = (obj["status"] as? JsonPrimitive)?.content ?: return null
        if (!status.equals("ERROR", ignoreCase = true)) return null
        val reason = (obj["reason"] as? JsonPrimitive)?.content
        return LNURLError.ServiceError(reason ?: "The service refused the request.")
    }

    // ══════════════════════════════════════════════════════════════════
    // Internal
    // ══════════════════════════════════════════════════════════════════

    private fun fetchPayResponse(url: String): LNURLPayResponse {
        Log.d(TAG, "Fetching LNURL pay response from $url")

        val request = Request.Builder()
            .url(url)
            .get()
            .build()

        val response = client.newCall(request).execute()
        if (!response.isSuccessful) {
            throw LNURLError.NetworkError("HTTP ${response.code}")
        }

        val body = response.body?.string() ?: throw LNURLError.InvalidResponse
        return json.decodeFromString<LNURLPayResponse>(body)
    }
}

// ── Data models ───────────────────────────────────────────────────

@Serializable
data class LNURLPayResponse(
    val callback: String,
    val maxSendable: Long,
    val minSendable: Long,
    val metadata: String,
    val tag: String,
    val nostrPubkey: String? = null,
    val allowsNostr: Boolean? = null,
    /** LUD-12: longest comment the service accepts; null or 0 means none. */
    val commentAllowed: Int? = null,
)

/** LUD-03: a service that pays *you*. */
@Serializable
data class LNURLWithdrawResponse(
    val callback: String,
    val k1: String,
    val minWithdrawable: Long,
    val maxWithdrawable: Long,
    val defaultDescription: String? = null,
)

sealed interface LNURLResolved {
    val host: String
    data class Pay(val pay: LNURLPayResponse, override val host: String) : LNURLResolved
    data class Withdraw(val withdraw: LNURLWithdrawResponse, override val host: String) : LNURLResolved
}

@Serializable
data class LNURLCallbackResponse(
    val pr: String? = null,
    val routes: List<Map<String, String>>? = null,
)

sealed class LNURLError : Exception() {
    data object InvalidAddress : LNURLError() {
        override val message: String get() = "Invalid Lightning Address"
    }
    data class NetworkError(override val message: String) : LNURLError()
    data object InvalidResponse : LNURLError() {
        override val message: String get() = "Invalid response from LNURL service"
    }
    data object InvalidInvoice : LNURLError() {
        override val message: String get() = "Failed to retrieve a valid invoice"
    }

    /** The service's own error, shown as-is: usually the only useful explanation. */
    data class ServiceError(val reason: String) : LNURLError() {
        override val message: String get() = reason
    }
}

/**
 * Minimal Bech32 LNURL decoder.
 */
object Bech32 {
    private const val CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"

    fun decodeLNURL(lnurl: String): String? {
        return try {
            val lower = lnurl.lowercase()
            val pos = lower.lastIndexOf("1")
            if (pos < 1) return null

            val data = lower.substring(pos + 1).dropLast(6) // Remove checksum
            val decoded = data.map { CHARSET.indexOf(it) }.filter { it >= 0 }

            // Convert 5-bit groups to 8-bit bytes
            val bytes = convertBits(decoded, 5, 8, false) ?: return null
            String(bytes.toByteArray(), Charsets.UTF_8)
        } catch (e: Exception) {
            Log.w("Bech32", "LNURL decode failed: ${e.message}")
            null
        }
    }

    private fun convertBits(data: List<Int>, fromBits: Int, toBits: Int, pad: Boolean): List<Byte>? {
        var acc = 0
        var bits = 0
        val result = mutableListOf<Byte>()
        val maxv = (1 shl toBits) - 1

        for (value in data) {
            if (value < 0 || value >= (1 shl fromBits)) return null
            acc = (acc shl fromBits) or value
            bits += fromBits
            while (bits >= toBits) {
                bits -= toBits
                result.add(((acc shr bits) and maxv).toByte())
            }
        }

        if (pad && bits > 0) {
            result.add(((acc shl (toBits - bits)) and maxv).toByte())
        } else if (bits >= fromBits || ((acc shl (toBits - bits)) and maxv) != 0) {
            return null
        }

        return result
    }
}
