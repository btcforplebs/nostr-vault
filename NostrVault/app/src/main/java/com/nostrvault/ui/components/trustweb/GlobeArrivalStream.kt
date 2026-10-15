package com.nostrvault.ui.components

import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.model.FeedMode
import com.nostrvault.data.model.FeedNote
import com.nostrvault.data.model.GlobeArcs
import com.nostrvault.data.model.GlobeLive
import com.nostrvault.data.model.GlobeStorm
import com.nostrvault.data.model.MediaFeedMode
import com.nostrvault.relay.HavenBridge
import com.nostrvault.relay.RelayForegroundService
import com.nostrvault.service.FeedService
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.channels.ProducerScope
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.buffer
import kotlinx.coroutines.flow.channelFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.flow.merge
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/**
 * Notes arriving, as globe arrivals, each marked with the feed it belongs to
 * (iOS `GlobeArrivalStream` in TrustWebView+LiveArcs.swift). Your follows'
 * notes: when the feed has their timeline open (Following, or Media on
 * Following) they come from its own live subscription, one stream with no
 * second set of connections. In every other feed mode the globe asks for notes
 * to you itself. Which of the two is re-picked whenever the feed mode or your
 * device relay changes. Everything else comes from one wider REQ on each of
 * your read relays. Every REQ rides the feed's own open connection to its relay
 * ([GlobeRelayLink]): the globe opens no connections of its own.
 *
 * Collect [arrivals] while the globe shows live arcs; cancelling closes every REQ.
 * Relay messages are parsed off the main thread.
 */
internal class GlobeArrivalStream(private val feed: FeedService) {
    private val configStore: ConfigStore get() = feed.configStore

    /** Where your follows' arrivals come from. */
    private sealed interface Source {
        /** The feed's own live timeline. */
        data object Feed : Source
        /** The globe's own REQ; [inbox] is your device relay's, when it is up. */
        data class Own(val inbox: String?) : Source
    }

    /** A sort switched off isn't asked for at all ([show]). */
    fun arrivals(me: String, rings: Set<GlobeArcs.Ring>, show: GlobeLive.Show): Flow<GlobeArcs.Arrival> = channelFlow {
        if (rings.isEmpty()) return@channelFlow
        val blocked = feed.blockedHexForActiveAccount()
        val follows = feed.followedPubkeys.value.toHashSet().apply { add(me) }
        val wider = feed.extendedNetworkPubkeys.value.ifEmpty { feed.relayTabTrustedPubkeys().toList() }
        val discover = wider.toHashSet().apply { removeAll(follows) }
        val links = ArrayList<GlobeRelayLink>()
        try {
            openWide(me, rings, show, follows, discover, blocked, links)
            if (GlobeArcs.Ring.FOLLOWING !in rings) awaitCancellation()
            combine(feed.feedMode, feed.mediaFeedMode, RelayForegroundService.relayStatus) { mode, media, status ->
                val carriesFollows = mode == FeedMode.FOLLOWING || (mode == FeedMode.MEDIA && media == MediaFeedMode.FOLLOWING)
                val inbox = configStore.config.value.localInboxURL
                    ?.takeIf { status == RelayForegroundService.RelayStatus.RUNNING }
                if (carriesFollows && inbox != null) Source.Feed else Source.Own(inbox)
            }.distinctUntilChanged().collectLatest { source ->
                // A new source cancels the old one, closing its links.
                when (source) {
                    Source.Feed -> watchFeed(me, follows, blocked)
                    is Source.Own -> ask(source.inbox, me, follows, blocked, show.noteKinds)
                }
            }
        } finally {
            withContext(kotlinx.coroutines.NonCancellable + Dispatchers.Main.immediate) { links.forEach { it.close() } }
        }
    }.buffer(ARRIVAL_BUFFER).flowOn(Dispatchers.Main.immediate)

    /**
     * New notes as the feed takes them in: yours, your follows', and those that
     * tag you (the feed's are from your device relay's inbox, which already keeps
     * strangers out). Notes land in pendingNotes or notes depending on their age
     * and the feed's scroll, so both are watched; both are newest first, so only
     * their fresh heads are read. What is already there when the globe opens has
     * arrived, so it doesn't fly.
     */
    private suspend fun ProducerScope<GlobeArcs.Arrival>.watchFeed(me: String, follows: Set<String>, blocked: Set<String>) {
        fun fresh(notes: List<FeedNote>): List<FeedNote> {
            val cutoff = System.currentTimeMillis() - FRESH_WINDOW_MS
            return notes.takeWhile { it.createdAt.time >= cutoff }
        }
        // Seen ids and when they were written; only the fresh window is kept.
        val seen = HashMap<String, Long>()
        for (note in fresh(feed.notes.value) + fresh(feed.pendingNotes.value)) seen[note.id] = note.createdAt.time
        merge(feed.pendingNotes, feed.notes).collect { notes ->
            for (note in fresh(notes)) {
                if (note.repostedBy != null || note.id in seen) continue
                seen[note.id] = note.createdAt.time
                val arrival = GlobeArcs.arrival(note.kind, note.id, note.pubkey, note.createdAt.time / 1000.0, note.tags)
                    ?: continue
                if (arrival.author in blocked) continue
                if (arrival.author !in follows && me !in arrival.targets) continue
                // A note to you from outside your follows still flies on Following:
                // your relay's inbox already kept strangers out.
                send(arrival.copy(ring = GlobeArcs.Ring.FOLLOWING))
            }
            if (seen.size > SEEN_KEEP) {
                val cutoff = System.currentTimeMillis() - FRESH_WINDOW_MS
                seen.entries.removeAll { it.value < cutoff }
            }
            // More than that inside one minute: keep the newest. The board drops a repeat id itself.
            if (seen.size > SEEN_KEEP) {
                val keep = seen.entries.sortedByDescending { it.value }.take(SEEN_KEEP).associate { it.key to it.value }
                seen.clear()
                seen.putAll(keep)
            }
        }
    }

    /**
     * Notes to you, when the feed isn't carrying your follows. Yours and your
     * follows' own notes come in on the wider REQ ([openWide]). Notes to you come
     * from your device relay's inbox when it is up, which keeps strangers out;
     * when it isn't, from the read relays, where anyone can tag you, so only your
     * web's come through, the same as Global.
     */
    private suspend fun ProducerScope<GlobeArcs.Arrival>.ask(
        inbox: String?, me: String, follows: Set<String>, blocked: Set<String>, kinds: List<Int>,
    ) {
        // An empty kinds list would match everything on some relays.
        if (kinds.isEmpty()) return
        val toMe = buildJsonObject {
            put("kinds", JsonArray(kinds.map { JsonPrimitive(it) }))
            put("since", System.currentTimeMillis() / 1000)
            put("#p", JsonArray(listOf(JsonPrimitive(me))))
        }
        val urls = inbox?.let { listOf(it) } ?: configStore.config.value.readRelays
        val trusted = if (inbox == null) feed.relayTabTrustedPubkeys() + follows else null
        val links = urls.map { url ->
            GlobeRelayLink(url, listOf(toMe), feed, this) { event ->
                val arrival = GlobeArcs.arrival(event) ?: return@GlobeRelayLink
                if (arrival.author in blocked || (trusted != null && arrival.author !in trusted)) return@GlobeRelayLink
                trySend(arrival.copy(ring = GlobeArcs.Ring.FOLLOWING))
            }
        }
        try {
            awaitCancellation()
        } finally {
            withContext(kotlinx.coroutines.NonCancellable + Dispatchers.Main.immediate) { links.forEach { it.close() } }
        }
    }

    /**
     * The wider REQ on every one of your read relays: your follows' notes,
     * reposts (the feed shows a repost as the note reposted, so it can't say when
     * one is made), reactions and zaps, and the Discover and Global feeds when they're
     * on, as one stream sorted here by author ([GlobeStorm.storm]). Global keeps
     * to your web, as the Global feed does, unless that is set to Everyone.
     */
    private fun ProducerScope<GlobeArcs.Arrival>.openWide(
        me: String, rings: Set<GlobeArcs.Ring>, show: GlobeLive.Show,
        follows: Set<String>, discover: Set<String>, blocked: Set<String>, links: MutableList<GlobeRelayLink>,
    ) {
        // A note the feed's timeline also carries flies once: the board drops a repeat id.
        val filters = GlobeStorm.storm(rings, show, follows.sorted(), System.currentTimeMillis() / 1000)
        if (filters.isEmpty()) return
        val trusted = if (GlobeArcs.Ring.GLOBAL in rings) feed.globalTrustSet() else null
        for (url in configStore.config.value.readRelays) {
            links += GlobeRelayLink(url, filters, feed, this) { event ->
                // A zap's request must be signed by its zapper.
                val parsed = GlobeArcs.arrival(event, verifyZap = HavenBridge::verifyEvent) ?: return@GlobeRelayLink
                if (parsed.author in blocked) return@GlobeRelayLink
                val arrival = parsed.copy(ring = GlobeArcs.ring(parsed.author, follows, discover))
                if (arrival.ring !in rings) return@GlobeRelayLink
                if (arrival.ring == GlobeArcs.Ring.GLOBAL && trusted != null && arrival.author !in trusted) return@GlobeRelayLink
                trySend(arrival)
            }
        }
    }

    companion object {
        /** How far back a note in the feed still counts as just arrived, for authors whose clocks run slow. */
        const val FRESH_WINDOW_MS = 60_000L
        /** Fresh ids kept to tell a new note from one already flown. */
        const val SEEN_KEEP = 256
        /** Arrivals held while the frame clock catches up; the board caps what flies anyway. */
        const val ARRIVAL_BUFFER = 1_024
    }
}

/** What the WOT tab's globe asks to fly: [stream]'s arrivals for [me], from [rings], of the sorts [show] allows. */
internal data class LiveArcsRequest(
    val me: String,
    val rings: Set<GlobeArcs.Ring>,
    val show: GlobeLive.Show,
    val stream: GlobeArrivalStream,
)
