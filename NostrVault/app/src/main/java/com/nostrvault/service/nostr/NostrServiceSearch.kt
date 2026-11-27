package com.nostrvault.service

import com.nostrvault.data.model.FeedProfile
import com.nostrvault.data.model.GlobalSearchResults
import com.nostrvault.relay.HavenBridge
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.serialization.json.*
import com.nostrvault.service.NostrService.SearchCaller
import com.nostrvault.data.model.SearchTermMatcher

    /**
     * "You" for every people box (search plan §1a): the active account and
     * every account on this phone, owner included, as lowercase hex.
     */
    internal fun NostrService.ownSearchPubkeys(): Set<String> {
        val out = HashSet<String>()
        configStore.activeAccountHexPubkey.value.takeIf { it.isNotEmpty() }?.let { out += it.lowercase() }
        for (npub in configStore.config.value.allAccountNpubs()) {
            if (!npub.startsWith("npub1")) continue
            HavenBridge.decodeNpub(npub)?.takeIf { it.isNotEmpty() }?.let { out += it.lowercase() }
        }
        return out
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

    /**
     * Starts a search session and returns it; the caller collects
     * [GlobalSearchSession.state] and cancels the session when the query
     * changes. Returns null for a query too short to search.
     *
     * The Search tab always passes [includeGlobal] true: the phone's embedded
     * relay, the Mac relay (if configured) and the configured NIP-50 search
     * relays, all at once. False walks the phone's relay only; the Vault search
     * builds its own phone-only session instead of calling this.
     */
    internal fun NostrService.startSearchImpl(query: String, includeGlobal: Boolean, follows: Set<String>, wot: Set<String> = emptySet()): GlobalSearchSession? {
        val matcher = SearchTermMatcher.create(query) ?: return null
        val config = configStore.config.value
        val plan = GlobalSearchSession.Plan(
            phoneRelayUrl = config.nostrURL,
            macRelayUrl = if (includeGlobal) config.macRelayWssURL.ifEmpty { null } else null,
            searchRelays = if (includeGlobal) config.activeSearchRelays else emptyList(),
        )
        val session = GlobalSearchSession(
            query = query.trim(),
            matcher = matcher,
            plan = plan,
            own = ownSearchPubkeys(),
            follows = follows,
            wot = wot,
            cachedProfiles = _profiles.value.values.toList(),
            onFinished = { results -> scope.launch { mergeSearchProfiles(results.profiles) } },
        )
        session.start()
        return session
    }

    internal fun NostrService.globalSearchImpl(
        query: String,
        caller: SearchCaller,
        onResult: (GlobalSearchResults) -> Unit,
    ) {
        cancelGlobalSearch(caller)
        val matcher = SearchTermMatcher.create(query)
        if (matcher == null) {
            onResult(GlobalSearchResults())
            return
        }
        val session = GlobalSearchSession(
            query = query.trim(),
            matcher = matcher,
            plan = GlobalSearchSession.Plan(
                phoneRelayUrl = null,
                macRelayUrl = null,
                searchRelays = configStore.config.value.activeSearchRelays,
            ),
            own = ownSearchPubkeys(),
            follows = emptySet(),
            onFinished = { results -> deliverCallbackSearch(caller, results, onResult) },
        )
        callbackSearches[caller] = session
        session.start()
    }
