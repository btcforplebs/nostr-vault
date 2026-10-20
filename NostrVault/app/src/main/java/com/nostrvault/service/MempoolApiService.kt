package com.nostrvault.service

import android.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.intOrNull
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
     * Returns the spendable balance (sats) of [address] = funded − spent,
     * summing confirmed (chain_stats) and unconfirmed (mempool_stats) txos.
     * Returns null on network/parse failure.
     */
    suspend fun fetchAddressBalanceSats(address: String): Long? = withContext(Dispatchers.IO) {
        try {
            val request = Request.Builder().url("$BASE_URL/address/$address").build()
            client.newCall(request).execute().use { response ->
                if (!response.isSuccessful) return@withContext null
                val body = response.body?.string() ?: return@withContext null
                val root = json.parseToJsonElement(body).jsonObject

                fun stat(group: String, field: String): Long =
                    root[group]?.jsonObject?.get(field)?.jsonPrimitive?.intOrNull?.toLong() ?: 0L

                val funded = stat("chain_stats", "funded_txo_sum") +
                    stat("mempool_stats", "funded_txo_sum")
                val spent = stat("chain_stats", "spent_txo_sum") +
                    stat("mempool_stats", "spent_txo_sum")
                (funded - spent).coerceAtLeast(0L)
            }
        } catch (e: Exception) {
            Log.w(TAG, "Failed to fetch address balance: ${e.message}")
            null
        }
    }
}
