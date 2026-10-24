package com.nostrvault.service

import com.nostrvault.data.model.*
import com.nostrvault.data.remote.WebSocketClient
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.serialization.json.*

    /** The relays every feed subscription asks, before the follows' own (outbox) relays. */
    private fun FeedService.baseFeedRelayUrls(): List<String> {
        val config = configStore.config.value
        return buildList {
            config.nostrURL?.let { add(it) }
            config.localInboxURL?.let { add(it) }
            // Local feed cache: follows' recent notes kept in sync by the
            // embedded relay (negentropy against the feed relays). Serves the
            // feed window from disk instantly on cold start and pagination.
            config.localRelayURL("feed")?.let { add(it) }
            config.inboxRelays?.let { addAll(it) }
            // Follows publish to feed/blastr relays, not just the local + inbox
            // set. Mirror iOS (externalRelayURLs) and the fetchReplies fix so
            // follows who post elsewhere actually appear in the feed.
            addAll(config.readRelays)
            addAll(config.writeRelays)
        }.distinct().let { FeedService.relaysForMode(_feedMode.value, it) }
    }

    /**
     * Recomputes [outboxPlan] from the follow set and the NIP-65 lists known so
     * far, and asks for the lists still missing; the plan grows as they arrive
     * (see the outboxRelays collector in init).
     */
    private fun FeedService.refreshOutboxPlan(feedRelays: List<String>) {
        val follows = _followedPubkeys.value
        if (!isFollowSetMode() || follows.isEmpty()) {
            outboxPlan = emptyMap()
            outboxPlanInputs = null
            return
        }
        val inputs = FeedOutboxPlan.Inputs(
            follows = follows,
            writeRelays = nostrService.outboxRelays.value,
            feedRelays = feedRelays,
            unreachableRelays = downRelayUrls.toSet(),
        )
        // Every reconcile lands here (each load round, older page and relay
        // drop), mostly with nothing changed. As on iOS, keep the last plan.
        if (inputs == outboxPlanInputs) return
        outboxPlanInputs = inputs
        requestRelayListsForAuthors(follows)
        outboxPlan = FeedOutboxPlan.plan(inputs)
    }

    /** Every relay the feed subscribes to: [baseFeedRelayUrls], then the follows' own relays. */
    internal fun FeedService.feedRelayUrlsWithOutbox(): List<String> {
        val base = baseFeedRelayUrls()
        refreshOutboxPlan(base)
        return (base + outboxPlan.keys.sorted()).distinct()
    }

    /**
     * The follows to ask a relay for: an outbox relay only for the follows it
     * was picked for, every other relay for all of them.
     */
    internal fun FeedService.followAuthors(relayUrl: String): List<String> =
        outboxPlan[relayUrl] ?: feedAuthors()

    /**
     * Brings the follows' own relays in line with a fresh plan: drops the ones
     * it no longer picks (their follows were taken by another, or the relay
     * died) and connects the new ones. With [resend], connected ones whose
     * follows changed get their REQ again. Does nothing while the feed has no
     * connections (paused, or not loaded yet).
     */
    internal fun FeedService.reconcileOutboxRelays(resend: Boolean = true) {
        if (feedClients.isEmpty()) return
        val before = outboxPlan
        val base = baseFeedRelayUrls()
        refreshOutboxPlan(base)
        val plan = outboxPlan
        for (relayUrl in before.keys) {
            if (relayUrl !in plan && relayUrl !in base) teardownFeedClient(relayUrl)
        }
        for ((relayUrl, authors) in plan) {
            val client = feedClients[relayUrl]
            if (client == null) {
                connectFeedRelay(relayUrl)
            } else if (resend && before[relayUrl] != authors &&
                client.connectionState.value == WebSocketClient.ConnectionState.CONNECTED
            ) {
                sendPrimaryFeedSubscription(relayUrl, primaryFeedSubId())
            }
        }
    }
