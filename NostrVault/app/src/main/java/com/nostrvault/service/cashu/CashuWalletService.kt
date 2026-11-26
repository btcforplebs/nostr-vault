package com.nostrvault.service.cashu

import android.content.Context
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.decodeFromJsonElement
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import java.io.File
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Where each account's built-in Cashu wallet lives (design
 * RESEARCH/NV_CASHU_WALLET_DESIGN_2026_11_25.md §2, step D1; Apple twin
 * `Services/Cashu/CashuWalletService.swift`): one engine state file per
 * account, `filesDir/cashu/<hex>/wallet.json`. App-private and not in Auto
 * Backup (backup_rules.xml is an allow-list). Publishing the NIP-60 events
 * from it is step D2.
 */
@Singleton
class CashuWallets(private val base: File, private val engine: CashuEngine = CashuNative) {
    @Inject constructor(@ApplicationContext context: Context) : this(File(context.filesDir, "cashu"))

    private val open = HashMap<String, CashuWalletService>()

    fun fileFor(accountHex: String): File = File(File(base, accountHex.lowercase()), "wallet.json")

    /** True once this account has a wallet on this device. Never creates one. */
    fun exists(accountHex: String): Boolean = isAccountHex(accountHex) && fileFor(accountHex).exists()

    /**
     * The account's wallet, opened once per process. [create] false (paying)
     * refuses an account with no wallet file yet, so a payment never makes an
     * empty wallet; the screens that set one up (D3) pass true.
     */
    @Synchronized
    fun wallet(accountHex: String, create: Boolean = false): CashuWalletService {
        val hex = accountHex.lowercase()
        if (!isAccountHex(hex)) throw CashuException.noWallet()
        val file = fileFor(hex)
        open[file.path]?.let { return it }
        if (!create && !file.exists()) throw CashuException.noWallet()
        file.parentFile?.mkdirs()
        val reply = CashuReply.parse(engine.open(file.absolutePath))
        val handle = (reply as? JsonObject)?.get("handle")?.jsonPrimitive?.intOrNull
            ?.takeIf { it > 0 } ?: throw CashuException("error", "The wallet engine gave no handle.")
        return CashuWalletService(hex, engine, handle).also { open[file.path] = it }
    }

    companion object {
        fun isAccountHex(s: String) = s.length == 64 && s.all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' }
    }
}

/** One account's open wallet: a typed face on the engine's JSON calls. */
class CashuWalletService internal constructor(
    val accountHex: String,
    private val engine: CashuEngine,
    private val handle: Int,
) {
    /** One engine call, off the main thread (mint calls block up to 2 min). */
    suspend fun call(method: String, args: JsonObject = JsonObject(emptyMap())): JsonElement =
        withContext(Dispatchers.IO) { CashuReply.parse(engine.call(handle, method, args.toString())) }

    private suspend inline fun <reified T> typed(method: String, args: JsonObject = JsonObject(emptyMap())): T =
        CashuReply.json.decodeFromJsonElement(call(method, args))

    suspend fun balance(): CashuBalance = typed("balance")
    suspend fun mints(): List<String> = typed<List<String>?>("mints").orEmpty()
    suspend fun addMint(url: String): CashuMintSummary = typed("add_mint", buildJsonObject { put("mint", url) })

    /** A Lightning invoice that mints [amount] sats at [mint] once paid. */
    suspend fun requestMint(mint: String, amount: Long): CashuMintQuote =
        typed("request_mint", buildJsonObject { put("mint", mint); put("amount", amount) })

    /** Mints a paid quote's proofs; the amount minted. `not_paid` until it is. */
    suspend fun claimMint(quote: String): Long = typed("claim_mint", buildJsonObject { put("quote", quote) })

    suspend fun quoteMelt(mint: String, bolt11: String): CashuMeltQuote =
        typed("quote_melt", buildJsonObject { put("mint", mint); put("bolt11", bolt11) })

    suspend fun melt(quote: CashuMeltQuote): CashuMeltResult =
        typed("melt", buildJsonObject { put("melt", CashuReply.json.encodeToJsonElement(CashuMeltQuote.serializer(), quote)) })

    /** Every op the engine journaled and hasn't closed, stuck ones included. */
    suspend fun pending(): List<CashuPendingOp> = typed<List<CashuPendingOp>?>("pending").orEmpty()

    /**
     * Ops whose answer from the mint is still unknown (not stuck): the same
     * rule the engine's mintBusy uses. Only these may still move money.
     */
    suspend fun unsettledCount(): Int = pending().count { it.isUnsettled }

    /** Finishes spends the engine journaled but never heard back about. */
    suspend fun recover() { call("recover") }

    /**
     * Pays [bolt11] by melting at one mint (NUT-05). Mints are tried from the
     * biggest balance down, and the next one only when this one refused before
     * any money moved. `pending` (the mint may still pay) stops at once.
     */
    suspend fun payInvoice(bolt11: String): CashuMeltResult {
        // An earlier payment the mint hasn't settled may be this same invoice
        // (a retry after "may still pay"). Starting another one, at any mint,
        // could pay it twice, so nothing new goes out until recover clears it.
        // A stuck op doesn't count: its outcome is known (only the change is
        // missing), and counting it would block this wallet for good.
        if (pending().isNotEmpty()) {
            runCatching { recover() }
            if (unsettledCount() > 0) throw CashuException("busy", "an earlier payment is still unsettled")
        }
        val order = payOrder(balance())
        if (order.isEmpty()) throw CashuException.notEnough()
        var first: Exception? = null
        for ((mint, have) in order) {
            val quote = try {
                quoteMelt(mint, bolt11)
            } catch (e: CashuException) {
                first = first ?: e
                continue
            }
            if (quote.amount + quote.feeReserve > have) {
                first = first ?: CashuException.notEnough()
                continue
            }
            try {
                return melt(quote)
            } catch (e: CashuException) {
                if (!triesNextMint(e.code)) throw e
                first = first ?: e
            }
        }
        throw first ?: CashuException.notEnough()
    }

    companion object {
        /** Mints with sats to spend, biggest first (ties by URL, so the order is fixed). */
        fun payOrder(balance: CashuBalance): List<Pair<String, Long>> =
            balance.perMint.orEmpty().filter { it.value > 0 }.entries
                .sortedWith(compareByDescending<Map.Entry<String, Long>> { it.value }.thenBy { it.key })
                .map { it.key to it.value }

        /**
         * Refusals that happen before the engine journals the spend, so no
         * money moved. Anything else stops the payment: pending, an error after
         * the mint call, and busy (that mint's unfinished op may be this invoice).
         */
        fun triesNextMint(code: String): Boolean = code in setOf("not_enough", "no_change", "unknown_mint")
    }
}

/** The engine's reply envelope: `{"ok":true,"result":…}` or `{"ok":false,"error":…,"code":…}`. */
object CashuReply {
    val json = Json { ignoreUnknownKeys = true; explicitNulls = false }

    /** The `result` of an ok reply (JsonNull when it has none), or the error thrown. */
    fun parse(bytes: ByteArray): JsonElement {
        val obj = try {
            json.parseToJsonElement(bytes.decodeToString()).jsonObject
        } catch (e: Exception) {
            throw CashuException("error", "The wallet engine gave an unreadable answer.")
        }
        if (obj["ok"]?.jsonPrimitive?.booleanOrNull != true) {
            throw CashuException(
                obj["code"]?.jsonPrimitive?.contentOrNull ?: "error",
                obj["error"]?.jsonPrimitive?.contentOrNull ?: "The wallet engine refused.",
            )
        }
        return obj["result"] ?: JsonNull
    }
}

// Engine shapes (haven-go/wallet: Balance, MintSummary, MintQuote, MeltQuote, MeltResult, Op).

@Serializable
data class CashuBalance(
    val total: Long = 0,
    @SerialName("per_mint") val perMint: Map<String, Long>? = null,
    val reserved: Long = 0,
    @SerialName("in_flight") val inFlight: Long = 0,
    val warn: Boolean = false,
)

@Serializable
data class CashuMintSummary(
    val url: String,
    val name: String = "",
    @SerialName("nut07") val checkstate: Boolean = false,
    @SerialName("nut09") val restore: Boolean = false,
    @SerialName("nut11") val p2pk: Boolean = false,
    @SerialName("nut12") val dleq: Boolean = false,
    val sat: Boolean = false,
)

@Serializable
data class CashuMintQuote(val id: String, val mint: String, val amount: Long, val request: String, val expiry: Long? = null)

/** Handed back to melt as it is: the engine re-reads it and refuses a changed quote. */
@Serializable
data class CashuMeltQuote(
    val id: String,
    val mint: String,
    val amount: Long,
    @SerialName("fee_reserve") val feeReserve: Long,
    val expiry: Long? = null,
)

@Serializable
data class CashuMeltResult(val preimage: String? = null, val spent: Long = 0, val change: Long = 0)

@Serializable
data class CashuPendingOp(val id: String, val kind: String? = null, val mint: String? = null, val stuck: String? = null) {
    val isUnsettled: Boolean get() = stuck.isNullOrEmpty()
}
