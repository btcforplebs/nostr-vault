package com.nostrvault.ui.components

import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.ime
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import com.nostrvault.relay.HavenBridge
import com.nostrvault.service.NostrService
import com.nostrvault.tutorials.TutorialContent
import com.nostrvault.tutorials.tutorialAnchor
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.data.model.ContactList
import com.nostrvault.data.model.TrustMap
import com.nostrvault.data.model.TrustPath
import com.nostrvault.data.model.WotNewcomers
import com.nostrvault.data.model.WotRefreshProgress
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.NostrVaultIcons
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.text.NumberFormat
import kotlin.math.max
import kotlin.math.min

/** Deep space behind the globe: dark whatever the app's appearance. */
private val SpaceTop = Color(red = 0.07f, green = 0.08f, blue = 0.13f)
internal val SpaceBrush = Brush.radialGradient(listOf(SpaceTop, Color.Black), radius = 2400f)

/** The globe's warm accent (iOS system orange) and the author's ring (yellow). */
internal val GlobeAccent = Color(0xFFFF9F0A)
internal val AuthorTint = Color(0xFFFFD60A)
internal val RingColor = Color(red = 0.72f, green = 0.82f, blue = 1f)
internal val HazeColor = Color(red = 0.62f, green = 0.55f, blue = 0.9f)
/** Warm amber for the threads, lighter than the glow behind them. */
internal val ThreadColor = Color(red = 1f, green = 0.66f, blue = 0.3f)

/** Bridges drawn as faces; the rest stay bright stars. */
internal const val MAX_FACES = 12

@Composable
internal fun TrustWebContent(
    author: String,
    path: TrustPath,
    onProfileClick: ((String) -> Unit)?,
    /** Null in the WOT tab, which has nothing to close. */
    onDismiss: (() -> Unit)?,
    isWOTTab: Boolean = false,
    onMessage: ((String) -> Unit)? = null,
    reselects: kotlinx.coroutines.flow.Flow<*>? = null,
    bottomInset: androidx.compose.ui.unit.Dp = 0.dp,
) {
    val services = rememberTrustPathServices()
    val trust = services.trustPathService()
    val nostrService = services.nostrService()
    val profiles by nostrService.profiles.collectAsState()
    val accent = LocalNostrVaultColors.current.primary
    val scope = rememberCoroutineScope()
    val appContext = androidx.compose.ui.platform.LocalContext.current.applicationContext
    val lite = remember { isLiteGlobe(appContext) }

    val me = remember { trust.me }
    var myFollows by remember { mutableStateOf(trust.myFollows().toSet()) }
    var crumbs by remember { mutableStateOf(listOf(me)) }
    var frames by remember { mutableStateOf(mapOf(me to TrustFrame(me, trust.myFollows(), true, path))) }
    /** The faint outer shell around you: your web of trust past your follows. */
    var haze by remember { mutableStateOf(emptyList<String>()) }
    var peek by remember { mutableStateOf<String?>(null) }
    // Per person, so re-centering mid-load neither blocks nor mislabels the
    // next person's globe.
    var loadingMore by remember { mutableStateOf(emptySet<String>()) }
    var lookingDeeper by remember { mutableStateOf(emptySet<String>()) }
    // No relay answered: offer a retry instead of a final answer.
    var failed by remember { mutableStateOf(emptySet<String>()) }
    var deeperFailed by remember { mutableStateOf(emptySet<String>()) }
    var showingList by remember { mutableStateOf(false) }
    /** Your whole trust graph, for the search's "In your web" tag. */
    var web by remember { mutableStateOf(emptySet<String>()) }
    /**
     * How many of your follows follow each person past them (the relay's
     * vouches), and who of the drawn shell is Close. Null on an old cache.
     */
    var vouches by remember { mutableStateOf<Map<String, Int>?>(null) }
    var closeHaze by remember { mutableStateOf(emptySet<String>()) }
    /**
     * The WOT tab's Close and Further out faces: the people past your
     * follows worth a profile fetch ([TrustMap.layerFaceCandidates]).
     */
    var layerCandidates by remember { mutableStateOf(emptyMap<TrustMap.Layer, List<String>>()) }
    // An empty follow list means "not in yet" until a load has finished.
    val loadingFollows by trust.isLoadingFollows.collectAsState()
    val followsAttempted by trust.followsAttempted.collectAsState()
    // Nothing says when the trust graph has been tried, so its pill gives up
    // after a while rather than spin all session for an empty web.
    var webWaitOver by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { delay(WEB_WAIT_MS); webWaitOver = true }
    /** The refresh button's run; null when idle. */
    var refreshState by remember { mutableStateOf<RefreshState?>(null) }
    /** The WOT tab's layer picker: which part of your web is lit. */
    var layer by remember { mutableStateOf(TrustMap.Layer.EVERYONE) }
    /** The WOT tab's search field is open under the bar. */
    var searchOpen by remember { mutableStateOf(false) }
    /**
     * People who joined your web since you last looked, for the
     * "↑ N new people" pill; [webSeen] is the count they're measured from.
     */
    var newPeople by remember { mutableIntStateOf(0) }
    var webSeen by remember { mutableStateOf<Int?>(null) }
    /**
     * A relay rebuild seen running from the WOT tab: the people it has found
     * so far who weren't on the old map, lit as stars while it runs, and how
     * many of its newcomers the pill was tapped away at. [liveCounted] holds
     * from its first report until its pill folds away.
     */
    var liveRebuild by remember { mutableStateOf(false) }
    var arrivals by remember { mutableStateOf(emptySet<String>()) }
    var arrivalsDismissed by remember { mutableIntStateOf(0) }
    var liveCounted by remember { mutableStateOf(false) }
    /**
     * The WOT tab's trust card: who was tapped or searched, and how they
     * reach you (null while it's being traced).
     */
    var card by remember { mutableStateOf<String?>(null) }
    var cardPath by remember { mutableStateOf<TrustPath?>(null) }
    val feedService = services.feedService()

    val centerKey = crumbs.last()
    val frame = frames[centerKey]
    /** Your follows are in but the wider web around them isn't yet. */
    val mappingWeb = centerKey == me && frame != null && frame.ring.isNotEmpty() && haze.isEmpty() &&
        web.isEmpty() && !webWaitOver

    fun name(pubkey: String): String =
        if (pubkey == me) "You" else profiles[pubkey]?.bestName ?: "npub…${pubkey.takeLast(6)}"

    val trustGraphUpdate by trust.trustGraphUpdates.collectAsState()

    LaunchedEffect(Unit) {
        nostrService.fetchMissingProfiles(listOf(me, author) + path.bridges)
    }

    // Again when the trust graph lands: on a cold start it's still loading, and
    // a haze computed then stays empty all session.
    LaunchedEffect(trustGraphUpdate, myFollows, arrivals) {
        val graph = trust.myTrustGraph() + arrivals
        val inner = myFollows + me + author
        val counts = trust.myVouches()
        val shell = withContext(Dispatchers.Default) { TrustMap.haze(graph - inner, cap = if (lite) TrustMap.HAZE_CAP_LITE else TrustMap.HAZE_CAP) }
        if (isWOTTab) {
            val follows = myFollows
            layerCandidates = withContext(Dispatchers.Default) {
                listOf(TrustMap.Layer.CLOSE, TrustMap.Layer.FURTHER_OUT).associateWith {
                    TrustMap.layerFaceCandidates(it, me, follows, graph, counts)
                }
            }
        }
        closeHaze = counts?.let { v -> shell.filterTo(HashSet()) { (v[it] ?: 0) >= TrustMap.CLOSE_VOUCHES } }.orEmpty()
        haze = shell
        web = graph
        vouches = counts
        if (layer !in TrustMap.layers(counts != null)) layer = TrustMap.Layer.EVERYONE
    }

    // The web grew: count the newcomers into the pill, which folds away a few
    // seconds after the last one arrives. The first count is the start.
    LaunchedEffect(web.size) {
        if (!isWOTTab) return@LaunchedEffect
        val seen = webSeen
        webSeen = web.size
        // A rebuild the relay reports on counts its own newcomers, live; the
        // saved web landing afterwards is the same people again.
        if (liveCounted) return@LaunchedEffect
        if (seen == null || web.size <= seen) return@LaunchedEffect
        newPeople += web.size - seen
        delay(NEW_PEOPLE_SHOWN_MS)
        newPeople = 0
    }

    // Follows the relay's rebuilds while the WOT tab is open, whoever started
    // them (the daily timer, the boot check or the dropdown): newcomers fade in
    // as stars and count up in the pill, and the saved web loads when the
    // rebuild ends. Mirrors iOS.
    LaunchedEffect(isWOTTab) {
        if (!isWOTTab) return@LaunchedEffect
        // A fold cut short by leaving the tab would leave the pill muted.
        if (!liveRebuild) liveCounted = false
        var cursor = 0
        var fade: kotlinx.coroutines.Job? = null
        while (true) {
            val progress = withContext(Dispatchers.IO) {
                WotRefreshProgress.parse(runCatching { HavenBridge.getWotRefreshProgress() }.getOrNull())
            }
            if (progress?.running == true) {
                if (!liveRebuild) {
                    liveRebuild = true
                    liveCounted = true
                    fade?.cancel()
                    cursor = 0
                    arrivals = emptySet()
                    arrivalsDismissed = 0
                }
                val from = cursor
                // Throws on a library from before the call existed.
                val batch = withContext(Dispatchers.IO) {
                    WotNewcomers.parse(runCatching { HavenBridge.getWotNewcomers(from) }.getOrNull())
                }
                if (batch != null) {
                    cursor = batch.total
                    if (batch.pubkeys.isNotEmpty()) arrivals = arrivals + batch.pubkeys
                }
                newPeople = max(0, (progress.new ?: arrivals.size) - arrivalsDismissed)
            } else if (liveRebuild) {
                liveRebuild = false
                cursor = 0
                // Saved: the new map has everyone that lit up. Stopped: the
                // old one stays, and the stars that came in fade back out.
                arrivals = emptySet()
                trust.reloadTrustGraph()
                fade = launch {
                    delay(NEW_PEOPLE_SHOWN_MS)
                    newPeople = 0
                    liveCounted = false
                }
            }
            delay(if (liveRebuild) LIVE_POLL_MS else IDLE_POLL_MS)
        }
    }

    // With the author in the middle there are no bridges, so the ring gets
    // the faces: on your own globe, the people you interact with most.
    var engagement by remember { mutableStateOf(emptyMap<String, Int>()) }
    LaunchedEffect(Unit) { engagement = trust.engagement() }
    val ringCandidates = remember(frame?.center, frame?.ring, engagement) {
        if (frame != null && frame.center == author) {
            TrustMap.faceCandidates(frame.ring, if (author == me) engagement else emptyMap())
        } else emptyList()
    }
    LaunchedEffect(ringCandidates) {
        if (ringCandidates.isNotEmpty()) nostrService.fetchMissingProfiles(ringCandidates)
    }
    // Only pictures that loaded become faces ("pubkey url" keys), taken in
    // once a second so the globe settles a few times, not sixteen.
    var renderedPictures by remember { mutableStateOf(emptySet<String>()) }
    suspend fun loadPictures(candidates: List<String>) = coroutineScope {
        val asked = HashSet<String>()
        val loaded = java.util.Collections.synchronizedSet(HashSet<String>())
        repeat(PICTURE_WAIT_TICKS) {
            for (pubkey in candidates) {
                val url = nostrService.profiles.value[pubkey]?.pictureURL?.takeIf { it.isNotBlank() } ?: continue
                val key = "$pubkey $url"
                if (key in renderedPictures || !asked.add(key)) continue
                launch { if (avatarRenders(appContext, url)) loaded += key }
            }
            delay(1_000)
            val batch = synchronized(loaded) { loaded.toSet().also { loaded.clear() } }
            if (batch.isNotEmpty()) renderedPictures = renderedPictures + batch
        }
    }
    LaunchedEffect(ringCandidates) { loadPictures(ringCandidates) }
    fun pictureRenders(pubkey: String): Boolean =
        profiles[pubkey]?.pictureURL?.let { "$pubkey $it" in renderedPictures } == true
    val ringFaces = remember(ringCandidates, renderedPictures) {
        TrustMap.pickFaces(ringCandidates, ::pictureRenders, if (lite) TrustMap.RING_FACES_LITE else TrustMap.RING_FACES)
    }
    // The picked layer's faces (Close or Further out), fetched on each pick:
    // the picture loader stops after a while and profiles can arrive late.
    val pickedLayerCandidates = layerCandidates[layer].orEmpty()
    LaunchedEffect(layer, pickedLayerCandidates) {
        if (pickedLayerCandidates.isEmpty()) return@LaunchedEffect
        nostrService.fetchMissingProfiles(pickedLayerCandidates)
        loadPictures(pickedLayerCandidates)
    }
    /** Pictures on the outer shell for the picked layer, most vouched first; only ones that loaded. */
    val layerFaces = remember(isWOTTab, centerKey, pickedLayerCandidates, renderedPictures) {
        if (!isWOTTab || centerKey != me) emptyList()
        else TrustMap.pickFaces(pickedLayerCandidates, ::pictureRenders,
            if (lite) TrustMap.RING_FACES_LITE else TrustMap.LAYER_FACES)
    }

    fun jump(index: Int) {
        if (index >= crumbs.size - 1) return
        peek = null
        crumbs = crumbs.take(index + 1)
    }

    fun openCard(pubkey: String) {
        peek = null
        card = pubkey
        cardPath = null
        nostrService.fetchMissingProfiles(listOf(pubkey))
        scope.launch {
            // From you, whoever is in the middle: which of your follows follow them.
            val found = trust.path(pubkey)
            if (card != pubkey) return@launch
            nostrService.fetchMissingProfiles(found.bridges)
            cardPath = found
        }
    }

    fun closeCard() {
        card = null
        cardPath = null
    }

    /** [pubkey] in the middle with everyone they follow around them, one step further along the trail. */
    fun center(pubkey: String) {
        val index = crumbs.indexOf(pubkey)
        if (index >= 0) return jump(index)
        crumbs = crumbs + pubkey
        if (frames[pubkey] != null) return
        scope.launch {
            val list = trust.followList(pubkey)
            val ring = list.orEmpty()
            val found = trust.path(author, pubkey, ring)
            frames = frames + (pubkey to TrustFrame(pubkey, ring, list != null, found))
            nostrService.fetchMissingProfiles(listOf(pubkey) + found.bridges)
        }
    }

    fun tapped(pubkey: String) {
        // The WOT tab answers "can I trust them?" in a card; only the card's
        // "See their web" moves the globe.
        if (isWOTTab) return if (pubkey == me || pubkey == card) closeCard() else openCard(pubkey)
        if (peek != null) { peek = null; return }
        // The one in the middle: say who they are rather than go nowhere.
        if (pubkey == crumbs.last()) {
            if (pubkey != me) peek = pubkey
            return
        }
        center(pubkey)
    }

    /**
     * "Show everyone": batches of 20 lists until no relay has more, lighting
     * stars as each batch lands. Stops at [TrustMap.MAX_BATCHED_LISTS] a tap.
     */
    fun showEveryone() {
        val key = frame?.center ?: return
        if (key in loadingMore) return
        loadingMore = loadingMore + key
        failed = failed - key
        scope.launch {
            var fetched = 0
            while (true) {
                val current = frames[key] ?: break
                if (current.exhausted || fetched >= TrustMap.MAX_BATCHED_LISTS) break
                val lists: List<ContactList>? = trust.moreBridgeLists(author, current.ring, current.seen)
                if (lists == null) {
                    failed = failed + key
                    break
                }
                val latest = frames[key] ?: break
                fetched += lists.size
                val fresh = TrustPath.allBridges(author, key, current.ringSet, lists)
                frames = frames + (key to latest.copy(
                    seen = latest.seen + lists.map { it.pubkey },
                    bridges = (latest.bridges + fresh).distinct().sorted(),
                    exhausted = lists.isEmpty(),
                ))
            }
            frames[key]?.bridges?.let { nostrService.fetchMissingProfiles(TrustMap.spread(it, MAX_FACES)) }
            loadingMore = loadingMore - key
        }
    }

    fun lookDeeper() {
        val start = frames[crumbs.last()] ?: return
        val key = start.center
        if (key in lookingDeeper) return
        lookingDeeper = lookingDeeper + key
        deeperFailed = deeperFailed - key
        scope.launch {
            val graph = if (key == me) trust.myTrustGraph() else emptySet()
            val chains = trust.deeperChains(author, key, start.ring, graph)
            if (chains != null) {
                frames[key]?.let { frames = frames + (key to it.copy(chains = chains)) }
                nostrService.fetchMissingProfiles(chains.take(TrustMap.SHOWN_CHAINS).flatMap { listOf(it.bridge, it.via) })
            } else {
                deeperFailed = deeperFailed + key
            }
            lookingDeeper = lookingDeeper - key
        }
    }

    fun openProfile(pubkey: String) {
        peek = null
        showingList = false
        onProfileClick?.invoke(pubkey)
    }

    // ── Search (WOT tab only) ──
    var query by remember { mutableStateOf("") }
    var searchFocused by remember { mutableStateOf(false) }
    var searchingRelays by remember { mutableStateOf(false) }
    val focusManager = LocalFocusManager.current
    val keyboard = LocalSoftwareKeyboardController.current
    val pasted = remember(query) { TrustMap.pastedKey(query, HavenBridge::decodeNpub) }
    val hits = remember(query, pasted, profiles, myFollows, web) {
        if (pasted != null) {
            listOf(TrustMap.PersonHit(pasted, when (pasted) {
                in myFollows -> TrustMap.Tier.FOLLOW
                in web -> TrustMap.Tier.WEB
                else -> TrustMap.Tier.OTHER
            }))
        } else {
            TrustMap.searchPeople(query, profiles.values, myFollows, web)
        }
    }

    if (isWOTTab) {
        // Names not cached yet come from the relays. Their profiles land in
        // the cache, so the local ranking above just runs again; nothing here
        // reads the results.
        LaunchedEffect(query) {
            val text = query.trim()
            if (text.isEmpty()) {
                nostrService.cancelGlobalSearch(NostrService.SearchCaller.WOT)
                searchingRelays = false
                return@LaunchedEffect
            }
            if (pasted != null) {
                nostrService.cancelGlobalSearch(NostrService.SearchCaller.WOT)
                searchingRelays = false
                nostrService.fetchMissingProfiles(listOf(pasted))
                return@LaunchedEffect
            }
            delay(SEARCH_DEBOUNCE_MS)
            searchingRelays = true
            nostrService.globalSearch(text, NostrService.SearchCaller.WOT) { searchingRelays = false }
        }
        androidx.compose.runtime.DisposableEffect(Unit) {
            onDispose { nostrService.cancelGlobalSearch(NostrService.SearchCaller.WOT) }
        }
    }

    fun clearSearch() {
        query = ""
        focusManager.clearFocus()
        keyboard?.hide()
    }

    /** A search row: back to you, then off to them as if their face was tapped. */
    fun pick(pubkey: String) {
        clearSearch()
        if (isWOTTab) {
            searchOpen = false
            return if (pubkey == me) closeCard() else openCard(pubkey)
        }
        jump(0)
        tapped(pubkey)
    }

    if (isWOTTab) {
        // The tab lives on, so it follows your follow list as it loads or
        // changes, in place, so you stay wherever you'd gone on the globe.
        LaunchedEffect(Unit) {
            trust.followUpdates.collect { follows ->
                val set = follows.toSet()
                if (set == myFollows) return@collect
                myFollows = set
                // Keep what the globe had already found around you.
                frames = frames + (me to (frames[me]?.withRing(follows) ?: TrustFrame(me, follows, true, path)))
            }
        }
        // Tapping the tab again brings the globe back to you.
        LaunchedEffect(reselects) {
            reselects?.collect {
                peek = null
                showingList = false
                clearSearch()
                searchOpen = false
                closeCard()
                jump(0)
            }
        }
    }

    // Back steps along the breadcrumbs before it closes the globe.
    BackHandler(enabled = crumbs.size > 1) { jump(crumbs.size - 2) }
    // Registered after the crumbs' handler, so it goes first: a search in
    // progress is cleared before back moves the globe.
    BackHandler(enabled = isWOTTab && (searchFocused || query.isNotEmpty())) { clearSearch() }

    val rootRingEmpty = isWOTTab && centerKey == me && frame != null && frame.ring.isEmpty()
    val followsPending = rootRingEmpty && (loadingFollows || !followsAttempted)

    /**
     * The WOT tab's refresh: your follow list, then the relay rebuilds your
     * wider web, then the ring's pictures. Each step runs even if the one
     * before came back empty or failed, since each can still help on its own.
     * The bar fills one unit a step, out of [REFRESH_STEPS]. Mirrors iOS.
     */
    fun refresh() {
        if (refreshState != null) return
        refreshState = RefreshState(0f, "Updating your follows…")
        scope.launch {
            try {
                try {
                    trust.refreshFollows()
                } catch (e: kotlinx.coroutines.CancellationException) {
                    throw e
                } catch (_: Exception) {
                }

                refreshState = RefreshState(1f, "Rebuilding your web…")
                // Whether the relay saved a new web: the bar ends on "Up to
                // date" only then, else on why not (iOS rebuildWeb).
                var saved = false
                // False when the relay isn't up; throws on a library from before the call existed.
                val started = withContext(Dispatchers.IO) { runCatching { HavenBridge.refreshWot() }.getOrDefault(false) }
                if (!started) {
                    refreshState = RefreshState(1f, "Relay isn't running. Showing your last saved web.")
                    delay(RELAY_DOWN_HOLD_MS)
                } else {
                    var finished = false
                    val rebuildStart = System.nanoTime()
                    // The creep restarts at each new phase and each finished
                    // batch, so the bar never sits on the next batch's mark.
                    var step: Pair<String, Int>? = null
                    var phaseStarted = rebuildStart
                    fun seconds(since: Long) = (System.nanoTime() - since) / 1e9
                    for (poll in 0 until MAX_WOT_POLLS) {
                        val progress = withContext(Dispatchers.IO) {
                            WotRefreshProgress.parse(runCatching { HavenBridge.getWotRefreshProgress() }.getOrNull())
                        }
                        if (progress != null) {
                            val now = progress.phase to progress.batchesDone
                            if (now != step) {
                                step = now
                                phaseStarted = System.nanoTime()
                            }
                            refreshState = RefreshState(
                                1f + progress.fraction(seconds(phaseStarted)).toFloat(),
                                progress.caption(seconds(rebuildStart).toLong()),
                            )
                            if (!progress.running) {
                                saved = progress.phase == "saved"
                                finished = true
                                break
                            }
                        }
                        delay(WOT_POLL_MS)
                    }
                    if (!finished) {
                        refreshState = RefreshState(1f, "The rebuild is taking too long. Showing your last saved web.")
                    }
                }
                val outcome = refreshState?.caption.orEmpty()
                // The rebuild saved a new graph: read it in, and the haze
                // follows through trustGraphUpdates. Give it a moment to land.
                trust.reloadTrustGraph()
                kotlinx.coroutines.withTimeoutOrNull(TRUST_GRAPH_WAIT_MS) { trust.trustGraphUpdates.drop(1).first() }

                refreshState = RefreshState(2f, "Loading profile pictures…")
                val scores = trust.engagement()
                engagement = scores
                nostrService.fetchMissingProfiles(listOf(me) + TrustMap.faceCandidates(trust.myFollows(), scores), force = true)
                refreshState = RefreshState(REFRESH_STEPS.toFloat(), if (saved) "Up to date" else outcome, failed = !saved)
                // A failure stays up long enough to read.
                delay(if (saved) REFRESH_DONE_HOLD_MS else REFRESH_FAILED_HOLD_MS)
            } finally {
                refreshState = null
            }
        }
    }

    val explainer = explainer(frame, me, author, centerKey, ::name, myFollows,
        lookingDeeper = frame?.center in lookingDeeper, deeperFailed = frame?.center in deeperFailed, accent = accent,
        noFollows = rootRingEmpty && !followsPending)

    @Composable
    fun crumbRow(modifier: Modifier) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
            modifier = modifier.horizontalScroll(rememberScrollState()).padding(horizontal = 16.dp),
        ) {
            crumbs.forEachIndexed { index, pubkey ->
                if (index > 0) CrumbArrow()
                val on = index == crumbs.size - 1
                Chip(pubkey, name(pubkey), profiles[pubkey], on = on, destination = false, accent = accent,
                    onClick = if (on) null else ({ jump(index) }))
            }
            if (centerKey != author) {
                CrumbArrow()
                Chip(author, name(author), profiles[author], on = false, destination = true, accent = accent, onClick = null)
            }
        }
    }

    @Composable
    fun legend() {
        if (frame == null || !frame.listFound) return
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            LegendDot(RingColor)
            Text(
                "${NumberFormat.getIntegerInstance().format(frame.ring.size)} " +
                    if (frame.center == me) "you follow" else "${name(frame.center)} follows",
                color = SecondaryText, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f, fill = false),
            )
            Spacer(Modifier.weight(1f).widthIn(min = 8.dp))
            if (frame.bridges.isNotEmpty()) {
                LegendDot(GlobeAccent)
                Text("${countText(frame)} follow ${name(author)}", color = accent, fontSize = 12.sp, maxLines = 1,
                    overflow = TextOverflow.Ellipsis)
            }
        }
    }

    @Composable
    fun actions() {
        if (frame != null && frame.listFound) {
            when {
                frame.center in deeperFailed -> FooterButton("Try again", accent, filled = false, onClick = ::lookDeeper)
                frame.center in lookingDeeper ->
                    FooterButton("Looking further out…", accent, filled = false, loading = true, onClick = {})
                canLookDeeper(frame, author) -> FooterButton("Look deeper", accent, filled = false, onClick = ::lookDeeper)
                canLoadMore(frame) -> {
                    val loading = frame.center in loadingMore
                    FooterButton(
                        title = when {
                            loading -> "Finding more… ${frame.bridges.size} so far"
                            frame.center in failed -> "Couldn't reach the relays. Try again"
                            else -> "Show everyone who follows ${name(author)}"
                        },
                        accent = accent,
                        filled = false,
                        loading = loading,
                        onClick = ::showEveryone,
                    )
                }
            }
        }
        if (centerKey != me && onProfileClick != null) {
            FooterButton("View ${name(centerKey)}'s profile", accent, filled = true) { openProfile(centerKey) }
        }
    }

    @Composable
    fun globeArea(
        modifier: Modifier,
        /** Off on the WOT tab, where the globe runs to the screen's edges. */
        clip: Boolean = true,
        /** Keeps the pills and the peek card clear of the floating tab bar. */
        overlayPadding: PaddingValues = PaddingValues(0.dp),
    ) {
        Box(if (clip) modifier.clipToBounds() else modifier) {
            TrustGlobe(
                frame = frame, center = centerKey, me = me, author = author, myFollows = myFollows, haze = haze,
                closeHaze = closeHaze,
                lite = lite,
                ringFaces = ringFaces,
                layerFaces = layerFaces,
                running = !showingList,
                layer = if (isWOTTab && centerKey == me) layer else TrustMap.Layer.EVERYONE,
                summary = summary(frame, me, author, centerKey, ::name),
                profiles = profiles, name = ::name,
                onTap = ::tapped,
                // A tap on open space also puts the keyboard away.
                focus = if (isWOTTab) card else null,
                focusBridges = if (isWOTTab) cardPath?.all.orEmpty() else emptyList(),
                onEmptyTap = { peek = null; closeCard(); if (searchFocused) focusManager.clearFocus() },
            )
            // The WoT tutorial's first card points at the middle of the
            // globe, you and the faces nearest you. The whole globe is nearly
            // the screen's height, which leaves the card no room beside it.
            if (isWOTTab) {
                Box(
                    Modifier.align(Alignment.Center).fillMaxSize(0.6f).aspectRatio(1f)
                        .tutorialAnchor(TutorialContent.WOT_GLOBE),
                )
            }
            Box(Modifier.matchParentSize().padding(overlayPadding)) {
            when {
                // Someone tapped, their follow list still on its way.
                frame == null -> StatusPill(
                    text = "Loading ${name(centerKey)}'s follows…",
                    pubkey = centerKey, profile = profiles[centerKey], accent = accent,
                    modifier = Modifier.align(Alignment.Center),
                )
                followsPending -> StatusPill(
                    text = "Loading your follows…", accent = accent,
                    modifier = Modifier.align(Alignment.Center),
                )
                // Your follows are in but the wider web (the haze) isn't yet.
                // The WOT tab says so in its live pill instead.
                !isWOTTab && mappingWeb ->
                    StatusPill(
                        text = "Mapping your wider web…", accent = accent, small = true,
                        modifier = Modifier.align(Alignment.BottomCenter).padding(bottom = 12.dp),
                    )
            }
            peek?.let { pubkey ->
                val followsAuthor = frame?.bridges?.contains(pubkey) == true ||
                    frame?.chains?.any { it.via == pubkey } == true
                PeekCard(
                    pubkey = pubkey, name = name(pubkey), profile = profiles[pubkey], accent = accent,
                    line = listOfNotNull(
                        when { pubkey == me -> "You"; pubkey in myFollows -> "You follow"; else -> "Not someone you follow" },
                        when {
                            pubkey == author -> null
                            followsAuthor -> "follows ${name(author)}"
                            else -> "not seen following ${name(author)}"
                        },
                    ).joinToString(" · "),
                    onProfile = onProfileClick?.let { { openProfile(pubkey) } },
                    modifier = Modifier.align(Alignment.BottomStart),
                )
            }
            val shown = card
            if (isWOTTab && shown != null) {
                val following = shown in myFollows
                var blocked by remember(shown) { mutableStateOf(feedService.isBlocked(shown)) }
                TrustCard(
                    pubkey = shown,
                    name = ::name,
                    profiles = profiles,
                    path = cardPath,
                    following = following,
                    blocked = blocked,
                    accent = accent,
                    onClose = ::closeCard,
                    onFollow = { if (following) feedService.unfollowPubkey(shown) else feedService.followPubkey(shown) },
                    onMessage = onMessage?.let { { it(shown) } },
                    onProfile = onProfileClick?.let { { openProfile(shown) } },
                    // Already in the middle: there's no further web to move to.
                    onSeeWeb = if (shown == centerKey) null else { { closeCard(); center(shown) } },
                    onBlock = {
                        if (blocked) feedService.unblockUser(shown) else { feedService.blockUser(shown); closeCard() }
                        blocked = !blocked
                    },
                    modifier = Modifier.align(Alignment.BottomCenter),
                )
            }
            }
        }
    }

    if (isWOTTab) {
        // Full bleed, like the feed: space runs under the status bar and the
        // floating tab bar, and the bar's glass pills sit over it (iOS WOT bar).
        val counts = remember(myFollows, web, vouches) { TrustMap.layerCounts(me, myFollows, web, vouches) }
        Box(Modifier.fillMaxSize()) {
            globeArea(Modifier.fillMaxSize(), clip = false, overlayPadding = PaddingValues(bottom = bottomInset))
            Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(8.dp),
                modifier = Modifier
                    .fillMaxSize()
                    .windowInsetsPadding(WindowInsets.safeDrawing.only(WindowInsetsSides.Top + WindowInsetsSides.Horizontal)),
            ) {
                WotTopBar(
                    layer = layer,
                    layers = TrustMap.layers(vouches != null),
                    counts = counts,
                    onLayer = { layer = it },
                    refreshing = refreshState != null,
                    onRebuild = ::refresh,
                    searchOpen = searchOpen,
                    onSearch = {
                        if (searchOpen) clearSearch()
                        else { peek = null; closeCard() }
                        searchOpen = !searchOpen
                    },
                    showingList = showingList,
                    onGlobe = { showingList = false },
                    onList = { showingList = true },
                )
                if (searchOpen) {
                    val focus = remember { FocusRequester() }
                    LaunchedEffect(Unit) { focus.requestFocus() }
                    SearchField(
                        query = query,
                        onQueryChange = { query = it },
                        onFocusChange = { searchFocused = it },
                        onSearch = { keyboard?.hide() },
                        onClear = ::clearSearch,
                        accent = accent,
                        modifier = Modifier.focusRequester(focus),
                    )
                    if (query.isNotBlank()) {
                        // Above the keyboard when it's up, else above the tab bar.
                        val ime = WindowInsets.ime.asPaddingValues().calculateBottomPadding()
                        SearchResults(
                            query = query.trim(),
                            hits = hits,
                            searching = searchingRelays && pasted == null,
                            profiles = profiles,
                            name = ::name,
                            accent = accent,
                            onPick = ::pick,
                            modifier = Modifier
                                .weight(1f, fill = false)
                                .padding(bottom = maxOf(ime, bottomInset) + 8.dp),
                        )
                    }
                }
                if (crumbs.size > 1) crumbRow(Modifier.fillMaxWidth())
                WotLivePill(
                    caption = when {
                        // The Rebuild button's steps, then how it ended (iOS).
                        refreshState != null -> refreshState?.caption
                        liveRebuild -> "Rebuilding your web"
                        mappingWeb -> "Mapping your web"
                        else -> null
                    },
                    outcome = refreshState?.takeIf { it.done }?.let { if (it.failed) WotPillOutcome.Failed else WotPillOutcome.Saved },
                    newPeople = newPeople,
                    onClick = {
                        if (liveRebuild) arrivalsDismissed += newPeople
                        newPeople = 0
                    },
                )
            }
        }
    } else Column(Modifier.fillMaxSize().safeDrawingPadding()) {
        TopBar(
            title = if (centerKey == me) "Web of Trust" else name(centerKey),
            onDone = onDismiss,
            onList = { showingList = true },
        )
        Box(Modifier.weight(1f).fillMaxWidth()) {
        BoxWithConstraints(Modifier.fillMaxSize()) {
            if (maxWidth >= WIDE_WIDTH) {
                // Tablets: the globe takes the screen and the words move to a side panel.
                Row(Modifier.fillMaxSize()) {
                    Box(Modifier.weight(1f).fillMaxHeight()) {
                        globeArea(Modifier.fillMaxSize())
                        crumbRow(Modifier.align(Alignment.TopStart).padding(top = 12.dp))
                    }
                    Column(
                        verticalArrangement = Arrangement.spacedBy(16.dp),
                        modifier = Modifier
                            .width(360.dp)
                            .fillMaxHeight()
                            .background(Color.Black.copy(alpha = 0.35f))
                            .padding(24.dp),
                    ) {
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                            val profile = profiles[author]
                            AvatarImage(url = profile?.pictureURL, pubkey = author, size = 48.dp, displayName = profile?.bestName)
                            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                                Text(name(author), color = PrimaryText, fontSize = 19.sp, fontWeight = FontWeight.SemiBold,
                                    maxLines = 1, overflow = TextOverflow.Ellipsis)
                                Text(if (centerKey == me) "How you're connected" else "How ${name(centerKey)} is connected",
                                    color = SecondaryText, fontSize = 13.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                            }
                        }
                        Text(explainer, color = PrimaryText.copy(alpha = 0.85f), fontSize = 15.sp)
                        legend()
                        actions()
                        Box(Modifier.fillMaxWidth().height(1.dp).background(Color.White.copy(alpha = 0.12f)))
                        if (frame != null && frame.bridges.isNotEmpty()) {
                            Text("FOLLOWED BY", color = SecondaryText, fontSize = 12.sp, fontWeight = FontWeight.SemiBold,
                                letterSpacing = 1.2.sp)
                            LazyColumn(Modifier.weight(1f)) {
                                items(frame.bridges, key = { it }) { pubkey ->
                                    Row(
                                        verticalAlignment = Alignment.CenterVertically,
                                        horizontalArrangement = Arrangement.spacedBy(12.dp),
                                        modifier = Modifier
                                            .fillMaxWidth()
                                            .clickable(onClickLabel = "Move them to the middle of the globe") { tapped(pubkey) }
                                            .padding(vertical = 5.dp)
                                            .semantics(mergeDescendants = true) { },
                                    ) {
                                        val profile = profiles[pubkey]
                                        AvatarImage(url = profile?.pictureURL, pubkey = pubkey, size = 32.dp, displayName = profile?.bestName)
                                        Text(name(pubkey), color = PrimaryText, fontSize = 15.sp, maxLines = 1,
                                            overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
                                        Icon(NostrVaultIcons.Navigate, contentDescription = null, tint = SecondaryText,
                                            modifier = Modifier.size(16.dp))
                                    }
                                }
                            }
                        } else {
                            Spacer(Modifier.weight(1f))
                        }
                        Text(
                            "Drag to spin · pinch to zoom · tap a face to follow their path · double-tap to reset",
                            color = SecondaryText, fontSize = 11.sp, modifier = Modifier.clearAndSetSemantics { },
                        )
                    }
                }
            } else {
                Column(Modifier.fillMaxSize()) {
                    crumbRow(Modifier.padding(top = 8.dp))
                    globeArea(Modifier.weight(1f).fillMaxWidth())
                    Column(
                        verticalArrangement = Arrangement.spacedBy(10.dp),
                        modifier = Modifier.fillMaxWidth().padding(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 12.dp),
                    ) {
                        Text(explainer, color = PrimaryText.copy(alpha = 0.85f), fontSize = 14.sp)
                        legend()
                        actions()
                    }
                }
            }
        }
        }
    }

    if (showingList && isWOTTab) {
        val listed = remember(layer, myFollows, web, vouches) { TrustMap.layerPeople(layer, me, myFollows, web, vouches) }
        WotPeopleList(
            card = card, cardPath = cardPath, layer = layer, listed = listed, myFollows = myFollows,
            vouches = vouches, profiles = profiles, accent = accent, name = ::name,
            onSeen = { nostrService.fetchMissingProfiles(listOf(it)) },
            onOpen = { pubkey -> showingList = false; openCard(pubkey) },
            onDismiss = { showingList = false },
        )
    } else if (showingList && frame != null) {
        PeopleList(
            frame = frame, me = me, author = author, profiles = profiles, name = ::name,
            onOpen = onProfileClick?.let { { pubkey: String -> openProfile(pubkey) } },
            onDismiss = { showingList = false },
        )
    }
}

/** Past this width (tablets) the globe takes the screen and the words move to a side panel. */
private val WIDE_WIDTH = 760.dp

/** Read once per globe: [TrustMap.isLite] from this phone's memory. */
private fun isLiteGlobe(context: android.content.Context): Boolean {
    val am = context.getSystemService(android.content.Context.ACTIVITY_SERVICE) as? android.app.ActivityManager
        ?: return false
    val info = android.app.ActivityManager.MemoryInfo().also(am::getMemoryInfo)
    return TrustMap.isLite(info.totalMem, am.isLowRamDevice)
}
/** Typing pauses this long before the relays are asked. */
private const val SEARCH_DEBOUNCE_MS = 350L
/** "Mapping your wider web…" gives up after this; an empty web may just be empty. */
private const val WEB_WAIT_MS = 15_000L
/** How long the "↑ N new people" pill stays after the last newcomer. */
private const val NEW_PEOPLE_SHOWN_MS = 5_000L
/** Seconds the globe keeps taking in faces' pictures as profiles arrive. */
private const val PICTURE_WAIT_TICKS = 20
/** Refresh: follows, web, pictures. */
private const val REFRESH_STEPS = 3
/** How long refresh waits for the trust graph to be read off disk. */
private const val TRUST_GRAPH_WAIT_MS = 1_500L
/** The full bar holds this long before it fades, so the end reads as done. */
private const val REFRESH_DONE_HOLD_MS = 700L
/** A refresh that didn't save a new web holds its reason this long. */
private const val REFRESH_FAILED_HOLD_MS = 3_500L
/** "Relay isn't running" stays up this long before refresh goes on. */
private const val RELAY_DOWN_HOLD_MS = 1_500L
/** The relay's rebuild is polled this often, at most [MAX_WOT_POLLS] times (6 minutes). */
private const val WOT_POLL_MS = 500L
private const val MAX_WOT_POLLS = 720

/** The WOT tab checks on the relay's rebuild this often while one runs, and this often while none does. */
private const val LIVE_POLL_MS = 1_000L
private const val IDLE_POLL_MS = 5_000L

/**
 * Where a refresh is: [fill] out of [REFRESH_STEPS], and what it's doing.
 * [failed] once a finished run didn't save a new web.
 */
private data class RefreshState(val fill: Float, val caption: String, val failed: Boolean = false) {
    val done: Boolean get() = fill >= REFRESH_STEPS
}
