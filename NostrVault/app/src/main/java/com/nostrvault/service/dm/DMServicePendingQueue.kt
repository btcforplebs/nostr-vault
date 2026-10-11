package com.nostrvault.service

import android.util.Log
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import java.io.File
import com.nostrvault.service.DMService.Companion.MAX_PERSISTED_PENDING
import com.nostrvault.service.DMService.Companion.PENDING_SAVE_DEBOUNCE_MS
import com.nostrvault.service.DMService.Companion.TAG

/**
 * Durability for the signer-decrypt backlog. Inbound DMs that this device
 * cannot open yet (Amber has not granted silent signing, or the bunker is
 * asleep) used to sit in an in-memory queue only: a process death lost the
 * whole backlog, and whether it ever came back depended on a relay choosing to
 * serve the same wrap again. iOS persists the same backlog
 * (DMService+Persistence.saveUnreadableGiftWrapIds); this is the Android half.
 *
 * Raw events are stored, not ids: the point is to decrypt them later without
 * needing a relay to re-send them.
 */

/** Where the queue for [accountHex] lives, next to that account's DM cache. */
private fun DMService.pendingFile(accountHex: String): File? {
    val dir = configStore.config.value.appSupportDir ?: return null
    return File(dir, "dm_pending_$accountHex.json")
}

/**
 * Writes the queue for [accountHex] (default: the loaded account) after a short
 * debounce, so a burst of arrivals costs one write.
 */
internal fun DMService.savePendingQueue() {
    pendingSaveJob?.cancel()
    pendingSaveJob = scope.launch(Dispatchers.IO) {
        delay(PENDING_SAVE_DEBOUNCE_MS)
        writePendingQueueNow()
    }
}

/** Writes the queue for the loaded account immediately. */
internal fun DMService.writePendingQueueNow() {
    val key = loadedCacheKey ?: return
    writePendingQueue(key, pendingDecryptQueue.toList())
}

internal fun DMService.writePendingQueue(accountHex: String, events: List<JsonObject>) {
    val file = pendingFile(accountHex) ?: return
    try {
        if (events.isEmpty()) {
            file.delete()
            return
        }
        file.parentFile?.mkdirs()
        // Oldest first, newest dropped: an unbounded file is a disk-fill bug,
        // and the oldest wraps are the ones a relay is least likely to re-serve.
        val kept = events.take(MAX_PERSISTED_PENDING)
        file.writeText(JsonArray(kept).toString())
    } catch (e: Exception) {
        Log.w(TAG, "DM pending queue save failed: ${e.message}")
    }
}

/**
 * Re-feeds a persisted backlog through the normal inbound path, so every guard
 * still applies: the signature is verified again (the file is not a trusted
 * input — a tampered entry must not reach the conversation list), and the
 * events route by the CURRENT signing mode, which may have changed since they
 * were queued.
 */
internal fun DMService.restorePendingDecrypts(generation: Int) {
    scope.launch(Dispatchers.IO) {
        val key = configStore.activeAccountHexPubkey.value.ifEmpty { null } ?: return@launch
        val file = pendingFile(key) ?: return@launch
        if (!file.exists()) return@launch
        val events = try {
            json.parseToJsonElement(file.readText()).jsonArray
        } catch (e: Exception) {
            Log.w(TAG, "DM pending queue unreadable, dropping: ${e.message}")
            file.delete()
            return@launch
        }
        Log.i(TAG, "Restoring ${events.size} queued DM decrypt(s)")
        for (element in events.take(MAX_PERSISTED_PENDING)) {
            if (switchGeneration != generation) return@launch
            val obj = element as? JsonObject ?: continue
            when (obj["kind"]?.jsonPrimitive?.intOrNull) {
                1059 -> handleIncomingGiftWrap(obj, generation)
                4 -> handleIncomingNIP04(obj, generation)
            }
        }
        // Anything still unopenable was re-queued above and will be written
        // back by savePendingQueue(); anything opened is in the conversation
        // cache now and must not come back.
        if (switchGeneration == generation) writePendingQueueNow()
    }
}
