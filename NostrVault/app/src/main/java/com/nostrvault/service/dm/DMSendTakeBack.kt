package com.nostrvault.service

import android.util.Log
import kotlinx.coroutines.*
import java.io.File
import com.nostrvault.service.DMService.Companion.TAG

/** Thrown when the account changed while a DM was being sealed or signed: nothing was sent. */
class DMAccountSwitchedException :
    Exception("You switched accounts before this message went out. It was not sent.")

/** [conversations] without one message; a conversation left empty is dropped. */
internal fun List<DMConversation>.withoutMessage(counterparty: String, messageId: String): List<DMConversation> {
    val index = indexOfFirst { it.id == counterparty }
    if (index < 0) return this
    val conv = this[index]
    val remaining = conv.messages.filterNot { it.id == messageId }
    if (remaining.size == conv.messages.size) return this
    return toMutableList().apply {
        if (remaining.isEmpty()) removeAt(index) else this[index] = conv.copy(messages = remaining)
    }
}

/**
 * Takes back the optimistic bubble of a send that never went out. It is
 * removed from the live inbox when [cacheKey]'s account is still the loaded
 * one, and from that account's saved inbox otherwise: an account switch has
 * already written the bubble there, and it would come back looking sent.
 * Runs to the end even if the caller is cancelled.
 */
internal suspend fun DMService.takeBackOptimisticSend(cacheKey: String?, counterparty: String, messageId: String) =
    withContext(NonCancellable) {
        val live = withContext(Dispatchers.Main.immediate) {
            (loadedCacheKey == cacheKey).also { if (it) removeMessageFromConversation(counterparty, messageId) }
        }
        if (live || cacheKey == null) return@withContext
        // The switch's save of the old inbox must land first, or it would
        // write the bubble back over this edit.
        switchSaveJob?.join()
        withContext(Dispatchers.IO) {
            try {
                val dir = configStore.config.value.appSupportDir ?: return@withContext
                val file = File(dir, "dm_cache_$cacheKey.json")
                if (!file.exists()) return@withContext
                val saved = json.decodeFromString<List<DMConversation>>(file.readText())
                val kept = saved.withoutMessage(counterparty, messageId)
                if (kept !== saved) writeCache(cacheKey, kept)
            } catch (e: Exception) {
                Log.w(TAG, "Could not take back an unsent DM: ${e.message}")
            }
        }
    }
