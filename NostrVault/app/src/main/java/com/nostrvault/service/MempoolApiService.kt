package com.nostrvault.service

import android.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.OkHttpClient
import okhttp3.Request
import java.util.concurrent.TimeUnit
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Minimal mempool.space API client — port of iOS MempoolAPIService.
 * Used by the Bitcoin sweep flow to show the on-chain balance of the
 * Nostr-derived taproot address before sweeping.
 */
@Singleton
class MempoolApiService @Inject constructor() {

    companion object {
        private const val TAG = "MempoolApiService"
        private const val BASE_URL = "https://mempool.space/api"
    }

    private val json = Json { ignoreUnknownKeys = true }
    private val client = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(15, TimeUnit.SECONDS)
        .build()

    /**
     * The spendable balance (sats) of an address and how many unspent outputs
     * make it up, both funded − spent over confirmed and unconfirmed txos. The
     * sweep spends every one of them, so its fee grows with [utxoCount].
     */
    data class AddressFunds(val balanceSats: Long, val utxoCount: Int)

    /**
     * Returns [AddressFunds] for [address], summing confirmed (chain_stats)
     * and unconfirmed (mempool_stats) txos. Returns null on network/parse failure.
     */
    suspend fun fetchAddressFunds(address: String): AddressFunds? = withContext(Dispatchers.IO) {
        try {
            val request = Request.Builder().url("$BASE_URL/address/$address").build()
            client.newCall(request).execute().use { response ->
                if (!response.isSuccessful) return@withContext null
                val body = response.body?.string() ?: return@withContext null
                val root = json.parseToJsonElement(body).jsonObject

                // Long: a sum over about 21.47 BTC does not fit an Int.
                fun stat(group: String, field: String): Long =
                    root[group]?.jsonObject?.get(field)?.jsonPrimitive?.longOrNull ?: 0L
                fun unspent(prefix: String): Long =
                    stat("chain_stats", "funded_$prefix") + stat("mempool_stats", "funded_$prefix") -
                        stat("chain_stats", "spent_$prefix") - stat("mempool_stats", "spent_$prefix")

                AddressFunds(
                    balanceSats = unspent("txo_sum").coerceAtLeast(0L),
                    utxoCount = unspent("txo_count").coerceIn(0L, Int.MAX_VALUE.toLong()).toInt(),
                )
            }
        } catch (e: Exception) {
            Log.w(TAG, "Failed to fetch address balance: ${e.message}")
            null
        }
    }
}
