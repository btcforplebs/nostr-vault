package com.nostrvault.service

import com.nostrvault.data.model.FeedProfile
import com.nostrvault.data.model.GlobalSearchResults
import com.nostrvault.relay.HavenBridge
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.serialization.json.*
import com.nostrvault.service.NostrService.SearchCaller

    /** Active account and the owner (iOS parity: `request.own`). */
    internal fun NostrService.ownSearchPubkeys(): Set<String> {
        val owner = configStore.config.value.ownerNpub
            .takeIf { it.startsWith("npub1") }
            ?.let { HavenBridge.decodeNpub(it) }
        return setOfNotNull(
            configStore.activeAccountHexPubkey.value.takeIf { it.isNotEmpty() },
            owner?.takeIf { it.isNotEmpty() },
        )
    }

    /** Profiles a search discovered join the cache, so result rows and mentions resolve. */
    fun NostrService.mergeSearchProfiles(found: List<FeedProfile>) {
        if (found.isEmpty()) return
        val now = System.currentTimeMillis()
        val current = _profiles.value
        val additions = found.filter { !current.containsKey(it.pubkey) }
            .associate { it.pubkey to it.copy(fetchedAt = now) }
        if (additions.isNotEmpty()) _profiles.value = current + additions
    }

    internal fun NostrService.deliverCallbackSearch(
        caller: SearchCaller,
        results: GlobalSearchResults,
        onResult: (GlobalSearchResults) -> Unit,
    ) {
        scope.launch {
            mergeSearchProfiles(results.profiles)
            // Still this caller's search? `results` belongs to the session that
            // produced it; compare by the finished session's identity.
            val current = callbackSearches[caller] ?: return@launch
            if (current.finishedResults !== results) return@launch
            callbackSearches.remove(caller, current)
            onResult(results)
        }
    }
