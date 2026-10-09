package com.nostrvault.service

import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.model.ContactList
import com.nostrvault.data.model.FollowListFilter
import com.nostrvault.data.model.TrustMap
import com.nostrvault.data.model.TrustPath
import com.nostrvault.relay.HavenBridge
import com.nostrvault.relay.RelayConfiguration
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.withContext
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Finds and caches the Trust Path for an author. Runs only when Event Info or
 * the Web of Trust map opens, never while scrolling: a few follow lists, then
 * the answer is cached for the rest of the session.
 *
 * Port of iOS Services/TrustPathService.swift.
 */
@Singleton
class TrustPathService @Inject constructor(
    private val nostrService: NostrService,
    private val feedService: FeedService,
    private val configStore: ConfigStore,
) {
    private val cache = ConcurrentHashMap<String, TrustPath>()
    private val followLists = ConcurrentHashMap<String, List<String>>()

    val me: String get() = configStore.activeAccountHexPubkey.value

    /** Who you follow, as the feed knows it. */
    fun myFollows(): List<String> = feedService.followedPubkeys.value

    /** You, live: the WOT tab draws a new globe when the account switches. */
    val meUpdates: StateFlow<String> get() = configStore.activeAccountHexPubkey

    /** Who you follow, live: the WOT tab's globe keeps up as the list loads or changes. */
    val followUpdates: StateFlow<List<String>> get() = feedService.followedPubkeys

    /** Your trust graph plus your follows; empty until the graph has loaded. */
    fun myTrustGraph(): Set<String> = feedService.relayTabTrustedPubkeys()

    /**
     * The relay's trust graph as it loads. Android reads it from disk off the
     * main thread, so [myTrustGraph] can be empty on a cold start; key on this
     * to pick it up when it lands. iOS reads it from cache synchronously.
     */
    val trustGraphUpdates: StateFlow<Set<String>> get() = feedService.wotPubkeys

    /** True while your follow list is being fetched. */
    val isLoadingFollows: StateFlow<Boolean> get() = feedService.isLoadingContacts

    /**
     * True once a follow-list load has finished, found or not. Until then an
     * empty follow list means "not in yet", not "follows no one".
     */
    val followsAttempted: StateFlow<Boolean> get() = feedService.hasAttemptedContactLoad

    /** The WOT tab's refresh, step 1: fetch your follow list again. */
    suspend fun refreshFollows() = feedService.refreshContactList()

    /** Step 2: read the relay's trust graph again; [trustGraphUpdates] carries the result. */
    fun reloadTrustGraph() = feedService.loadWotPubkeys()

    suspend fun path(author: String): TrustPath = path(author, me, myFollows(), myTrustGraph())

    /**
     * The same answer seen from someone else: [center]'s follows stand in for
     * yours. The map uses it when you tap a face to re-center on them. With no
     * trust graph for them, "no bridge found" comes back as UNKNOWN.
     */
    suspend fun path(
        author: String,
        center: String,
        follows: List<String>,
        trustGraph: Set<String> = emptySet(),
    ): TrustPath {
        val me = this.me
        // The whole follow set and whether the graph is loaded are in the key,
        // so a follow, an unfollow, or the graph arriving gives a fresh answer.
        val key = "$me|$center|$author|${follows.toSet().hashCode()}|${trustGraph.isEmpty()}"
        cache[key]?.let { return it }

        val lists = ArrayList<ContactList>()
        var anyRelayAnswered = author == center || follows.isEmpty()
        if (!anyRelayAnswered) {
            // One relay at a time: a follow list is the whole list (~90 KB for
            // 1,000 follows), so asking every relay at once would download the
            // same lists several times. Stop once enough bridges are known.
            val filters = TrustPath.filters(author, follows)
            val signers = HashSet<String>()
            for (url in publicRelays().take(MAX_RELAYS)) {
                val found = query(filters, url, 5_000L)
                if (found.isNotEmpty()) anyRelayAnswered = true
                for (list in found) {
                    signers += list.pubkey
                    lists += list
                }
                if (signers.size >= TrustPath.LISTS_PER_FILTER) break
            }
        }
        val result = TrustPath.resolve(author, center, follows.toSet(), trustGraph, lists)
        // An empty answer may just be relays timing out, and an account switch
        // mid-query computed against the old follows: retry those next time.
        if ((anyRelayAnswered || result.reach == TrustPath.Reach.FOLLOW) && this.me == me) {
            cache[key] = result
        }
        return result
    }

    // ── Map ──────────────────────────────────────────────────────────

    /**
     * Who [pubkey] follows, from their newest signed follow list (one list,
     * ~90 KB at 1,000 follows). Cached for the session; null when no relay had it.
     */
    suspend fun followList(pubkey: String): List<String>? {
        if (pubkey == me) return myFollows()
        followLists[pubkey]?.let { return it }
        val filter = FollowListFilter(authors = listOf(pubkey), tagged = null, limit = 1)
        for (url in publicRelays().take(MAX_RELAYS)) {
            val follows = TrustMap.follows(pubkey, query(listOf(filter), url, 5_000L)) ?: continue
            followLists[pubkey] = follows
            return follows
        }
        return null
    }

    /**
     * One "show everyone" batch: more lists from [follows] that tag the author,
     * skipping signers already [seen]. Empty once relays answered with nothing
     * new; null when none answered at all, so a timeout isn't mistaken for
     * "that's everyone".
     */
    suspend fun moreBridgeLists(author: String, follows: List<String>, seen: Set<String>): List<ContactList>? {
        val filters = TrustMap.nextBatch(author, follows, seen)
        if (filters.isEmpty()) return emptyList()
        val answered = AtomicBoolean(false)
        for (url in publicRelays().take(MAX_RELAYS)) {
            val fresh = query(filters, url, 6_000L, answered).filter { it.pubkey !in seen }
            if (fresh.isNotEmpty()) return fresh
        }
        return if (answered.get()) emptyList() else null
    }

    /**
     * "Look deeper": 3-hop routes, you → a follow → someone → the author. Two
     * requests on one relay, a few MB of follow lists, so only on tap. Null
     * when no relay answered, so it can be tried again.
     */
    suspend fun deeperChains(
        author: String,
        center: String,
        follows: List<String>,
        trustGraph: Set<String>,
    ): List<TrustMap.Chain>? {
        val answered = AtomicBoolean(false)
        for (url in publicRelays().take(MAX_RELAYS)) {
            val seeds = query(listOf(TrustMap.deeperSeedFilter(author)), url, 8_000L, answered)
            if (seeds.isEmpty()) continue
            val via = TrustMap.deeperVia(author, center, follows.toSet(), trustGraph, seeds)
            val filters = TrustMap.deeperLinkFilters(follows.filter { it != author }, via)
            if (filters.isEmpty()) return emptyList()
            val links = query(filters, url, 8_000L)
            return TrustMap.chains(center, follows.toSet(), via, links)
        }
        return if (answered.get()) emptyList() else null
    }

    /** Signed follow lists from one relay. A list that fails its signature is dropped. */
    private suspend fun query(
        filters: List<FollowListFilter>,
        url: String,
        timeoutMs: Long,
        answered: AtomicBoolean? = null,
    ): List<ContactList> {
        val events = nostrService.queryRawEvents(
            filters.map { it.toJson() },
            listOf(url),
            timeoutMs,
            onAnswered = answered?.let { flag -> { flag.set(true) } },
        )
        return withContext(Dispatchers.Default) {
            events.filter { HavenBridge.verifyEvent(it.toString()) }.mapNotNull(ContactList::from)
        }
    }

    /**
     * Public relays to ask, in order. Your own relays (this device, the Mac)
     * only keep events from you and your whitelist, so they never hold a
     * follow's list.
     */
    private fun publicRelays(): List<String> {
        val config = configStore.config.value
        val own = setOfNotNull(config.nostrURL, config.macRelayWssURL).map(::relayKey).toSet()
        val urls = config.readRelays.filter { relayKey(it) !in own }
            .ifEmpty { RelayConfiguration.FALLBACK_RELAYS }
        return urls.distinctBy(::relayKey)
    }

    private fun relayKey(url: String) = url.trim().lowercase().trimEnd('/')

    private companion object {
        /** Public relays tried before giving up on finding more bridges. */
        const val MAX_RELAYS = 3
    }
}
