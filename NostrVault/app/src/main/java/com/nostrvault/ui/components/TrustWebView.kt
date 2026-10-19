package com.nostrvault.ui.components

import androidx.activity.compose.BackHandler
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import com.nostrvault.relay.HavenBridge
import com.nostrvault.service.NostrService
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.only
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import com.nostrvault.ui.navigation.FloatingButtonRow
import com.nostrvault.ui.navigation.WotOpenRequest
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.data.model.ContactList
import com.nostrvault.data.model.TrustMap
import com.nostrvault.data.model.TrustMapWider
import com.nostrvault.data.model.TrustPath
import com.nostrvault.data.model.WotNewcomers
import com.nostrvault.data.model.WotRefreshProgress
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.PrimaryText
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

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
    // Per person, so re-centering mid-load neither blocks nor mislabels the
    // next person's globe.
    // No relay answered: offer a retry instead of a final answer.
    var showingList by remember { mutableStateOf(false) }
    var myWebOpen by remember { mutableStateOf(false) }
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
    /** Whose wider web is on its way, for the loading pill. */
    var widerLoading by remember { mutableStateOf(emptySet<String>()) }
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
     * A relay rebuild seen running from the WOT tab, and the people it has
     * found so far who weren't on the old map, lit as stars while it runs.
     */
    var liveRebuild by remember { mutableStateOf(false) }
    var arrivals by remember { mutableStateOf(emptySet<String>()) }
    /**
     * The trust card: who was tapped or searched, and how they reach you
     * (null while it's being traced). Live, so Follow on the card shows on it.
     */
    var card by remember { mutableStateOf<String?>(null) }
    /** The author's path seen from you, traced again whenever your web changes. */
    val authorPath = rememberLiveTrustPath(author.takeIf { it != me })
    // The author's own card shares it rather than trace them twice.
    val tracedCard = rememberLiveTrustPath(card.takeIf { it != author })
    val cardPath = if (card != null && card == author) authorPath else tracedCard
    val feedService = services.feedService()
    // Live arrivals on the WOT tab's globe: the bar's antenna and its switches.
    val liveArcs = rememberLiveArcsState()
    val globeArrivals = remember(feedService) { GlobeArrivalStream(feedService) }

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
        // The popup opens on the author's card, as on iOS.
        if (!isWOTTab && author != me) card = author
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
                listOf(TrustMap.Layer.EVERYONE, TrustMap.Layer.CLOSE, TrustMap.Layer.FURTHER_OUT).associateWith {
                    TrustMap.layerFaceCandidates(it, me, follows, graph, counts, globeFaces(TrustMap.faceCandidateCount(it)))
                }
            }
        }
        // Close by vouches over the haze and every layer's faces alike.
        val faces = layerCandidates.values.flatten()
        closeHaze = withContext(Dispatchers.Default) { TrustMap.closeByVouches(shell + faces, counts) }
        haze = shell
        web = graph
        vouches = counts
        if (layer !in TrustMap.layers(counts != null)) layer = TrustMap.Layer.EVERYONE
    }

    // Follows the relay's rebuilds while the WOT tab is open, whoever started
    // them (the daily timer, the boot check or the dropdown): newcomers fade in
    // as stars, and the saved web loads when the rebuild ends. Mirrors iOS.
    LaunchedEffect(isWOTTab) {
        if (!isWOTTab) return@LaunchedEffect
        var cursor = 0
        while (true) {
            val progress = withContext(Dispatchers.IO) {
                WotRefreshProgress.parse(runCatching { HavenBridge.getWotRefreshProgress() }.getOrNull())
            }
            if (progress?.running == true) {
                if (!liveRebuild) {
                    liveRebuild = true
                    cursor = 0
                    arrivals = emptySet()
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
            } else if (liveRebuild) {
                liveRebuild = false
                cursor = 0
                // Saved: the new map has everyone that lit up. Stopped: the
                // old one stays, and the stars that came in fade back out.
                arrivals = emptySet()
                trust.reloadTrustGraph()
            }
            delay(if (liveRebuild) LIVE_POLL_MS else IDLE_POLL_MS)
        }
    }

    // The ring gets the faces left over from the paths: with the author in
    // the middle there are none, and anyone else in the middle gets faces as
    // you do on your own globe. Who you talk with first, on anyone's globe.
    // Your own globe opened for someone else keeps to the paths to them.
    var engagement by remember { mutableStateOf(emptyMap<String, Int>()) }
    LaunchedEffect(Unit) { engagement = trust.engagement() }
    val ringCandidates = remember(frame?.center, frame?.ring, engagement) {
        if (frame != null && (frame.center == author || frame.center != me)) {
            TrustMap.faceCandidates(frame.ring, engagement, globeFaces(TrustMap.FACE_CANDIDATES))
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
    // ── Filters (WOT tab only) ──
    val wotFilters = rememberWotFilters(me, WotFilterInputs(myFollows, web, engagement))
    val filterLit = if (isWOTTab) wotFilters.lit else null
    /** The picked layer as a lit set, for someone else's globe: it still lights your part of their web. */
    val layerLit = remember(layer, myFollows, web, vouches) { TrustMapWider.layerLit(layer, me, myFollows, web, vouches) }
    /**
     * Who the globe leaves lit. Yours: the filters (the layer dims by shell).
     * Someone else's: the filters and the layer, both still about you, so you
     * can see who in their web is close to you.
     */
    val globeLit = if (centerKey == me) filterLit else TrustMapWider.globeLit(filterLit, layerLit)
    /** Matching people worth a picture, most interacted with first. */
    val filterCandidates = remember(filterLit, myFollows, engagement, vouches) {
        filterFaceCandidates(filterLit, myFollows, engagement, vouches, globeFaces(TrustMap.LAYER_FACES) * 3)
    }
    LaunchedEffect(filterCandidates) {
        if (filterCandidates.isEmpty()) return@LaunchedEffect
        nostrService.fetchMissingProfiles(filterCandidates)
        loadPictures(filterCandidates)
    }
    val ringFaces = remember(ringCandidates, renderedPictures, globeLit) {
        // With a filter on, only people it lights get a face.
        TrustMap.pickFaces(ringCandidates, { (globeLit == null || it in globeLit) && pictureRenders(it) },
            if (lite) TrustMap.RING_FACES_LITE else globeFaces(TrustMap.RING_FACES))
    }
    // The picked layer's faces past your follows, fetched on each pick:
    // the picture loader stops after a while and profiles can arrive late.
    val pickedLayerCandidates = layerCandidates[layer].orEmpty()
    LaunchedEffect(layer, pickedLayerCandidates) {
        if (pickedLayerCandidates.isEmpty()) return@LaunchedEffect
        nostrService.fetchMissingProfiles(pickedLayerCandidates)
        loadPictures(pickedLayerCandidates)
    }
    /** Pictures past your follows for the picked layer, most vouched first: a few for Everyone, many for Vouched or Further out. Only ones that loaded. */
    val layerFaces = remember(isWOTTab, centerKey, layer, pickedLayerCandidates, renderedPictures, filterLit, filterCandidates) {
        if (!isWOTTab || centerKey != me) emptyList()
        // A filter's people take the outer faces first, as long as the layer lights them.
        else if (filterLit != null) TrustMap.pickFaces(filterCandidates, ::pictureRenders,
            if (lite) TrustMap.RING_FACES_LITE else globeFaces(TrustMap.LAYER_FACES))
        else TrustMap.pickFaces(pickedLayerCandidates, ::pictureRenders,
            if (lite) minOf(TrustMap.faceCount(layer), TrustMap.RING_FACES_LITE) else globeFaces(TrustMap.faceCount(layer)))
    }
    // Someone else's globe: their wider web's most vouched as the outer faces.
    val widerCandidates = frame?.wider?.layerFaces?.get(TrustMap.Layer.EVERYONE).orEmpty()
    LaunchedEffect(centerKey, widerCandidates) {
        if (centerKey == me || widerCandidates.isEmpty()) return@LaunchedEffect
        nostrService.fetchMissingProfiles(widerCandidates)
        loadPictures(widerCandidates)
    }
    /** Faces past the core's follows: yours by layer on your globe, or on someone else's the most vouched of their web. */
    val outerFaces = remember(centerKey, layerFaces, widerCandidates, renderedPictures, globeLit) {
        if (centerKey == me) layerFaces
        else TrustMap.pickFaces(widerCandidates, { (globeLit == null || it in globeLit) && pictureRenders(it) },
            if (lite) minOf(TrustMap.EVERYONE_FACES, TrustMap.RING_FACES_LITE) else globeFaces(TrustMap.EVERYONE_FACES))
    }
    /** The haze is the core's own web: yours, or theirs once it loaded. */
    val globeHaze = if (centerKey == me) haze else frame?.wider?.shell.orEmpty()
    val globeCloseHaze = if (centerKey == me) closeHaze else frame?.wider?.close.orEmpty()

    fun jump(index: Int) {
        if (index >= crumbs.size - 1) return
        crumbs = crumbs.take(index + 1)
    }

    fun openCard(pubkey: String) {
        card = pubkey
        nostrService.fetchMissingProfiles(listOf(pubkey))
    }
    // From you, whoever is in the middle: which of your follows follow them.
    LaunchedEffect(cardPath) { cardPath?.let { nostrService.fetchMissingProfiles(it.bridges) } }

    fun closeCard() {
        card = null
    }

    /**
     * Their wider web, mapped from their follows' lists, as their globe's
     * haze and outer faces. Asked again on coming back to them if it failed.
     */
    fun loadWider(pubkey: String) {
        val ring = frames[pubkey]?.takeIf { it.wider == null }?.ring
        if (pubkey == me || ring.isNullOrEmpty() || pubkey in widerLoading) return
        widerLoading = widerLoading + pubkey
        val inner = ring.toSet() + pubkey + me + author
        scope.launch {
            try {
                val found = trust.widerWeb(pubkey, ring) ?: return@launch
                val layout = withContext(Dispatchers.Default) {
                    TrustMapWider.hazeLayout(found.graph, inner, found.vouches, pubkey, ring.toSet(), GLOBE_FACE_SCALE,
                        if (lite) TrustMap.HAZE_CAP_LITE else TrustMap.HAZE_CAP)
                }
                frames[pubkey]?.let { frames = frames + (pubkey to it.copy(wider = layout)) }
            } finally {
                widerLoading = widerLoading - pubkey
            }
        }
    }
    // Back onto someone: their web again if it failed.
    LaunchedEffect(centerKey) { if (centerKey != me) loadWider(centerKey) }

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
            loadWider(pubkey)
        }
    }

    fun tapped(pubkey: String) {
        // The globe answers "can I trust them?" in a card, in the WOT tab and
        // the popup alike; only the card's "See their web" moves the globe.
        if (pubkey == me || pubkey == card) closeCard() else openCard(pubkey)
    }

    fun openProfile(pubkey: String) {
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

    // Every globe, the tab and the popup alike, follows your follow list as it
    // loads or changes, in place, so you stay wherever you'd gone: someone you
    // follow from the card folds into your web at once.
    LaunchedEffect(Unit) {
        trust.followUpdates.collect { follows ->
            val set = follows.toSet()
            if (set == myFollows) return@collect
            myFollows = set
            // Keep what the globe had already found around you.
            frames = frames + (me to (frames[me]?.withRing(follows) ?: TrustFrame(me, follows, true, path)))
        }
    }
    // The author's path ([authorPath]) kept current the same way, so the
    // legend and threads stop saying "outside your web" after a follow.
    // The path this globe opened with is already fresh; only a change to your
    // follows since may replace it, so a trace whose relays timed out can't.
    val openedWith = remember { myFollows }
    LaunchedEffect(authorPath) {
        val live = authorPath ?: return@LaunchedEffect
        if (myFollows == openedWith) return@LaunchedEffect
        val root = frames[me] ?: return@LaunchedEffect
        if (root.path == live) return@LaunchedEffect
        frames = frames + (me to root.withPath(live, myFollows))
    }

    if (isWOTTab) {
        // Tapping the tab again brings the globe back to you.
        LaunchedEffect(reselects) {
            reselects?.collect {
                showingList = false
                clearSearch()
                searchOpen = false
                closeCard()
                jump(0)
            }
        }
    }

    if (isWOTTab) {
        // "Open in WoT" from a profile's or a post's globe: back to you, then
        // onto them, with anything open on the tab put away.
        LaunchedEffect(Unit) {
            WotOpenRequest.pending.collect {
                val pubkey = WotOpenRequest.take() ?: return@collect
                showingList = false
                clearSearch()
                searchOpen = false
                closeCard()
                myWebOpen = false
                jump(0)
                if (pubkey != me) center(pubkey)
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

    @Composable
    fun crumbRow(modifier: Modifier) {
        TrustWebViewBreadcrumbs(modifier, crumbs, centerKey, author, profiles, accent, ::name, ::jump)
    }

    @Composable
    fun globeArea(
        modifier: Modifier,
        clip: Boolean = true,
        overlayPadding: PaddingValues = PaddingValues(0.dp),
        cardAsSidePanel: Boolean = false,
    ) {
        TrustWebViewGlobe(
            modifier = modifier, clip = clip, overlayPadding = overlayPadding, cardAsSidePanel = cardAsSidePanel,
            frame = frame, centerKey = centerKey, me = me, author = author, myFollows = myFollows, haze = globeHaze,
            closeHaze = globeCloseHaze, lite = lite, ringFaces = ringFaces, layerFaces = outerFaces, filterLit = globeLit,
            showingList = showingList, isWOTTab = isWOTTab, layer = layer, profiles = profiles, name = ::name,
            tapped = ::tapped, card = card, cardPath = cardPath,
            onEmptyTap = { closeCard(); if (searchFocused) focusManager.clearFocus() },
            followsPending = followsPending, mappingWeb = mappingWeb, accent = accent,
            onProfileClick = onProfileClick, openProfile = ::openProfile, feedService = feedService,
            closeCard = ::closeCard, onMessage = onMessage, center = ::center,
            live = if (isWOTTab && liveArcs.on) LiveArcsRequest(me, liveArcs.rings, liveArcs.show, globeArrivals) else null,
            mappingWider = centerKey in widerLoading,
            // A profile's or a post's globe makes way for the WOT tab's.
            onOpenInWot = if (isWOTTab) null else { pubkey -> WotOpenRequest.open(pubkey); onDismiss?.invoke() },
        )
    }

    if (isWOTTab) {
        // Full bleed, like the feed: space runs under the status bar and the
        // floating tab bar, and the bar's glass pills sit over it (iOS WOT bar).
        val counts = remember(myFollows, web, vouches) { TrustMap.layerCounts(me, myFollows, web, vouches) }
        BoxWithConstraints(Modifier.fillMaxSize()) {
            val sidePanel = wotCardIsSidePanel(maxWidth)
            globeArea(
                Modifier.fillMaxSize(), clip = false, overlayPadding = PaddingValues(bottom = bottomInset),
                cardAsSidePanel = sidePanel,
            )
            // The side-panel card owns the trailing edge; the bar centres in what is left.
            Box(Modifier.fillMaxSize().padding(end = if (sidePanel) SIDE_PANEL_WIDTH else 0.dp)) {
            TrustWebViewWOTTabBar(
                layer = layer,
                vouches = vouches,
                counts = counts,
                onLayer = { layer = it },
                refreshState = refreshState,
                onRebuild = ::refresh,
                searchOpen = searchOpen,
                onSearch = {
                    if (searchOpen) clearSearch()
                    else closeCard()
                    searchOpen = !searchOpen
                },
                onList = { showingList = true },
                search = {
                    TrustWebViewSearch(
                        query = query,
                        onQueryChange = { query = it },
                        onFocusChange = { searchFocused = it },
                        // Return opens the top match, as on iOS; nothing to open just puts the keyboard away.
                        onSearch = { hits.firstOrNull()?.let { pick(it.pubkey) } ?: keyboard?.hide() },
                        onClear = ::clearSearch,
                        accent = accent,
                        hits = hits,
                        searchingRelays = searchingRelays,
                        pasted = pasted,
                        profiles = profiles,
                        name = ::name,
                        onPick = ::pick,
                        bottomInset = bottomInset,
                    )
                },
                crumbs = crumbs,
                crumbRow = { crumbRow(it) },
                liveRebuild = liveRebuild,
                mappingWeb = mappingWeb,
                filters = wotFilters.on,
                onFilter = wotFilters::toggle,
                filterNote = wotFilters.note,
                liveArcs = liveArcs,
            )
            }
            // My Web, where other tabs have Post; it steps aside for a card, the list or search.
            if (card == null && !searchFocused && !showingList) MyWebButton(
                onClick = { closeCard(); myWebOpen = true },
                modifier = Modifier.align(Alignment.BottomEnd).padding(end = 20.dp, bottom = FloatingButtonRow.rowBottom),
            )
            if (myWebOpen) {
                val rebuilding = refreshState != null
                val rebuiltAgo = remember(rebuilding) { wotRebuiltAgo(feedService) }
                MyWebSheet(
                    numbers = MyWebNumbers(counts, vouches != null, layer, (myFollows - me).size, rebuilding, rebuiltAgo),
                    filters = wotFilters,
                    liveArcs = liveArcs,
                    onLayer = { jump(0); layer = it; myWebOpen = false },
                    onRebuild = ::refresh,
                    onDismiss = { myWebOpen = false },
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
        // A post's globe: the trust card does the explaining, as in the WOT tab,
        // so there are no words, legend or buttons under the globe (iOS).
        Column(Modifier.fillMaxSize()) {
            crumbRow(Modifier.padding(top = 8.dp))
            globeArea(Modifier.weight(1f).fillMaxWidth())
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

/** "3 hours ago" for when the relay last saved your web, or null before it ever has. */
private fun wotRebuiltAgo(feedService: com.nostrvault.service.FeedService): String? {
    val dir = feedService.configStore.config.value.relayDataDir ?: return null
    val modified = java.io.File(dir, com.nostrvault.service.FeedService.WOT_CACHE_FILE).lastModified()
    if (modified <= 0L) return null
    val now = System.currentTimeMillis()
    if (now - modified < android.text.format.DateUtils.MINUTE_IN_MILLIS) return "just now"
    return android.text.format.DateUtils.getRelativeTimeSpanString(
        modified, now, android.text.format.DateUtils.MINUTE_IN_MILLIS,
    ).toString()
}

/** Width of the docked trust card (iOS `AdaptiveLayout.sidePanelWidth`). */
internal val SIDE_PANEL_WIDTH = 360.dp

/** Room for a 360dp panel and a globe that is still the subject (iOS `cardIsSidePanel`, 900pt). */
internal fun wotCardIsSidePanel(paneWidth: Dp): Boolean = paneWidth >= 900.dp

/** Typing pauses this long before the relays are asked. */
private const val SEARCH_DEBOUNCE_MS = 350L
/** "Mapping your wider web…" gives up after this; an empty web may just be empty. */
private const val WEB_WAIT_MS = 15_000L
/** Seconds the globe keeps taking in faces' pictures as profiles arrive. */
private const val PICTURE_WAIT_TICKS = 20
