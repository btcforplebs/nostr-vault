package com.nostrvault.ui.components

import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.model.GlobeArcs
import com.nostrvault.data.model.GlobeLive
import com.nostrvault.data.model.GlobeStorm
import com.nostrvault.relay.HavenBridge
import com.nostrvault.relay.RelayForegroundService
import com.nostrvault.service.FeedService
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.buffer
import kotlinx.coroutines.flow.channelFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.withContext

/**
 * Your web's activity, as globe arrivals (iOS `GlobeArrivalStream` in
 * TrustWebView+LiveArcs.swift; rules RESEARCH/NV_GLOBE_STARS_FINAL.md, Logen
 * 11/19). One REQ per relay asks for just your web's notes, replies, reposts
 * and reactions by author ([GlobeStorm.filters]): you and your follows (hop 1)
 * and, with Friends of friends on, the rest of your own web (hop 2). Zaps from
 * anyone come in on one authorless filter of their own. It goes to your read
 * relays and, while it runs, your device relay's inbox. Every REQ rides the
 * feed's open connection to its relay ([GlobeRelayLink]).
 *
 * Collect [arrivals] while the globe shows live arcs; cancelling closes every REQ.
 * Relay messages are parsed off the main thread.
 */
internal class GlobeArrivalStream(private val feed: FeedService) {
    private val configStore: ConfigStore get() = feed.configStore

    fun arrivals(me: String, show: GlobeLive.Show): Flow<GlobeArcs.Arrival> = channelFlow {
        val blocked = feed.blockedHexForActiveAccount()
        val follows = feed.followedPubkeys.value.toHashSet().apply { add(me) }
        // Hop 2: the open account's own web (the gate's), not the Discover list.
        val web = feed.relayTabTrustedPubkeys().toHashSet().apply { removeAll(follows) }
        val authors = (follows + if (show.friendsOfFriends) web else emptySet()).sorted()
        val filters = GlobeStorm.filters(authors, show, System.currentTimeMillis() / 1000)
        if (filters.isEmpty()) return@channelFlow
        RelayForegroundService.relayStatus
            .map { it == RelayForegroundService.RelayStatus.RUNNING }
            .distinctUntilChanged()
            .collectLatest { running ->
                // The relay starting or stopping re-sends to the new set of URLs.
                val inbox = configStore.config.value.localInboxURL?.takeIf { running }
                val urls = (configStore.config.value.readRelays + listOfNotNull(inbox)).distinct()
                val links = urls.map { url ->
                    GlobeRelayLink(url, filters, feed, this@channelFlow) { event ->
                        // A zap's request must be signed by its zapper.
                        val parsed = GlobeArcs.arrival(event, verifyZap = HavenBridge::verifyEvent) ?: return@GlobeRelayLink
                        if (parsed.author in blocked) return@GlobeRelayLink
                        val arrival = parsed.copy(ring = GlobeArcs.ring(parsed.author, follows, web))
                        // Past MAX_AUTHORS the filter is authorless: the same check here.
                        if (!show.allows(arrival.sort, arrival.ring)) return@GlobeRelayLink
                        trySend(arrival)
                    }
                }
                try {
                    awaitCancellation()
                } finally {
                    withContext(kotlinx.coroutines.NonCancellable + Dispatchers.Main.immediate) { links.forEach { it.close() } }
                }
            }
    }.buffer(ARRIVAL_BUFFER).flowOn(Dispatchers.Main.immediate)

    companion object {
        /** Arrivals held while the frame clock catches up; the board caps what flies anyway. */
        const val ARRIVAL_BUFFER = 1_024
    }
}

/** What the WOT tab's globe asks to fly: [stream]'s arrivals for [me], as [show] allows. */
internal data class LiveArcsRequest(
    val me: String,
    val show: GlobeLive.Show,
    val stream: GlobeArrivalStream,
)
