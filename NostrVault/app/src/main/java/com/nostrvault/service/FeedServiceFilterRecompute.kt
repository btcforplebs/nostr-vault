package com.nostrvault.service

import com.nostrvault.data.model.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.serialization.json.*
import com.nostrvault.service.FeedService.Companion.RECOMPUTE_DEBOUNCE_MS

    // ══════════════════════════════════════════════════════════════════
    // Filtering
    // ══════════════════════════════════════════════════════════════════

    /**
     * Coalesced filter recomputation.
     * Multiple rapid-fire calls (e.g. batch flush + engagement update + profile
     * update all within 50 ms) are collapsed into a single computation.
     */
    fun FeedService.recomputeFilteredNotes() {
        recomputeJob?.cancel()
        // Run the filter/sort on Default, NOT Main. doRecomputeFilteredNotes()
        // filters + sorts the entire notes list (allocating new lists) and, under
        // a relay-event flood, fires every debounce window — doing that on
        // Main.immediate saturated the UI thread and was the main feed-slowness
        // source. The reads (.value) and StateFlow writes here are thread-safe.
        recomputeJob = scope.launch(Dispatchers.Default) {
            delay(RECOMPUTE_DEBOUNCE_MS)
            doRecomputeFilteredNotes()
        }
    }

    /** Same as Settings → Blocked: the active account's list, signed as it. */
    internal fun FeedService.publishActiveMuteList() {
        val cfg = configStore.config.value
        val account = cfg.activeOrOwnerNpub()
        val list = cfg.blockedForActiveAccount()
        scope.launch(Dispatchers.IO) { nostrService.publishMuteList(account, list) }
    }
