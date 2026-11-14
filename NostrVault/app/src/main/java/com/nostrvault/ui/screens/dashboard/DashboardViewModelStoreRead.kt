package com.nostrvault.ui.screens.dashboard

import android.util.Log
import com.nostrvault.relay.StartupMarks
import com.nostrvault.relay.VaultStoreRead
import com.nostrvault.ui.screens.dashboard.DashboardViewModel.Companion.TAG
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/**
 * The Notes / Likes / Zaps lists' rows straight from the store (VaultStoreRead;
 * iOS NostrService+VaultDirectRead): the same filters as the socket, through
 * the same per-event path (processVaultEvent), so the lists, dots and zap
 * checks read them as before. The first read for an account takes the whole
 * window, later ones what is new. Not ready: nothing happens here and the
 * socket reads as it always did.
 */
internal suspend fun DashboardViewModel.readVaultFromStore() = storeReadMutex.withLock {
    val owner = nostrService.activeHexPubkey.lowercase()
    if (owner.isEmpty()) return@withLock
    val local = configStore.config.value.nostrURL ?: return@withLock
    val epoch = storeEpoch.get()
    val newest = newestEventCreatedAt
    val since = if (storeAnswered == owner && newest > 0) ",\"since\":${newest - 60}" else ""
    val filters = vaultFilters(buildAuthorSet(), owner, since, since)
    val rows = withContext(Dispatchers.IO) { VaultStoreRead.query(filters) } ?: return@withLock
    if (epoch != storeEpoch.get() || nostrService.activeHexPubkey.lowercase() != owner) return@withLock
    withContext(Dispatchers.IO) {
        for (row in rows) {
            try {
                processVaultEvent(row, local) { """["EVENT","vault-store",$row]""" }
            } catch (e: Exception) {
                Log.w(TAG, "Store row skipped: ${e.message}")
            }
        }
    }
    if (epoch != storeEpoch.get()) return@withLock
    storeAnswered = owner
    if (rows.isNotEmpty()) StartupMarks.markOnce("vault store read", "vault store read ${rows.size}")
    _notesHasLoadedOnce.value = true
    updateJob?.cancel()
    updateGeneration++
    updateDisplayData(updateGeneration)
}

/** Whether [relayUrl] is this device's own outbox or inbox, which the store read covers. */
internal fun DashboardViewModel.isLocalVaultRelay(relayUrl: String): Boolean {
    val config = configStore.config.value
    return relayUrl == config.nostrURL || relayUrl == config.localInboxURL
}
