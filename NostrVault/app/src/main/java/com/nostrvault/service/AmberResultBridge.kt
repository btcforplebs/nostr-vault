package com.nostrvault.service

import android.app.Activity
import android.content.Intent
import android.util.Log
import androidx.activity.ComponentActivity
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.contract.ActivityResultContracts
import kotlinx.coroutines.CompletableDeferred
import java.util.concurrent.ConcurrentHashMap

/**
 * Bridges Android ActivityResult with coroutine suspension for Amber NIP-55 signing.
 * Must be initialized in MainActivity.onCreate() before the Activity reaches STARTED state.
 */
object AmberResultBridge {

    private var launcher: ActivityResultLauncher<Intent>? = null

    // Maps request IDs to their CompletableDeferred results
    private val pendingRequests = ConcurrentHashMap<String, CompletableDeferred<AmberResult>>()

    // Track which request ID corresponds to the most recent launch
    @Volatile
    private var activeRequestId: String? = null

    data class AmberResult(
        val resultCode: Int,
        val signature: String? = null,
        val event: String? = null,
        val pubkey: String? = null,
        val packageName: String? = null,
        val rejected: Boolean = false,
    )

    fun initialize(activity: ComponentActivity) {
        launcher = activity.registerForActivityResult(
            ActivityResultContracts.StartActivityForResult()
        ) { result ->
            val reqId = activeRequestId ?: return@registerForActivityResult
            val deferred = pendingRequests.remove(reqId) ?: return@registerForActivityResult

            if (result.resultCode == Activity.RESULT_OK) {
                val data = result.data
                Log.w("AmberResultBridge", "DBG: OK extras keys=${data?.extras?.keySet()} result=${data?.getStringExtra("result")?.length} signature=${data?.getStringExtra("signature")?.length} event=${data?.getStringExtra("event")?.length}")
                deferred.complete(
                    AmberResult(
                        resultCode = result.resultCode,
                        signature = data?.getStringExtra("signature"),
                        event = data?.getStringExtra("event"),
                        pubkey = data?.getStringExtra("result"),
                        packageName = data?.getStringExtra("package"),
                    )
                )
            } else {
                deferred.complete(
                    AmberResult(
                        resultCode = result.resultCode,
                        rejected = true,
                    )
                )
            }
        }
    }

    /**
     * Launch an Amber intent and suspend until the result arrives.
     * Returns null if no launcher is available (Activity not initialized).
     */
    suspend fun launchAndAwait(intent: Intent, requestId: String): AmberResult? {
        val l = launcher ?: return null
        val deferred = CompletableDeferred<AmberResult>()
        pendingRequests[requestId] = deferred
        activeRequestId = requestId

        try {
            l.launch(intent)
        } catch (e: Exception) {
            pendingRequests.remove(requestId)
            return null
        }

        return deferred.await()
    }

    fun detach() {
        // Cancel any pending requests
        pendingRequests.values.forEach { it.cancel() }
        pendingRequests.clear()
    }
}
