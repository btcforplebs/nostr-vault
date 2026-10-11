package com.nostrvault.ui.screens

import android.util.Log
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.model.FeedNote
import com.nostrvault.data.remote.WebSocketClient
import com.nostrvault.relay.HavenBridge
import com.nostrvault.service.TopicFeedScreener
import com.nostrvault.service.FeedFilterEngine
import com.nostrvault.service.FeedService
import com.nostrvault.service.InterestList
import com.nostrvault.service.NostrService
import com.nostrvault.service.ZapSendService
import com.nostrvault.ui.components.ZapFlight
import com.nostrvault.ui.theme.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray

/**
 * Posts tagged with any of a set of hashtags (`#t`), newest first, live: the
 * subscription stays open so new posts arrive while the screen is up. Two
 * groups: the people you follow, then everyone else the shield lets through
 * (your Web of Trust, or everyone). Shared by the hashtag sheet (one tag) and
 * the Hashtags feed (every followed tag). Port of iOS `HashtagFeedModel`.
 */
abstract class HashtagNotesViewModel(
    protected val nostrService: NostrService,
    protected val configStore: ConfigStore,
    protected val feedService: FeedService,
    private val zapSendService: ZapSendService,
) : ViewModel() {

    companion object {
        private const val TAG = "HashtagFeed"
        private const val LIMIT = 100
        /** Per group, so a long read stays bounded. Live posts arrive at the top, so trimming drops the oldest. */
        private const val MAX_NOTES = 1500
        /** How many rows before a group's end its next older page starts loading. */
        private const val PAGE_AHEAD = 5
        /** Authors per REQ filter; relays reject very large filters (iOS `trustedAuthorsCap`). */
        const val AUTHORS_CAP = 500
        /** Hashtags per REQ; past this the rest are left out rather than the REQ refused. */
        const val MAX_TAGS = 100
        /** Never spin forever if every relay is slow or down. */
        private const val LOADING_TIMEOUT_MS = 8_000L
        /** A screening lookup gives up on relays that haven't answered by then. */
        private const val LOOKUP_TIMEOUT_MS = 6_000L

        /**
         * The `#t` values for [tags]: a relay matches tag values exactly, and
         * not every client lowercases (NIP-24 asks it to), so each tag goes out
         * as lowercase, Capitalized and UPPERCASE. At most [MAX_TAGS] tags.
         */
        fun tagFilterValues(tags: List<String>): List<String> = tags
            .map(InterestList::normalize)
            .filter { it.isNotEmpty() }
            .distinct()
            .take(MAX_TAGS)
            .flatMap { listOf(it, it.replaceFirstChar { c -> c.uppercaseChar() }, it.uppercase()) }
            .distinct()
    }

    protected val json = Json { ignoreUnknownKeys = true }

    private val _fromFollows = MutableStateFlow<List<FeedNote>>(emptyList())
    val fromFollows: StateFlow<List<FeedNote>> = _fromFollows.asStateFlow()

    private val _fromOthers = MutableStateFlow<List<FeedNote>>(emptyList())
    val fromOthers: StateFlow<List<FeedNote>> = _fromOthers.asStateFlow()

    private val _isLoading = MutableStateFlow(true)
    val isLoading: StateFlow<Boolean> = _isLoading.asStateFlow()

    enum class Section { FOLLOWS, OTHERS }

    /** The group whose older page is on its way, for the spinner under it. */
    private val _loadingOlder = MutableStateFlow<Section?>(null)
    val loadingOlder: StateFlow<Section?> = _loadingOlder.asStateFlow()

    /** The app-wide shield: Web of Trust (false) or everyone (true). */
    val globalShowsEveryone: StateFlow<Boolean> = configStore.config
        .map { it.globalShowsEveryone }
        .stateIn(viewModelScope, SharingStarted.Eagerly, configStore.config.value.globalShowsEveryone)

    val profiles = nostrService.profiles
    val likedEventIds = feedService.likedEventIds
    val repostedEventIds = feedService.repostedEventIds
    val noteStats = feedService.noteStats
    val quotedNotesCache = feedService.quotedNotes

    private val _toast = MutableStateFlow<String?>(null)
    val toast = _toast.asStateFlow()

    val hasAccount: StateFlow<Boolean> = configStore.activeAccountHexPubkey
        .map { it.isNotEmpty() }
        .stateIn(viewModelScope, SharingStarted.Eagerly, configStore.activeAccountHexPubkey.value.isNotEmpty())

    private val lock = Any()
    private val seen = HashSet<String>()
    @Volatile private var follows: Set<String> = emptySet()
    /**
     * Who fills the top group: your follows under the shield, nobody with
     * Everyone. Everyone is one list by time; with follows on top, a busy
     * follow list buried everyone else and the shield seemed to do nothing.
     */
    @Volatile private var topGroup: Set<String> = emptySet()
    private val requestedAuthors = HashSet<String>()
    @Volatile private var generation = 0
    private var clients = mutableListOf<WebSocketClient>()
    private var jobs = mutableListOf<Job>()
    private var currentTags: List<String> = emptyList()
    /** What the posts on hand were loaded for; see [start]. */
    private var shownTags: List<String>? = null
    private var shownTrust: Set<String>? = null
    private var observing: Job? = null
    /** What `start` asked for, kept so an older page asks the same of each group. */
    private var followsFilters: List<JsonObject> = emptyList()
    private var othersFilters: List<JsonObject> = emptyList()
    private var pageContext: PageContext? = null
    private val exhausted = HashSet<Section>()
    private var pageClients = mutableListOf<WebSocketClient>()
    private var pageJobs = mutableListOf<Job>()
    @Volatile private var page = 0

    private class PageContext(
        val values: List<String>,
        val wantedTags: Set<String>,
        val wantedAuthors: Set<String>?,
        val blocked: Set<String>,
        val relays: List<String>,
    )

    /**
     * Loads [tags] while [active], again whenever the tags, the follow list,
     * the trust graph or the shield change. Called from a subclass's init,
     * once its own properties exist.
     */
    /**
     * Following nobody means no Web of Trust to filter by. The Hashtags feed
     * then opens to everyone and says so: it is where a new account finds its
     * first people. The single-tag sheet keeps failing closed.
     */
    protected open val opensWithoutWebOfTrust: Boolean = false

    /**
     * True while this feed is open to everyone because there's no Web of
     * Trust yet. Those posts are screened for bots and farms
     * ([TopicFeedScreener]) rather than shown raw, and in that order: posts
     * people responded to first.
     */
    private val _unfilteredForNewAccount = MutableStateFlow(false)
    val unfilteredForNewAccount: StateFlow<Boolean> = _unfilteredForNewAccount.asStateFlow()

    /**
     * Once the open list is being screened it stays screened while this
     * model lives: the empty web of trust is rebuilt every 2 minutes, and the
     * moment the guide's follows gave it names, flipping to the network feed
     * wiped the list under the reader (iOS `screenLatched`).
     */
    private var screenLatched = false
    @Volatile private var screening = false
    private val screener = TopicFeedScreener(
        scope = viewModelScope,
        query = ::lookupQuery,
        isValid = HavenBridge::verifyEvent,
        onShown = { notes ->
            _fromOthers.value = notes
            if (notes.isNotEmpty()) _isLoading.value = false
            nostrService.fetchMissingProfiles(notes.map { it.pubkey }.distinct())
        },
        onPass = ::endLoadingIfScreened,
    )

    /** A relay has finished its first page. Screened, that alone isn't the
     *  end of loading: the posts on hand wait for their authors' follow
     *  counts, and an empty list until then is not "no posts". */
    @Volatile private var firstPageDone = false
    /** The generation whose first page is in, so an old feed's EOSE landing
     *  just after a restart can't end the new feed's loading. */
    @Volatile private var firstPageGen = -1

    private fun endLoadingIfScreened() {
        if (firstPageDone && firstPageGen == generation && screener.isSettled()) _isLoading.value = false
    }

    protected fun observe(tags: Flow<List<String>>, active: Flow<Boolean> = flowOf(true)) {
        observing?.cancel()
        observing = viewModelScope.launch {
            combine(
                tags.distinctUntilChanged(),
                active.distinctUntilChanged(),
                feedService.followedPubkeys,
                combine(
                    feedService.wotPubkeys.map { it.size }.distinctUntilChanged(),
                    feedService.wotCacheRead,
                ) { size, read -> size to read },
                globalShowsEveryone,
            ) { t, on, _, _, _ -> t to on }
                .collect { (t, on) -> if (on) start(t) else stop() }
        }
    }

    /** Leaving the Web of Trust goes through the screen's warning first. */
    fun setGlobalShowsEveryone(on: Boolean) {
        feedService.setGlobalShowsEveryone(on)
    }

    /** Pull to refresh: the same tags, asked again. */
    fun reload() = start(currentTags)

    /**
     * (Re)opens the subscription. Your own posts count with your follows: you
     * just tagged it, you want to see it.
     */
    private fun start(tags: List<String>) {
        stop()
        currentTags = tags
        val followSet = buildSet {
            addAll(feedService.followedPubkeys.value)
            configStore.activeAccountHexPubkey.value.takeIf { it.isNotEmpty() }?.let(::add)
        }
        // Null is everyone; empty is nobody (no Web of Trust yet fails closed, like Global).
        val everyone = globalShowsEveryone.value
        val unfiltered = opensWithoutWebOfTrust && !everyone && feedService.hasNoWebOfTrustYet()
        if (unfiltered) screenLatched = true
        if (everyone) screenLatched = false
        val screen = !everyone && (unfiltered || screenLatched)
        _unfilteredForNewAccount.value = screen
        val trust = if (screen) null else feedService.globalTrustSet()
        val values = tagFilterValues(tags)
        // Matched locally in lowercase; only the tags actually asked for.
        val wantedTags = values.map { it.lowercase() }.toSet()
        // Same feed as last time (back from a note): keep the posts so the
        // list, and the scroll position on it, survive; the reopened
        // subscription only adds what is new.
        // Screened (Fill your feed), follows don't change what's shown: a
        // follow from the guide must not wipe and reload the list under the
        // reader.
        val switchingScreen = screen != screening
        val sameFollows = followSet == follows || (screen && trust == null)
        val resuming = !switchingScreen && tags == shownTags && sameFollows && trust == shownTrust &&
            (_fromFollows.value.isNotEmpty() || _fromOthers.value.isNotEmpty())
        shownTags = tags
        shownTrust = trust
        val gen = synchronized(lock) {
            generation += 1
            // After the bump, so a post from the old subscription can't reach the new pool.
            screening = screen
            if (!resuming) screener.reset()
            if (!resuming) seen.clear()
            follows = followSet
            topGroup = if (trust == null) emptySet() else followSet
            if (!resuming) exhausted.clear()
            generation
        }
        // Rebuilt below; a resumed list keeps what it learned about its end.
        followsFilters = emptyList()
        othersFilters = emptyList()
        pageContext = null
        if (!resuming) {
            _fromFollows.value = emptyList()
            _fromOthers.value = emptyList()
            _isLoading.value = true
            firstPageDone = false
        }
        // stop() dropped any lookups in flight; ask again for what's on hand.
        if (resuming && screen) screener.resume()

        if (values.isEmpty()) {
            _isLoading.value = false
            return
        }
        // Follows asked by name, so a busy tag cannot push them out of the page;
        // past the cap, the open filter finds them. Capped so the REQ stays
        // under relay message limits.
        if (followSet.isNotEmpty()) followsFilters = listOf(hashtagFilter(values, followSet.sorted().take(AUTHORS_CAP)))
        val others = trust?.minus(followSet)
        othersFilters = when {
            // Trusted authors by name, then open for those past the cap (iOS `trustScopedFilters`).
            !others.isNullOrEmpty() -> listOf(
                hashtagFilter(values, others.sorted().take(AUTHORS_CAP)),
                hashtagFilter(values, null),
            )
            trust == null || followSet.size > AUTHORS_CAP -> listOf(hashtagFilter(values, null))
            else -> emptyList()
        }
        val filters = followsFilters + othersFilters
        if (filters.isEmpty()) {
            _isLoading.value = false
            return
        }
        val wantedAuthors = trust?.let { it + followSet }
        val blocked = configStore.config.value.blockedForActiveAccount()
            .mapNotNull { nostrService.npubToHex(it) }
            .toSet()
        val relays = configStore.config.value.readRelays
        pageContext = PageContext(values, wantedTags, wantedAuthors, blocked, relays)

        val subId = "hashtag-${System.currentTimeMillis().toString(36)}"
        val req = buildJsonArray {
            add(JsonPrimitive("REQ"))
            add(JsonPrimitive(subId))
            filters.forEach { add(it) }
        }.toString()

        for (url in relays) {
            val client = WebSocketClient(url, viewModelScope)
            clients += client
            jobs += viewModelScope.launch(Dispatchers.Default) {
                client.messages.collect { raw -> onMessage(raw, subId, gen, blocked, wantedAuthors, wantedTags) }
            }
            // Sent again after a reconnect, so the feed stays live.
            jobs += viewModelScope.launch {
                client.connectionState.collect { state ->
                    if (state == WebSocketClient.ConnectionState.CONNECTED) client.send(req)
                }
            }
            client.connect()
        }
        jobs += viewModelScope.launch {
            delay(LOADING_TIMEOUT_MS)
            if (gen == generation) _isLoading.value = false
        }
    }

    private fun hashtagFilter(
        values: List<String>,
        authors: List<String>?,
        until: Long? = null,
    ): JsonObject = buildJsonObject {
        putJsonArray("kinds") { add(JsonPrimitive(1)) }
        putJsonArray("#t") { values.forEach { add(JsonPrimitive(it)) } }
        put("limit", LIMIT)
        if (authors != null) putJsonArray("authors") { authors.forEach { add(JsonPrimitive(it)) } }
        if (until != null) put("until", until)
    }

    private fun stop() {
        screener.stop()
        jobs.forEach { it.cancel() }
        jobs.clear()
        clients.forEach { it.disconnect() }
        clients.clear()
        stopPage()
    }

    private fun stopPage() {
        pageJobs.forEach { it.cancel() }
        pageJobs.clear()
        pageClients.forEach { it.disconnect() }
        pageClients.clear()
        _loadingOlder.value = null
    }

    /**
     * Call as each row shows. Near the end of its group, loads that group's
     * next older page. Older posts only ever join the group being read, at its
     * end, so nothing above the reader moves: an older post from someone you
     * follow, found while paging the second group, waits for the first
     * group's own page.
     */
    fun rowAppeared(noteId: String, section: Section) {
        val list = if (section == Section.FOLLOWS) _fromFollows.value else _fromOthers.value
        val index = list.indexOfLast { it.id == noteId }
        if (index < 0 || index < list.size - PAGE_AHEAD) return
        loadOlder(section)
    }

    /** The last card of a group showed (Threaded layout, where rows are conversations). */
    fun reachedEnd(section: Section) = loadOlder(section)

    private fun loadOlder(section: Section) {
        val base = if (section == Section.FOLLOWS) followsFilters else othersFilters
        val context = pageContext ?: return
        // Screened, the oldest post asked for is in the pool, not the list.
        val oldest = when {
            section == Section.FOLLOWS -> _fromFollows.value.lastOrNull()
            screening -> screener.oldest()
            else -> _fromOthers.value.lastOrNull()
        } ?: return
        if (_loadingOlder.value != null || section in exhausted || base.isEmpty()) return
        // Inclusive, so posts sharing the oldest second are not skipped; seen drops repeats.
        val until = oldest.createdAt.time / 1000
        val filters = base.map { filter ->
            buildJsonObject {
                filter.forEach { (k, v) -> if (k != "until") put(k, v) }
                put("until", until)
            }
        }
        val gen = generation
        page += 1
        val thisPage = page
        _loadingOlder.value = section
        val subId = "hashtag-older-${System.currentTimeMillis().toString(36)}"
        val req = buildJsonArray {
            add(JsonPrimitive("REQ"))
            add(JsonPrimitive(subId))
            filters.forEach { add(it) }
        }.toString()
        var added = 0
        val pending = HashSet(context.relays)
        fun finish() {
            synchronized(lock) {
                if (gen != generation || thisPage != page || _loadingOlder.value == null) return
                if (added == 0) exhausted.add(section)
            }
            viewModelScope.launch { if (thisPage == page) stopPage() }
        }
        for (url in context.relays) {
            val client = WebSocketClient(url, viewModelScope)
            pageClients += client
            pageJobs += viewModelScope.launch(Dispatchers.Default) {
                client.messages.collect { raw ->
                    if (gen != generation || thisPage != page) return@collect
                    val array = try {
                        json.parseToJsonElement(raw) as? JsonArray
                    } catch (e: Exception) {
                        null
                    } ?: return@collect
                    if (array.size < 2 || array[1].jsonPrimitive.contentOrNull != subId) return@collect
                    when (array[0].jsonPrimitive.contentOrNull) {
                        "EOSE" -> {
                            val done = synchronized(lock) { pending.remove(url); pending.isEmpty() }
                            if (done) finish()
                        }
                        "EVENT" -> {
                            val event = array.getOrNull(2) as? JsonObject ?: return@collect
                            val note = parseNote(event, context.blocked, context.wantedAuthors, context.wantedTags)
                                ?: return@collect
                            if (insertOlder(note, section, gen)) synchronized(lock) { added += 1 }
                        }
                    }
                }
            }
            pageJobs += viewModelScope.launch {
                client.connectionState.collect { state ->
                    if (state == WebSocketClient.ConnectionState.CONNECTED) client.send(req)
                }
            }
            client.connect()
        }
        // A relay that never answers must not hold the next page forever.
        pageJobs += viewModelScope.launch {
            delay(LOADING_TIMEOUT_MS)
            finish()
        }
    }

    /** An older page's post, kept only if it belongs to the group being paged. */
    private fun insertOlder(note: FeedNote, section: Section, gen: Int): Boolean {
        // Same split as [insert]: with the shield off there is one list.
        val noteSection = if (note.pubkey in topGroup) Section.FOLLOWS else Section.OTHERS
        return noteSection == section && insert(note, gen)
    }

    override fun onCleared() {
        stop()
        super.onCleared()
    }

    /**
     * One REQ to the feed relays for the screener. Returns when every relay
     * has answered (EOSE or CLOSED, counted per relay) or after
     * [LOOKUP_TIMEOUT_MS]; its sockets close then. Only verified events.
     * True when every relay answered, false when it timed out.
     */
    private suspend fun lookupQuery(filters: List<JsonObject>, onEvent: (JsonObject) -> Unit): Boolean {
        val relays = configStore.config.value.readRelays
        if (relays.isEmpty() || filters.isEmpty()) return true
        val subId = "screen-${System.nanoTime().toString(36)}"
        val req = buildJsonArray {
            add(JsonPrimitive("REQ"))
            add(JsonPrimitive(subId))
            filters.forEach { add(it) }
        }.toString()
        val answered = HashSet<String>()
        val done = kotlinx.coroutines.CompletableDeferred<Unit>()
        val clients = mutableListOf<WebSocketClient>()
        val lookupJobs = mutableListOf<Job>()
        return try {
            coroutineScope {
                for (url in relays) {
                    // Big buffer: a responder lookup can return thousands of frames,
                    // and a dropped EOSE would hold it to the timeout.
                    val client = WebSocketClient(url, viewModelScope, autoReconnect = false, messageBuffer = 4096)
                    clients += client
                    lookupJobs += launch(Dispatchers.Default) {
                        client.messages.collect { raw ->
                            val array = try {
                                json.parseToJsonElement(raw) as? JsonArray
                            } catch (e: Exception) {
                                null
                            } ?: return@collect
                            if (array.size < 2 || (array[1] as? JsonPrimitive)?.contentOrNull != subId) return@collect
                            when ((array[0] as? JsonPrimitive)?.contentOrNull) {
                                "EVENT" -> {
                                    val event = array.getOrNull(2) as? JsonObject ?: return@collect
                                    if (HavenBridge.verifyEvent(event.toString())) onEvent(event)
                                }
                                "EOSE", "CLOSED" -> {
                                    val all = synchronized(answered) { answered.add(url); answered.size >= relays.size }
                                    if (all) done.complete(Unit)
                                }
                            }
                        }
                    }
                    lookupJobs += launch {
                        client.connectionState.first { it == WebSocketClient.ConnectionState.CONNECTED }
                        client.send(req)
                    }
                    client.connect()
                }
                val allAnswered = withTimeoutOrNull(LOOKUP_TIMEOUT_MS) { done.await() } != null
                lookupJobs.forEach { it.cancel() }
                allAnswered
            }
        } finally {
            clients.forEach { it.disconnect() }
        }
    }

    /**
     * Runs off Main. Only what was asked for: a relay can send validly signed
     * posts that lack the tag, or come from people outside the requested
     * authors, and any event under any author, so every signature is checked.
     */
    private fun onMessage(
        raw: String,
        subId: String,
        gen: Int,
        blocked: Set<String>,
        authors: Set<String>?,
        wantedTags: Set<String>,
    ) {
        val array = try {
            json.parseToJsonElement(raw) as? JsonArray
        } catch (e: Exception) {
            Log.w(TAG, "unparseable relay message: ${e.message}")
            null
        } ?: return
        if (array.size < 2 || array[1].jsonPrimitive.contentOrNull != subId) return
        when (array[0].jsonPrimitive.contentOrNull) {
            "EOSE" -> if (gen == generation) {
                firstPageGen = gen
                firstPageDone = true
                if (screening) endLoadingIfScreened() else _isLoading.value = false
            }
            "EVENT" -> {
                val event = array.getOrNull(2) as? JsonObject ?: return
                val note = parseNote(event, blocked, authors, wantedTags) ?: return
                insert(note, gen)
            }
        }
    }

    private fun parseNote(
        event: JsonObject,
        blocked: Set<String>,
        authors: Set<String>?,
        wantedTags: Set<String>,
    ): FeedNote? = try {
        val id = event["id"]?.jsonPrimitive?.contentOrNull
        val pubkey = event["pubkey"]?.jsonPrimitive?.contentOrNull
        val content = event["content"]?.jsonPrimitive?.contentOrNull
        val createdAt = event["created_at"]?.jsonPrimitive?.longOrNull
        val kind = event["kind"]?.jsonPrimitive?.contentOrNull?.toIntOrNull()
        val tags = event["tags"]?.jsonArray?.map { t -> t.jsonArray.map { it.jsonPrimitive.contentOrNull.orEmpty() } }
        if (id == null || pubkey == null || content == null || createdAt == null || kind != 1 || tags == null) {
            null
        } else if (authors != null && pubkey !in authors) {
            null
        } else if (tags.none { it.size >= 2 && it[0] == "t" && it[1].lowercase() in wantedTags }) {
            null
        } else if (FeedNote.isNoiseOrSpam(content, tags)) {
            null
        } else {
            val note = FeedNote.fromEvent(id, pubkey, content, tags, createdAt, kind)
            note.takeIf {
                !FeedFilterEngine.involvesBlocked(it, blocked) { ref -> feedService.findNote(ref)?.pubkey } &&
                    HavenBridge.verifyEvent(event.toString())
            }
        }
    } catch (e: Exception) {
        Log.w(TAG, "unusable event: ${e.message}")
        null
    }

    /** True when the post was new and went into its group. */
    private fun insert(note: FeedNote, gen: Int): Boolean {
        val updated = synchronized(lock) {
            if (gen != generation || !seen.add(note.id)) return false
            if (screening && note.pubkey !in topGroup) {
                screener.add(note)
                return true
            }
            val target = if (note.pubkey in topGroup) _fromFollows else _fromOthers
            val current = target.value
            val index = current.indexOfFirst { it.createdAt < note.createdAt }.let { if (it < 0) current.size else it }
            val list = current.toMutableList().apply { add(index, note) }
            val capped = if (list.size > MAX_NOTES) list.subList(0, MAX_NOTES).toList() else list
            target.value = capped
            _isLoading.value = false
            requestedAuthors.add(note.pubkey)
        }
        if (updated) nostrService.fetchMissingProfiles(listOf(note.pubkey))
        return true
    }

    // ── Engagement (same services as the feed, search and profile) ────────

    fun clearToast() { _toast.value = null }

    /** Your own notes have no trust path, so they get no Web of Trust button. */
    fun isOwnNote(pubkey: String): Boolean = pubkey == nostrService.activeHexPubkey

    /** The avatar quick menu: Follow/Unfollow and Block (iOS FeedView avatar toolbar). */
    val avatarMenu = com.nostrvault.ui.components.avatarMenuActions(feedService, ::isOwnNote)

    fun likeNote(noteId: String) {
        viewModelScope.launch { feedService.likeNote(noteId) }
    }

    fun repostNote(noteId: String) {
        viewModelScope.launch { feedService.repostNote(noteId) }
    }

    fun zapNote(noteId: String, notePubkey: String) {
        viewModelScope.launch {
            // The Wallet default, same figure the feed and profile use.
            val sats = configStore.config.value.defaultZapAmount.coerceAtLeast(1)
            val result = zapSendService.zapNote(noteId, notePubkey, sats)
            _toast.value = result.fold(
                onSuccess = {
                    ZapFlight.launch(noteId)
                    "Zapped $sats sats"
                },
                onFailure = { "Zap failed: ${it.message ?: "unknown error"}" },
            )
        }
    }

    fun quotedNoteFor(identifier: String): FeedNote? = feedService.quotedNoteFor(identifier)

    fun fetchMissingQuotedNotes(identifiers: List<String>) =
        feedService.fetchMissingQuotedNotes(identifiers)

    fun fetchMissingQuotedProfiles(identifiers: List<String>) =
        feedService.fetchMissingQuotedProfiles(identifiers)
}
