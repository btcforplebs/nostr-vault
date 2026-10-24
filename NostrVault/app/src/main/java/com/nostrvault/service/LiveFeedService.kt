package com.nostrvault.service

import android.util.Log
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.model.LiveStream
import com.nostrvault.data.model.ReelsScope
import com.nostrvault.data.remote.WebSocketClient
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import javax.inject.Inject
import javax.inject.Singleton

/**
 * NIP-53 live streams (kind 30311).
 *
 * Deliberately its own service with its own short-lived connections rather
 * than another mode on the feed subscription: a live event is not a note, it
 * is a replaceable announcement whose truth expires. A stream that ended two
 * minutes ago still says `live` in whatever we cached, so this always refetches
 * rather than restoring anything.
 */
@Singleton
class LiveFeedService @Inject constructor(
    private val configStore: ConfigStore,
    private val nostrService: NostrService,
    private val feedService: FeedService,
) {
    companion object {
        private const val TAG = "LiveFeedService"
        private const val LIMIT = 300
        /**
         * How long to hold the relay connections open for one refresh.
         *
         * 6s was too short on the phone: five sockets each have to do DNS, TLS
         * and a subscription, and the window closed with an empty list on a
         * connection that was working fine — the relays connected at t+5s and
         * were disconnected at t+6s before any of them answered.
         */
        private const val COLLECT_WINDOW_MS = 20_000L

        /** iOS LiveChat.globalGate. */
        fun globalGate(trust: Set<String>?, hasNoWebOfTrustYet: Boolean): GlobalGate = when {
            trust == null -> GlobalGate.Everyone
            trust.isEmpty() && hasNoWebOfTrustYet -> GlobalGate.NewAccount
            else -> GlobalGate.Trusted(trust)
        }

        /**
         * A stream marked adult by its tags (NIP-36 content warning, a NIP-32
         * content-warning label, #nsfw and the like) or by its title or
         * summary (🔞, "NSFW"). Of the 5 streams live on the default relays on
         * 2026-10-12, the adult one carried no tag, only a 🔞 in its title.
         * iOS LiveChat.isAdultStream.
         */
        fun isAdultStream(tags: List<List<String>>): Boolean {
            if (com.nostrvault.data.model.TopicFeedFilter.isAdult(tags)) return true
            if (tags.any { it.size >= 2 && it[0] == "L" && it[1].lowercase() == "content-warning" }) return true
            val text = tags.filter { it.size >= 2 && (it[0] == "title" || it[0] == "summary") }
                .joinToString(" ") { it[1].lowercase() }
            if ("🔞" in text) return true
            return text.split(Regex("[^\\p{L}\\p{N}]+"))
                .any { it in com.nostrvault.data.model.TopicFeedFilter.adultHashtags }
        }
    }

    /** Who the Global side lets in. iOS LiveChat.GlobalGate. */
    sealed interface GlobalGate {
        /** The shield is set to Everyone. */
        data object Everyone : GlobalGate
        /**
         * The Web of Trust. Empty while the graph is still being built, and
         * then nobody passes: an account with a graph coming must not flash
         * unfiltered first.
         */
        data class Trusted(val pubkeys: Set<String>) : GlobalGate
        /** Follows nobody, so no graph: everyone, minus adult streams. */
        data object NewAccount : GlobalGate
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val json = Json { ignoreUnknownKeys = true }

    private val _streams = MutableStateFlow<List<LiveStream>>(emptyList())
    val streams: StateFlow<List<LiveStream>> = _streams.asStateFlow()

    /** Hosts blocked from the player since the last refresh; a late relay answer must not bring them back. */
    private val removedHosts = java.util.concurrent.ConcurrentHashMap.newKeySet<String>()

    private val _isLoading = MutableStateFlow(false)
    val isLoading: StateFlow<Boolean> = _isLoading.asStateFlow()

    /** No relay connected during the last load, so an empty grid is not "nothing live". */
    private val _loadFailed = MutableStateFlow(false)
    val loadFailed: StateFlow<Boolean> = _loadFailed.asStateFlow()

    /** Following by default, as on iPhone; Global follows the shield. */
    private val _scope = MutableStateFlow(ReelsScope.FOLLOWING)
    val liveScope: StateFlow<ReelsScope> = _scope.asStateFlow()

    /** Who Global let in on the last load; null on Following. */
    private val _globalGate = MutableStateFlow<GlobalGate?>(null)
    val globalGate: StateFlow<GlobalGate?> = _globalGate.asStateFlow()

    /** Following, and the account follows nobody: nothing was asked. */
    private val _followSetIsEmpty = MutableStateFlow(false)
    val followSetIsEmpty: StateFlow<Boolean> = _followSetIsEmpty.asStateFlow()

    /**
     * The owner picked a side. Until then someone who follows nobody is
     * opened on Global, since Following can only ever be empty for them.
     */
    @Volatile private var scopeChosen = false

    fun setScope(newScope: ReelsScope) {
        if (newScope == _scope.value) return
        scopeChosen = true
        _scope.value = newScope
        _streams.value = emptyList()
        refresh()
    }

    private var clients = mutableListOf<WebSocketClient>()
    private var job: Job? = null

    fun refresh() {
        job?.cancel()
        disconnect()
        // The block list is read fresh below, so an unblocked host can come back.
        removedHosts.clear()
        _isLoading.value = true
        _loadFailed.value = false
        _followSetIsEmpty.value = false
        _globalGate.value = null

        if (_scope.value == ReelsScope.FOLLOWING && !scopeChosen &&
            feedService.followListIsKnown.value && feedService.followedPubkeys.value.isEmpty()
        ) {
            _scope.value = ReelsScope.GLOBAL
        }
        if (_scope.value == ReelsScope.FOLLOWING && feedService.followedPubkeys.value.isEmpty()) {
            // Every stream would be dropped for want of a followed host; asking
            // five relays for 20s to show nothing is all cost.
            _streams.value = emptyList()
            _isLoading.value = false
            _followSetIsEmpty.value = true
            return
        }

        val relays = configStore.config.value.activeFeedRelays
        if (relays.isEmpty()) {
            _isLoading.value = false
            _loadFailed.value = true
            return
        }

        val blocked = configStore.config.value.blockedForActiveAccount()
            .mapNotNull { nostrService.npubToHex(it) }
            .toSet()
        // Following: streams a follow hosts. Global: the Web of Trust, or
        // everyone with the shield off. Either way judged on the hosts.
        val admitted: Set<String>? = when (_scope.value) {
            ReelsScope.FOLLOWING -> feedService.feedAuthorSet()
            ReelsScope.GLOBAL -> {
                // trust first: reading it loads the graph that hasNoWebOfTrustYet checks.
                val trust = feedService.globalTrustSet()
                val gate = globalGate(trust, feedService.hasNoWebOfTrustYet())
                _globalGate.value = gate
                (gate as? GlobalGate.Trusted)?.pubkeys
            }
        }
        val hidesAdult = _globalGate.value == GlobalGate.NewAccount
        val subId = "live-${System.currentTimeMillis().toString(36)}"
        // Following asks by author and by `p`, for streams a service publishes
        // on a follow's behalf (iOS parity); Global asks for any stream.
        val open = """{"kinds":[${LiveStream.KIND}],"limit":$LIMIT}"""
        val filters = if (_scope.value == ReelsScope.FOLLOWING && !admitted.isNullOrEmpty()) {
            val list = admitted.take(500).joinToString(",") { "\"$it\"" }
            """{"kinds":[${LiveStream.KIND}],"authors":[$list],"limit":$LIMIT},""" +
                """{"kinds":[${LiveStream.KIND}],"#p":[$list],"limit":$LIMIT}"""
        } else open
        // Newest announcement per address wins: 30311 is replaceable, so the
        // same stream arrives repeatedly with updated status and viewer counts,
        // and keeping the first copy would pin it to whatever it said first.
        //
        // One collector per relay writes into this concurrently. A plain
        // LinkedHashMap crashed the app with ConcurrentModificationException on
        // the first real run — one relay inserting while another's publish()
        // iterated. The mutex is what makes read-modify-write atomic; the
        // snapshot copy is what keeps the iteration off the live map.
        val newest = mutableMapOf<String, LiveStream>()
        val newestLock = Mutex()
        // Any relay that connected answered the question, even with nothing.
        val reached = java.util.concurrent.atomic.AtomicBoolean(false)

        job = scope.launch {
            for (url in relays) {
                val client = WebSocketClient(url, scope)
                clients.add(client)
                launch {
                    client.messages.collect { raw ->
                        val stream = parseStream(raw, subId, hidesAdult) ?: return@collect
                        if (stream.hostPubkey in blocked) return@collect
                        if (admitted != null && stream.hosts.none { it in admitted }) return@collect
                        val snapshot = newestLock.withLock {
                            val existing = newest[stream.address]
                            if (existing != null && existing.createdAt >= stream.createdAt) {
                                null
                            } else {
                                newest[stream.address] = stream
                                newest.values.toList()
                            }
                        }
                        snapshot?.let { publish(it) }
                    }
                }
                launch {
                    client.connectionState.collect { state ->
                        if (state == WebSocketClient.ConnectionState.CONNECTED) {
                            reached.set(true)
                            client.send("""["REQ","$subId",$filters]""")
                        }
                    }
                }
                client.connect()
            }

            delay(COLLECT_WINDOW_MS)
            _isLoading.value = false
            _loadFailed.value = !reached.get() && _streams.value.isEmpty()
            // These connections exist to answer one question; holding them open
            // would keep five sockets alive behind a screen nobody is on.
            disconnect()
        }
    }

    fun disconnect() {
        clients.forEach { it.disconnect() }
        clients.clear()
    }

    /**
     * Drops a host's streams from the grid without a refetch, when the owner
     * blocks them from the player. iOS LiveFeedService.removeStreams(byHost:).
     */
    fun removeStreams(byHost: String) {
        removedHosts.add(byHost)
        _streams.value = _streams.value.filter { it.hostPubkey != byHost }
    }

    private fun publish(values: Collection<LiveStream>) {
        val now = System.currentTimeMillis() / 1000
        _streams.value = values
            .filter { it.isPlayableLive && it.isOnAirAt(now) && it.hostPubkey !in removedHosts }
            .sortedByDescending { it.participants ?: 0 }
    }

    /** @return the stream in this relay message, or null if it is not one. */
    private fun parseStream(raw: String, expectedSubId: String, hidesAdult: Boolean): LiveStream? = try {
        val array = json.parseToJsonElement(raw) as? JsonArray
        if (array == null || array.size < 3 ||
            array[0].jsonPrimitive.content != "EVENT" ||
            array[1].jsonPrimitive.content != expectedSubId
        ) {
            null
        } else {
            val event = array[2].jsonObject
            val kind = event["kind"]?.jsonPrimitive?.content?.toIntOrNull()
            val tags = event["tags"]?.jsonArray?.map { tag ->
                tag.jsonArray.map { it.jsonPrimitive.content }
            } ?: emptyList()
            if (kind != LiveStream.KIND || (hidesAdult && isAdultStream(tags))) {
                null
            } else {
                LiveStream.from(
                    pubkey = event["pubkey"]?.jsonPrimitive?.content.orEmpty(),
                    createdAt = event["created_at"]?.jsonPrimitive?.content?.toLongOrNull() ?: 0L,
                    tags = tags,
                )
            }
        }
    } catch (e: Exception) {
        Log.w(TAG, "unparseable relay message: ${e.message}")
        null
    }
}
