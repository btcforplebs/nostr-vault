package com.nostrvault.ui.components

import com.nostrvault.data.model.TrustPathText
import com.nostrvault.ui.theme.ErrorRed
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.ime
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import com.nostrvault.relay.HavenBridge
import com.nostrvault.service.NostrService
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.calculatePan
import androidx.compose.foundation.gestures.calculateZoom
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
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
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.BottomSheetDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.positionChanged
import androidx.compose.ui.input.pointer.util.VelocityTracker
import androidx.compose.ui.input.pointer.util.addPointerInputChange
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.TextMeasurer
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.currentStateAsState
import com.nostrvault.data.model.ContactList
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.data.model.GlobeCamera
import com.nostrvault.data.model.TrustMap
import com.nostrvault.data.model.TrustPath
import com.nostrvault.data.model.Vec3
import com.nostrvault.data.model.WotRefreshProgress
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.Motion
import com.nostrvault.ui.theme.NostrVaultIcons
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText
import com.nostrvault.ui.theme.Surface1
import com.nostrvault.ui.theme.Surface2
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.text.NumberFormat
import kotlin.math.abs
import kotlin.math.exp
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * One globe: who is at the core and what we know about their follows.
 */
private data class TrustFrame(
    val center: String,
    /** Everyone [center] follows: the stars on the inner sphere. */
    val ring: List<String>,
    /**
     * False when no relay had [center]'s follow list, so the empty sphere
     * means "unknown", not "follows no one".
     */
    val listFound: Boolean,
    val path: TrustPath,
    /** Every bridge found so far, sorted; starts as the card's 5. */
    val bridges: List<String> = path.bridges,
    /** Signers whose lists already came back, so a batch skips them. */
    val seen: Set<String> = path.bridges.toSet(),
    /**
     * Relays answered with nothing new: the count is the whole count. The card
     * asks for one more list than it shows, so no extra means it has everyone.
     */
    val exhausted: Boolean = !path.hasMore,
    /** 3-hop routes once "look deeper" ran; null before. */
    val chains: List<TrustMap.Chain>? = null,
    val ringSet: Set<String> = ring.toSet(),
)

/** Deep space behind the globe: dark whatever the app's appearance. */
private val SpaceTop = Color(red = 0.07f, green = 0.08f, blue = 0.13f)
private val SpaceBrush = Brush.radialGradient(listOf(SpaceTop, Color.Black), radius = 2400f)

/** The globe's warm accent (iOS system orange) and the author's ring (yellow). */
private val GlobeAccent = Color(0xFFFF9F0A)
private val AuthorTint = Color(0xFFFFD60A)
private val RingColor = Color(red = 0.72f, green = 0.82f, blue = 1f)
private val HazeColor = Color(red = 0.62f, green = 0.55f, blue = 0.9f)
/** Warm amber for the threads, lighter than the glow behind them. */
private val ThreadColor = Color(red = 1f, green = 0.66f, blue = 0.3f)

/** Bridges drawn as faces; the rest stay bright stars. */
private const val MAX_FACES = 12

/**
 * The Trust Path card opened up into a globe, full screen. Someone sits at the
 * core (you, at first) with everyone they follow as stars on a sphere around
 * them, people further out as a faint outer shell, and the author between the
 * two. Threads run from the core through each person who follows the author.
 * Each star's spot comes from its key ([TrustMap.direction]), so nothing is
 * ever laid out: spinning and zooming only move the camera, and re-centering
 * on someone only changes how far each star sits from the core.
 *
 * With no [initialPath] (the post bar's Web of Trust button) it finds the path
 * the same way the card does first.
 *
 * Port of iOS Views/TrustWebView.swift (TrustWebView and TrustWebSheet).
 */
@Composable
fun TrustWebDialog(
    author: String,
    initialPath: TrustPath?,
    onProfileClick: ((String) -> Unit)?,
    onDismiss: () -> Unit,
) {
    Dialog(
        onDismissRequest = onDismiss,
        properties = DialogProperties(usePlatformDefaultWidth = false),
    ) {
        Surface(color = Color.Black, modifier = Modifier.fillMaxSize()) {
            Box(Modifier.fillMaxSize().background(SpaceBrush)) {
                val trust = rememberTrustPathServices().trustPathService()
                var path by remember(author) { mutableStateOf(initialPath) }
                LaunchedEffect(author) {
                    if (path == null) path = trust.path(author)
                }
                val loaded = path
                if (loaded != null) {
                    TrustWebContent(
                        author = author,
                        path = loaded,
                        onProfileClick = onProfileClick?.let { open -> { pubkey: String -> onDismiss(); open(pubkey) } },
                        onDismiss = onDismiss,
                    )
                } else {
                    Column(Modifier.safeDrawingPadding()) {
                        TopBar(title = "Web of Trust", onDone = onDismiss, onList = null)
                        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                            CircularProgressIndicator(color = LocalNostrVaultColors.current.primary)
                        }
                    }
                }
            }
        }
    }
}

/**
 * The WOT tab: the globe with nobody picked. You sit at the core with your
 * follows around you and the rest of your web as the haze. Tapping a face
 * centres on them and shows how they reach you: the same globe a post's WOT
 * button opens, pointed back at you. Tapping the tab again ([reselects])
 * brings it back to you. Port of iOS WOTTabView.
 */
@Composable
fun TrustWebTab(
    onProfileClick: (String) -> Unit,
    /** The trust card's Message: opens a DM thread with them. */
    onMessage: (String) -> Unit,
    reselects: kotlinx.coroutines.flow.Flow<*>,
    /** The floating tab bar's height, so the footer's words sit above it. */
    bottomInset: androidx.compose.ui.unit.Dp,
) {
    val trust = rememberTrustPathServices().trustPathService()
    val me by trust.meUpdates.collectAsState()
    Box(Modifier.fillMaxSize().background(Color.Black).background(SpaceBrush)) {
        // A new account draws a new globe; the globe keeps up with your follows itself.
        if (me.isNotEmpty()) androidx.compose.runtime.key(me) {
            TrustWebContent(
                author = me,
                // The path from you to you: no bridges, nothing to look up.
                path = TrustPath.resolve(me, me, emptySet(), emptySet(), emptyList()),
                onProfileClick = onProfileClick,
                onDismiss = null,
                isWOTTab = true,
                onMessage = onMessage,
                reselects = reselects,
                bottomInset = bottomInset,
            )
        }
    }
}

@Composable
private fun TrustWebContent(
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
    LaunchedEffect(trustGraphUpdate, myFollows) {
        val graph = trust.myTrustGraph()
        val inner = myFollows + me + author
        val counts = trust.myVouches()
        val shell = withContext(Dispatchers.Default) { TrustMap.haze(graph - inner, cap = if (lite) TrustMap.HAZE_CAP_LITE else TrustMap.HAZE_CAP) }
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
        if (seen == null || web.size <= seen) return@LaunchedEffect
        newPeople += web.size - seen
        delay(NEW_PEOPLE_SHOWN_MS)
        newPeople = 0
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
    LaunchedEffect(ringCandidates) {
        val asked = HashSet<String>()
        val loaded = java.util.Collections.synchronizedSet(HashSet<String>())
        repeat(PICTURE_WAIT_TICKS) {
            for (pubkey in ringCandidates) {
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
    val ringFaces = remember(ringCandidates, renderedPictures) {
        TrustMap.pickFaces(ringCandidates, { pubkey ->
            profiles[pubkey]?.pictureURL?.let { "$pubkey $it" in renderedPictures } == true
        }, if (lite) TrustMap.RING_FACES_LITE else TrustMap.RING_FACES)
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

    fun tapped(pubkey: String) {
        // The WOT tab answers "can I trust them?" in a card and stays on you.
        if (isWOTTab) return if (pubkey == me || pubkey == card) closeCard() else openCard(pubkey)
        if (peek != null) { peek = null; return }
        // The one in the middle: say who they are rather than go nowhere.
        if (pubkey == crumbs.last()) {
            if (pubkey != me) peek = pubkey
            return
        }
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
                frames = frames + (me to TrustFrame(me, follows, true, path))
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
                // False when the relay isn't up; throws on a library from before the call existed.
                val started = withContext(Dispatchers.IO) { runCatching { HavenBridge.refreshWot() }.getOrDefault(false) }
                if (!started) {
                    refreshState = RefreshState(1f, "Relay isn't running. Showing your last saved web.")
                    delay(RELAY_DOWN_HOLD_MS)
                } else {
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
                            if (!progress.running) break
                        }
                        delay(WOT_POLL_MS)
                    }
                }
                // The rebuild saved a new graph: read it in, and the haze
                // follows through trustGraphUpdates. Give it a moment to land.
                trust.reloadTrustGraph()
                kotlinx.coroutines.withTimeoutOrNull(TRUST_GRAPH_WAIT_MS) { trust.trustGraphUpdates.drop(1).first() }

                refreshState = RefreshState(2f, "Loading profile pictures…")
                val scores = trust.engagement()
                engagement = scores
                nostrService.fetchMissingProfiles(listOf(me) + TrustMap.faceCandidates(trust.myFollows(), scores), force = true)
                refreshState = RefreshState(REFRESH_STEPS.toFloat(), "Up to date")
                delay(REFRESH_DONE_HOLD_MS)
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
                running = !showingList,
                layer = if (isWOTTab) layer else TrustMap.Layer.EVERYONE,
                summary = summary(frame, me, author, centerKey, ::name),
                profiles = profiles, name = ::name,
                onTap = ::tapped,
                // A tap on open space also puts the keyboard away.
                focus = if (isWOTTab) card else null,
                onEmptyTap = { peek = null; closeCard(); if (searchFocused) focusManager.clearFocus() },
            )
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
                        refreshState != null -> "Rebuilding your web"
                        mappingWeb -> "Mapping your web"
                        else -> null
                    },
                    newPeople = newPeople,
                    onClick = { newPeople = 0 },
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

    if (showingList && frame != null) {
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
/** "Relay isn't running" stays up this long before refresh goes on. */
private const val RELAY_DOWN_HOLD_MS = 1_500L
/** The relay's rebuild is polled this often, at most [MAX_WOT_POLLS] times (6 minutes). */
private const val WOT_POLL_MS = 500L
private const val MAX_WOT_POLLS = 720

/** Where a refresh is: [fill] out of [REFRESH_STEPS], and what it's doing. */
private data class RefreshState(val fill: Float, val caption: String)

/**
 * "47", or "at least 5" while relays may hold more: the count is only the
 * signed lists actually checked, never a number a relay states.
 */
private fun countText(frame: TrustFrame): String =
    if (frame.exhausted) "${frame.bridges.size}" else "at least ${frame.bridges.size}"

private fun canLoadMore(frame: TrustFrame): Boolean =
    !frame.exhausted && frame.bridges.isNotEmpty() &&
        (frame.path.hasMore || frame.bridges.size > TrustPath.SHOWN_BRIDGES)

/**
 * No one at the core's follows follows the author: offer the two-step search
 * further out, which costs a few MB, so only on a tap.
 */
private fun canLookDeeper(frame: TrustFrame, author: String): Boolean =
    frame.bridges.isEmpty() && frame.chains == null && frame.center != author && author !in frame.ringSet

private fun explainer(
    frame: TrustFrame?,
    me: String,
    author: String,
    centerKey: String,
    name: (String) -> String,
    myFollows: Set<String>,
    lookingDeeper: Boolean,
    deeperFailed: Boolean,
    accent: Color,
    /** The WOT tab's follow list came back empty: say so rather than "tap anyone". */
    noFollows: Boolean = false,
): AnnotatedString = buildAnnotatedString {
    if (frame == null) {
        append("Loading who ${name(centerKey)} follows…")
        return@buildAnnotatedString
    }
    val them = name(author)
    val center = if (frame.center == me) null else name(frame.center)
    fun bold(text: String, color: Color = accent) =
        withStyle(SpanStyle(color = color, fontWeight = FontWeight.Bold)) { append(text) }
    val direct = author in frame.ringSet
    val chains = frame.chains
    when {
        !frame.listFound -> append("No relay checked had ${name(frame.center)}'s follow list, so their globe can't be drawn.")
        lookingDeeper -> append("Looking two steps further out. This downloads a few MB of follow lists.")
        deeperFailed -> append("Couldn't reach the relays to look further out.")
        noFollows -> append("No follows found yet. Follow people and they'll appear here.")
        // The WOT tab, before anyone is picked.
        frame.center == author && author == me ->
            append("Everyone you follow, and your web around them. Tap anyone to see how they reach you.")
        frame.center == author -> append("Everyone $them follows. Tap a face to see their path.")
        frame.bridges.isNotEmpty() -> when {
            center != null -> {
                append("$center reaches $them through ")
                bold(countText(frame))
                append(" of their follows. ")
                bold("${frame.ring.count { it in myFollows }}", PrimaryText)
                append(" of $center's follows are people you follow too (bright stars).")
            }
            direct -> {
                append("You follow $them, and so do ")
                bold(countText(frame))
                append(" people you follow.")
            }
            else -> {
                append("Followed by ")
                bold(countText(frame))
                append(" people you follow.")
            }
        }
        direct -> append("${center ?: "You"} ${if (center == null) "follow" else "follows"} $them directly.")
        chains != null && chains.isNotEmpty() -> {
            bold("${chains.map { it.via }.toSet().size}")
            append(" people who follow $them are followed by ${center?.let { "people $it follows" } ?: "people you follow"}.")
        }
        chains != null -> append("No longer route turned up in the follow lists checked.")
        else -> append(
            when (frame.path.reach) {
                TrustPath.Reach.WEB -> "In your Web of Trust through people further out. Look deeper to see who."
                TrustPath.Reach.OUTSIDE -> "Not in your web. No one you follow follows them, in the lists checked."
                TrustPath.Reach.UNKNOWN ->
                    if (center != null) "None of $center's follows that were checked follow $them."
                    else "Your trust graph hasn't loaded yet."
                else -> "Tap a face to follow their path."
            },
        )
    }
}

/** The globe's words for TalkBack, which reads the picture as one element. */
private fun summary(frame: TrustFrame?, me: String, author: String, centerKey: String, name: (String) -> String): String {
    if (frame == null) return "Loading who ${name(centerKey)} follows."
    if (frame.center == me && author == me) {
        return "You, the ${frame.ring.size} people you follow, and your web around them."
    }
    val them = name(author)
    val who = if (frame.center == me) "you follow" else "${name(frame.center)} follows"
    if (frame.bridges.isEmpty()) {
        return if (author in frame.ringSet) "${name(frame.center)} follows $them directly."
        else "No one $who was seen following $them."
    }
    val named = frame.bridges.take(2).joinToString(", ") { name(it) }
    return "$them is followed by ${countText(frame)} people $who, including $named."
}

// ── Small pieces ─────────────────────────────────────────────────────

@Composable
private fun TopBar(
    title: String,
    onDone: (() -> Unit)?,
    onList: (() -> Unit)?,
) {
    val accent = LocalNostrVaultColors.current.primary
    Box(Modifier.fillMaxWidth().height(48.dp).padding(horizontal = 8.dp)) {
        if (onDone != null) {
            TextButton(onClick = onDone, modifier = Modifier.align(Alignment.CenterStart)) {
                Text("Done", color = accent, fontSize = 16.sp)
            }
        }
        Text(
            title,
            color = PrimaryText,
            fontSize = 17.sp,
            fontWeight = FontWeight.SemiBold,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            textAlign = TextAlign.Center,
            modifier = Modifier.align(Alignment.Center).padding(horizontal = 72.dp),
        )
        Row(Modifier.align(Alignment.CenterEnd)) {
            if (onList != null) {
                IconButton(onClick = onList) {
                    Icon(NostrVaultIcons.PeopleList, contentDescription = "People on this globe", tint = accent)
                }
            }
        }
    }
}

/** The WOT tab's layer picker icons, iOS `TrustMap.Layer.symbolName`. */
private val TrustMap.Layer.icon: ImageVector
    get() = when (this) {
        TrustMap.Layer.EVERYONE -> NostrVaultIcons.WebOfTrust
        TrustMap.Layer.FOLLOWING -> NostrVaultIcons.People
        TrustMap.Layer.CLOSE -> NostrVaultIcons.Groups
        TrustMap.Layer.FURTHER_OUT -> NostrVaultIcons.Sparkles
    }

/** 16K, 1.5K, 912: short enough that a menu row stays on one line (iOS compactName). */
private fun compactCount(n: Int): String =
    android.icu.text.CompactDecimalFormat
        .getInstance(java.util.Locale.getDefault(), android.icu.text.CompactDecimalFormat.CompactStyle.SHORT)
        .format(n)

/**
 * The WOT tab's bar: the feed's two glass pills. Left is the layer picker,
 * built like the feed picker (icon, name, chevron; the rare Rebuild at the
 * bottom after a divider). Right are search and the globe / list toggle.
 */
@Composable
private fun WotTopBar(
    layer: TrustMap.Layer,
    layers: List<TrustMap.Layer>,
    counts: Map<TrustMap.Layer, Int>,
    onLayer: (TrustMap.Layer) -> Unit,
    refreshing: Boolean,
    onRebuild: () -> Unit,
    searchOpen: Boolean,
    onSearch: () -> Unit,
    showingList: Boolean,
    onGlobe: () -> Unit,
    onList: () -> Unit,
) {
    val accent = LocalNostrVaultColors.current.primary
    var expanded by remember { mutableStateOf(false) }
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 12.dp, vertical = 8.dp)
            .heightIn(min = 48.dp),
    ) {
        Box {
            GlassPill(
                horizontalArrangement = Arrangement.Start,
                modifier = Modifier
                    .clip(CircleShape)
                    .clickable(onClickLabel = "Pick a layer") { expanded = true }
                    .semantics { contentDescription = "Showing: ${layer.title}, ${counts[layer] ?: 0} people" },
            ) {
                Box(Modifier.size(30.dp), contentAlignment = Alignment.Center) {
                    Icon(layer.icon, contentDescription = null, tint = PrimaryText, modifier = Modifier.size(18.dp))
                }
                Spacer(Modifier.width(6.dp))
                Text(layer.title, color = PrimaryText, fontSize = 17.sp, fontWeight = FontWeight.Bold, maxLines = 1)
                Spacer(Modifier.width(2.dp))
                Icon(NostrVaultIcons.ChevronDown, contentDescription = null, tint = PrimaryText, modifier = Modifier.size(16.dp))
                Spacer(Modifier.width(6.dp))
            }
            DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
                layers.forEach { item ->
                    DropdownMenuItem(
                        text = {
                            Text(
                                "${item.title} · ${compactCount(counts[item] ?: 0)}",
                                fontWeight = if (item == layer) FontWeight.SemiBold else FontWeight.Normal,
                            )
                        },
                        leadingIcon = { Icon(item.icon, contentDescription = null, modifier = Modifier.size(18.dp)) },
                        trailingIcon = if (item == layer) {
                            { Icon(NostrVaultIcons.Check, contentDescription = "Current layer", modifier = Modifier.size(16.dp)) }
                        } else null,
                        onClick = {
                            onLayer(item)
                            expanded = false
                        },
                    )
                }
                HorizontalDivider()
                DropdownMenuItem(
                    text = { Text(if (refreshing) "Rebuilding…" else "Rebuild your web") },
                    leadingIcon = { Icon(NostrVaultIcons.Refresh, contentDescription = null, modifier = Modifier.size(18.dp)) },
                    enabled = !refreshing,
                    onClick = {
                        expanded = false
                        onRebuild()
                    },
                )
            }
        }
        Spacer(Modifier.weight(1f))
        GlassPill(horizontalArrangement = Arrangement.Start) {
            IconButton(onClick = onSearch, modifier = Modifier.size(40.dp)) {
                Icon(NostrVaultIcons.Search, contentDescription = "Find someone",
                    tint = if (searchOpen) accent else SecondaryText, modifier = Modifier.size(22.dp))
            }
            Box(
                Modifier
                    .padding(horizontal = 4.dp)
                    .width(1.dp)
                    .height(20.dp)
                    .background(Color.White.copy(alpha = 0.15f)),
            )
            IconButton(onClick = onGlobe, modifier = Modifier.size(40.dp)) {
                Icon(NostrVaultIcons.Globe, contentDescription = "Globe",
                    tint = if (!showingList) accent else SecondaryText, modifier = Modifier.size(22.dp))
            }
            IconButton(onClick = onList, modifier = Modifier.size(40.dp)) {
                Icon(NostrVaultIcons.PeopleList, contentDescription = "List",
                    tint = if (showingList) accent else SecondaryText, modifier = Modifier.size(22.dp))
            }
        }
    }
}

/**
 * The feed's purple "New Posts" button, for people: a rebuild running
 * ([caption]), or how many joined your web since you looked. Nothing when
 * neither.
 */
@Composable
private fun WotLivePill(caption: String?, newPeople: Int, onClick: () -> Unit) {
    val accent = LocalNostrVaultColors.current.primary
    val shape = RoundedCornerShape(50)
    AnimatedVisibility(
        visible = caption != null || newPeople > 0,
        enter = fadeIn(Motion.chrome()),
        exit = fadeOut(Motion.chrome()),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .shadow(8.dp, shape, ambientColor = Color.Black.copy(alpha = 0.4f), spotColor = Color.Black.copy(alpha = 0.4f))
                .clip(shape)
                .background(accent)
                .clickable(enabled = newPeople > 0, onClick = onClick)
                .padding(vertical = 10.dp, horizontal = 20.dp)
                .semantics(mergeDescendants = true) { liveRegion = LiveRegionMode.Polite },
        ) {
            if (newPeople > 0) {
                Icon(NostrVaultIcons.ArrowUp, contentDescription = null, tint = PrimaryText, modifier = Modifier.size(12.dp))
                Spacer(Modifier.width(8.dp))
                Text("${NumberFormat.getIntegerInstance().format(newPeople)} new people",
                    color = PrimaryText, fontSize = 13.sp, fontWeight = FontWeight.Bold)
            } else {
                CircularProgressIndicator(color = PrimaryText, strokeWidth = 1.5.dp, modifier = Modifier.size(12.dp))
                Spacer(Modifier.width(8.dp))
                Text(caption.orEmpty(), color = PrimaryText, fontSize = 13.sp, fontWeight = FontWeight.Bold)
            }
        }
    }
}

/**
 * What the globe is waiting on, said in words over it: a spinner, the person
 * when there is one, and a line. [small] for the quieter "wider web" note.
 */
@Composable
private fun StatusPill(
    text: String,
    accent: Color,
    modifier: Modifier = Modifier,
    pubkey: String? = null,
    profile: FeedProfile? = null,
    small: Boolean = false,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(if (small) 6.dp else 8.dp),
        modifier = modifier
            .padding(horizontal = 24.dp)
            .shadow(8.dp, RoundedCornerShape(50))
            .clip(RoundedCornerShape(50))
            .background(Surface2.copy(alpha = 0.92f))
            .padding(horizontal = if (small) 12.dp else 14.dp, vertical = if (small) 6.dp else 8.dp)
            .semantics(mergeDescendants = true) { liveRegion = LiveRegionMode.Polite },
    ) {
        CircularProgressIndicator(
            color = accent,
            strokeWidth = 1.5.dp,
            modifier = Modifier.size(if (small) 12.dp else 14.dp),
        )
        if (pubkey != null) {
            AvatarImage(url = profile?.pictureURL, pubkey = pubkey, size = 22.dp, displayName = profile?.bestName)
        }
        Text(
            text,
            color = PrimaryText,
            fontSize = if (small) 12.sp else 14.sp,
            fontWeight = FontWeight.Medium,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

/**
 * The WOT tab's "Find someone": a way in for anyone who doesn't know where on
 * the globe a person is. Results show while there's text.
 */
@Composable
private fun SearchField(
    query: String,
    onQueryChange: (String) -> Unit,
    onFocusChange: (Boolean) -> Unit,
    onSearch: () -> Unit,
    onClear: () -> Unit,
    accent: Color,
    modifier: Modifier = Modifier,
) {
    BasicTextField(
        value = query,
        onValueChange = onQueryChange,
        singleLine = true,
        textStyle = TextStyle(color = PrimaryText, fontSize = 15.sp),
        cursorBrush = SolidColor(accent),
        keyboardOptions = KeyboardOptions(
            capitalization = KeyboardCapitalization.None,
            autoCorrectEnabled = false,
            imeAction = ImeAction.Search,
        ),
        keyboardActions = KeyboardActions(onSearch = { onSearch() }),
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 4.dp)
            .onFocusChanged { onFocusChange(it.isFocused) },
        decorationBox = { field ->
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                modifier = Modifier
                    .clip(RoundedCornerShape(12.dp))
                    .background(Color.White.copy(alpha = 0.08f))
                    .heightIn(min = 40.dp)
                    .padding(start = 12.dp, end = 4.dp),
            ) {
                Icon(NostrVaultIcons.Search, contentDescription = null, tint = SecondaryText, modifier = Modifier.size(18.dp))
                Box(Modifier.weight(1f)) {
                    if (query.isEmpty()) Text("Find someone", color = SecondaryText, fontSize = 15.sp, maxLines = 1)
                    field()
                }
                if (query.isNotEmpty()) {
                    IconButton(onClick = onClear, modifier = Modifier.size(36.dp)) {
                        Icon(NostrVaultIcons.Dismiss, contentDescription = "Clear search", tint = SecondaryText,
                            modifier = Modifier.size(18.dp))
                    }
                }
            }
        },
    )
}

/**
 * The search's results over the globe: people you follow first, then your
 * wider web, then anyone the relays know. While relays are being asked, a
 * last row says so; their answers re-rank this list as they land.
 */
@Composable
private fun SearchResults(
    query: String,
    hits: List<TrustMap.PersonHit>,
    searching: Boolean,
    profiles: Map<String, FeedProfile>,
    name: (String) -> String,
    accent: Color,
    onPick: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier
            .padding(horizontal = 12.dp, vertical = 4.dp)
            .widthIn(max = 560.dp)
            .fillMaxWidth()
            .shadow(12.dp, RoundedCornerShape(14.dp))
            .clip(RoundedCornerShape(14.dp))
            .background(Surface2.copy(alpha = 0.96f))
            .verticalScroll(rememberScrollState())
            .padding(vertical = 4.dp),
    ) {
        for (hit in hits) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp),
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable(onClickLabel = "Move them to the middle of the globe") { onPick(hit.pubkey) }
                    .padding(horizontal = 14.dp, vertical = 8.dp)
                    .semantics(mergeDescendants = true) { },
            ) {
                val profile = profiles[hit.pubkey]
                AvatarImage(url = profile?.pictureURL, pubkey = hit.pubkey, size = 32.dp, displayName = profile?.bestName)
                Text(name(hit.pubkey), color = PrimaryText, fontSize = 15.sp, maxLines = 1,
                    overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
                when (hit.tier) {
                    TrustMap.Tier.FOLLOW -> Text("You follow", color = accent, fontSize = 12.sp, maxLines = 1)
                    TrustMap.Tier.WEB -> Text("In your web", color = SecondaryText, fontSize = 12.sp, maxLines = 1)
                    TrustMap.Tier.OTHER -> {}
                }
            }
        }
        if (searching) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp),
                modifier = Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 10.dp),
            ) {
                Box(Modifier.size(32.dp), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator(color = accent, strokeWidth = 1.5.dp, modifier = Modifier.size(16.dp))
                }
                Text("Searching relays…", color = SecondaryText, fontSize = 14.sp)
            }
        } else if (hits.isEmpty()) {
            Text(
                "No one called \u201c$query\u201d yet",
                color = SecondaryText,
                fontSize = 14.sp,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 12.dp),
            )
        }
    }
}

@Composable
private fun CrumbArrow() {
    Text("›", color = SecondaryText, fontSize = 13.sp, modifier = Modifier.clearAndSetSemantics { })
}

@Composable
private fun Chip(
    pubkey: String,
    name: String,
    profile: FeedProfile?,
    on: Boolean,
    destination: Boolean,
    accent: Color,
    onClick: (() -> Unit)?,
) {
    val shape = RoundedCornerShape(50)
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        modifier = Modifier
            .clip(shape)
            .background(if (on) accent.copy(alpha = 0.22f) else Color.White.copy(alpha = 0.08f))
            .then(if (destination) Modifier.border(1.dp, accent.copy(alpha = 0.5f), shape) else Modifier)
            .then(if (onClick != null) Modifier.clickable(role = Role.Button, onClickLabel = "Go back to this step", onClick = onClick) else Modifier)
            .padding(start = 3.dp, end = 10.dp, top = 3.dp, bottom = 3.dp)
            .then(if (destination) Modifier.clearAndSetSemantics { contentDescription = "Looking for $name" } else Modifier),
    ) {
        AvatarImage(url = profile?.pictureURL, pubkey = pubkey, size = 22.dp, displayName = profile?.bestName)
        Text(name, color = if (destination) accent else PrimaryText, fontSize = 13.sp, maxLines = 1)
    }
}

@Composable
private fun LegendDot(color: Color) {
    Box(Modifier.size(7.dp).clip(CircleShape).background(color).clearAndSetSemantics { })
}

@Composable
private fun FooterButton(
    title: String,
    accent: Color,
    filled: Boolean,
    loading: Boolean = false,
    onClick: () -> Unit,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.Center,
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(if (filled) accent else Color.White.copy(alpha = 0.08f))
            .clickable(enabled = !loading, role = Role.Button, onClick = onClick)
            .padding(vertical = 12.dp, horizontal = 12.dp),
    ) {
        if (loading) {
            CircularProgressIndicator(color = accent, strokeWidth = 1.5.dp, modifier = Modifier.size(14.dp))
            Spacer(Modifier.width(8.dp))
        }
        Text(
            title,
            color = if (filled) Color.White else accent,
            fontSize = 15.sp,
            fontWeight = FontWeight.SemiBold,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

/**
 * The WOT tab's "can I trust them?" card: who they are, the people you follow
 * who follow them (the post card's answer and words), and what you can do
 * about it. Block sits behind ⋯ so it can't be hit by accident. iOS
 * `trustCard`.
 */
@Composable
private fun TrustCard(
    pubkey: String,
    name: (String) -> String,
    profiles: Map<String, FeedProfile>,
    path: TrustPath?,
    following: Boolean,
    blocked: Boolean,
    accent: Color,
    onClose: () -> Unit,
    onFollow: () -> Unit,
    onMessage: (() -> Unit)?,
    onProfile: (() -> Unit)?,
    onBlock: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val shape = RoundedCornerShape(16.dp)
    var moreOpen by remember { mutableStateOf(false) }
    Column(
        verticalArrangement = Arrangement.spacedBy(12.dp),
        modifier = modifier
            .padding(12.dp)
            .widthIn(max = 520.dp)
            .fillMaxWidth()
            .shadow(16.dp, shape)
            .clip(shape)
            .background(Surface2.copy(alpha = 0.96f))
            .padding(14.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            val profile = profiles[pubkey]
            AvatarImage(url = profile?.pictureURL, pubkey = pubkey, size = 44.dp, displayName = profile?.bestName)
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(name(pubkey), color = PrimaryText, fontSize = 17.sp, fontWeight = FontWeight.SemiBold,
                    maxLines = 1, overflow = TextOverflow.Ellipsis)
                profile?.nip05?.takeIf { it.isNotBlank() }?.let {
                    Text(it, color = SecondaryText, fontSize = 13.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
            }
            IconButton(onClick = onClose, modifier = Modifier.size(36.dp)) {
                Box(
                    Modifier.size(30.dp).clip(CircleShape).background(Color.White.copy(alpha = 0.08f)),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(NostrVaultIcons.Dismiss, contentDescription = "Close", tint = SecondaryText, modifier = Modifier.size(16.dp))
                }
            }
        }
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            val bridges = path?.bridges.orEmpty()
            if (bridges.isNotEmpty()) {
                Row(horizontalArrangement = Arrangement.spacedBy((-10).dp), modifier = Modifier.clearAndSetSemantics { }) {
                    for (bridge in bridges) {
                        val profile = profiles[bridge]
                        AvatarImage(url = profile?.pictureURL, pubkey = bridge, size = 26.dp, displayName = profile?.bestName,
                            modifier = Modifier.border(2.dp, Color.Black.copy(alpha = 0.6f), CircleShape))
                    }
                }
            }
            Text(
                TrustPathText.label(path, name),
                color = if (path?.reach == TrustPath.Reach.OUTSIDE) SecondaryText else PrimaryText.copy(alpha = 0.85f),
                fontSize = 13.sp,
                modifier = Modifier.weight(1f),
            )
        }
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            // The profile page's words: Unfollow says what the tap does.
            CardButton(if (following) "Unfollow" else "Follow", filled = !following, accent = accent,
                onClick = onFollow, modifier = Modifier.weight(1f))
            if (onMessage != null) CardButton("Message", filled = false, accent = accent, onClick = onMessage, modifier = Modifier.weight(1f))
            if (onProfile != null) CardButton("Profile", filled = false, accent = accent, onClick = onProfile, modifier = Modifier.weight(1f))
            Box {
                IconButton(onClick = { moreOpen = true }, modifier = Modifier.size(40.dp)) {
                    Box(
                        Modifier.size(width = 40.dp, height = 38.dp).clip(RoundedCornerShape(50)).background(Color.White.copy(alpha = 0.08f)),
                        contentAlignment = Alignment.Center,
                    ) {
                        Icon(NostrVaultIcons.More, contentDescription = "More", tint = SecondaryText, modifier = Modifier.size(18.dp))
                    }
                }
                DropdownMenu(expanded = moreOpen, onDismissRequest = { moreOpen = false }) {
                    DropdownMenuItem(
                        text = { Text(if (blocked) "Unblock" else "Block", color = if (blocked) PrimaryText else ErrorRed) },
                        onClick = {
                            moreOpen = false
                            onBlock()
                        },
                    )
                }
            }
        }
    }
}

@Composable
private fun CardButton(title: String, filled: Boolean, accent: Color, onClick: () -> Unit, modifier: Modifier = Modifier) {
    Box(
        contentAlignment = Alignment.Center,
        modifier = modifier
            .height(38.dp)
            .clip(RoundedCornerShape(50))
            .background(if (filled) accent else Color.White.copy(alpha = 0.08f))
            .clickable(role = Role.Button, onClick = onClick),
    ) {
        Text(title, color = if (filled) Color.White else accent, fontSize = 14.sp, fontWeight = FontWeight.SemiBold, maxLines = 1)
    }
}

@Composable
private fun PeekCard(
    pubkey: String,
    name: String,
    profile: FeedProfile?,
    line: String,
    accent: Color,
    onProfile: (() -> Unit)?,
    modifier: Modifier = Modifier,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        modifier = modifier
            .padding(12.dp)
            .shadow(12.dp, RoundedCornerShape(12.dp))
            .clip(RoundedCornerShape(12.dp))
            .background(Surface2)
            .padding(12.dp)
            .semantics(mergeDescendants = true) { },
    ) {
        AvatarImage(url = profile?.pictureURL, pubkey = pubkey, size = 32.dp, displayName = profile?.bestName)
        Column(Modifier.weight(1f, fill = false), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(name, color = PrimaryText, fontSize = 14.sp, fontWeight = FontWeight.SemiBold, maxLines = 1,
                overflow = TextOverflow.Ellipsis)
            Text(line, color = SecondaryText, fontSize = 11.sp, maxLines = 2, overflow = TextOverflow.Ellipsis)
        }
        if (onProfile != null) {
            TextButton(onClick = onProfile, contentPadding = PaddingValues(horizontal = 8.dp)) {
                Text("Profile", color = accent, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
            }
        }
    }
}

/** The globe as a list: for TalkBack, and anyone who'd rather read. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun PeopleList(
    frame: TrustFrame,
    me: String,
    author: String,
    profiles: Map<String, FeedProfile>,
    name: (String) -> String,
    onOpen: ((String) -> Unit)?,
    onDismiss: () -> Unit,
) {
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = Surface1,
        dragHandle = { BottomSheetDefaults.DragHandle(color = SecondaryText) },
    ) {
        val chains = frame.chains.orEmpty()
        LazyColumn(Modifier.fillMaxWidth().padding(bottom = 24.dp)) {
            item {
                Text(name(frame.center), color = PrimaryText, fontSize = 17.sp, fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.padding(horizontal = 20.dp, vertical = 8.dp))
            }
            if (frame.bridges.isNotEmpty()) {
                item {
                    ListHeader(
                        if (frame.center == me) "People you follow who follow ${name(author)}"
                        else "${name(frame.center)}'s follows who follow ${name(author)}",
                    )
                }
                items(frame.bridges, key = { it }) { pubkey ->
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(12.dp),
                        modifier = Modifier
                            .fillMaxWidth()
                            .then(if (onOpen != null) Modifier.clickable(onClickLabel = "Open their profile") { onOpen(pubkey) } else Modifier)
                            .padding(horizontal = 20.dp, vertical = 8.dp),
                    ) {
                        val profile = profiles[pubkey]
                        AvatarImage(url = profile?.pictureURL, pubkey = pubkey, size = 28.dp, displayName = profile?.bestName)
                        Text(name(pubkey), color = PrimaryText, fontSize = 15.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                }
            }
            if (chains.isNotEmpty()) {
                item { ListHeader("Further out") }
                items(chains.take(50)) { chain ->
                    Text(
                        "${name(chain.bridge)} → ${name(chain.via)} → ${name(author)}",
                        color = PrimaryText,
                        fontSize = 15.sp,
                        modifier = Modifier
                            .fillMaxWidth()
                            .then(if (onOpen != null) Modifier.clickable { onOpen(chain.via) } else Modifier)
                            .padding(horizontal = 20.dp, vertical = 10.dp),
                    )
                }
            }
            if (frame.bridges.isEmpty() && chains.isEmpty()) {
                item {
                    Text("No one on this globe follows ${name(author)} yet.", color = SecondaryText, fontSize = 15.sp,
                        modifier = Modifier.padding(horizontal = 20.dp, vertical = 12.dp))
                }
            }
        }
    }
}

@Composable
private fun ListHeader(text: String) {
    Text(
        text.uppercase(),
        color = SecondaryText,
        fontSize = 11.sp,
        fontWeight = FontWeight.SemiBold,
        letterSpacing = 0.5.sp,
        modifier = Modifier.padding(start = 20.dp, end = 20.dp, top = 16.dp, bottom = 4.dp),
    )
}

// ── The globe ────────────────────────────────────────────────────────

/** Frame-clock seconds: the same base as `withFrameNanos`. */
private fun nowSeconds() = System.nanoTime() / 1e9

/** What a globe reload depends on; any change re-settles it. */
private data class LoadKey(
    val center: String,
    val ring: Int,
    val bridges: Int,
    val chains: Int,
    val haze: Int,
    val close: Int,
    val mine: Int,
    /** The ring's faces when the core is the author; they change as pictures stream in. */
    val faces: List<String>,
)

/** Spinning and turning to a person both take about this long; a new person's globe settles in after it. */
private const val TURN_DELAY_MS = 380L

/** Pictures are laid out at this size and scaled to each face. */
private const val PICTURE_DP = 64f

/**
 * The globe itself: one Canvas for stars and threads, the few faces on top as
 * pictures, and a second Canvas for names. A frame clock runs only while
 * something on it moves.
 */
@Composable
private fun TrustGlobe(
    frame: TrustFrame?,
    center: String,
    me: String,
    author: String,
    myFollows: Set<String>,
    haze: List<String>,
    /** The part of [haze] at least [TrustMap.CLOSE_VOUCHES] of your follows follow. */
    closeHaze: Set<String> = emptySet(),
    /** A phone with little memory: stars are drawn as points. */
    lite: Boolean,
    /**
     * Faces for the ring when the core is the author, who has no bridges to
     * show: without these the only face is the core ([TrustMap.pickFaces]).
     */
    ringFaces: List<String>,
    /** False while a sheet covers the globe: the clock stops. */
    running: Boolean,
    /** Which part of the web is lit (the WOT tab's layer picker). */
    layer: TrustMap.Layer = TrustMap.Layer.EVERYONE,
    /** The person the trust card is about: the globe turns to face them. */
    focus: String? = null,
    summary: String,
    profiles: Map<String, FeedProfile>,
    name: (String) -> String,
    onTap: (String) -> Unit,
    /** A tap that lands on no one, e.g. to close the peek card. */
    onEmptyTap: () -> Unit,
) {
    val scene = remember { GlobeScene(lite) }
    val textMeasurer = rememberTextMeasurer(cacheSize = 128)
    val haptic = LocalHapticFeedback.current
    val lifecycleState by LocalLifecycleOwner.current.lifecycle.currentStateAsState()
    val active = running && lifecycleState.isAtLeast(Lifecycle.State.RESUMED)
    val currentFrame by rememberUpdatedState(frame)
    val currentHaze by rememberUpdatedState(haze)
    val currentCloseHaze by rememberUpdatedState(closeHaze)
    val currentRingFaces by rememberUpdatedState(ringFaces)
    val currentFollows by rememberUpdatedState(myFollows)
    val currentName by rememberUpdatedState(name)
    val currentOnTap by rememberUpdatedState(onTap)
    val currentOnEmptyTap by rememberUpdatedState(onEmptyTap)

    // The frame clock: runs while awake and on screen, then sleeps until a
    // touch or new data wakes it. Keyed on [active] only: a wake landing before
    // the next recomposition would leave an `awake` key unchanged.
    LaunchedEffect(active) {
        if (!active) return@LaunchedEffect
        while (true) {
            snapshotFlow { scene.awake }.first { it }
            scene.lastTick = null
            while (scene.awake) withFrameNanos { scene.tick(it / 1e9) }
        }
    }

    LaunchedEffect(center) {
        if (scene.hasLoaded && center != scene.center) scene.turn(center)
    }

    LaunchedEffect(layer) { scene.focus(layer) }

    LaunchedEffect(focus) { focus?.let { scene.turn(it) } }

    // Reduce Motion turned off while the clock sleeps: nothing else wakes it.
    LaunchedEffect(scene) {
        Motion.reducedUpdates.drop(1).collect { scene.reduceMotionChanged() }
    }

    val loadKey = frame?.let {
        LoadKey(it.center, it.ring.size, it.bridges.size, it.chains?.size ?: -1, haze.size, closeHaze.size,
            myFollows.size, if (it.center == author) ringFaces else emptyList())
    }
    LaunchedEffect(loadKey) {
        val first = currentFrame ?: return@LaunchedEffect
        // Turn to the new person first, then let the globe re-settle around them.
        if (scene.hasLoaded && first.center != scene.center && !Motion.isReduced) delay(TURN_DELAY_MS)
        val latest = currentFrame ?: return@LaunchedEffect
        scene.load(latest, me, author, currentFollows, currentHaze, currentCloseHaze, currentRingFaces)
    }

    val faceKeys = scene.faceKeys
    val accent = GlobeAccent
    Box(
        Modifier
            .fillMaxSize()
            .pointerInput(scene) {
                // A double-tap resets; a single tap waits until it can't be one,
                // so a double-tap on a face doesn't also fly there.
                detectTapGestures(
                    onDoubleTap = { scene.reset() },
                    onTap = { at ->
                        val key = scene.hit(at, size.width.toFloat(), size.height.toFloat(), density)
                        if (key == null) {
                            currentOnEmptyTap()
                        } else {
                            haptic.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                            currentOnTap(key)
                        }
                    },
                )
            }
            .pointerInput(scene) {
                // One finger spins, two pinch. Taps fall through to the detector
                // above until a finger moves past the touch slop.
                awaitEachGesture {
                    val down = awaitFirstDown(requireUnconsumed = false)
                    // The first finger only, release included, so a pause
                    // before lifting lets go with no flick.
                    val tracker = VelocityTracker()
                    tracker.addPointerInputChange(down)
                    var moving = false
                    var pinched = false
                    var travel = Offset.Zero
                    try {
                        while (true) {
                            val event = awaitPointerEvent()
                            event.changes.firstOrNull { it.id == down.id }?.let { tracker.addPointerInputChange(it) }
                            val pressed = event.changes.count { it.pressed }
                            if (pressed == 0) break
                            val zoom = event.calculateZoom()
                            val pan = event.calculatePan()
                            if (pressed > 1) pinched = true
                            if (!moving) {
                                travel += pan
                                moving = pressed > 1 || travel.getDistance() > viewConfiguration.touchSlop
                            }
                            if (!moving) continue
                            val now = nowSeconds()
                            if (pressed > 1) {
                                if (zoom != 1f) scene.camera.zoomBy(zoom.toDouble(), now)
                            } else {
                                scene.camera.dragging = true
                                scene.camera.drag(pan.x / density.toDouble(), pan.y / density.toDouble(), now)
                            }
                            event.changes.forEach { if (it.positionChanged()) it.consume() }
                            scene.wake()
                        }
                        if (moving && !pinched) {
                            val v = tracker.calculateVelocity()
                            scene.camera.flick(v.x / density.toDouble(), v.y / density.toDouble(), nowSeconds(), Motion.isReduced)
                        }
                    } finally {
                        // Also on cancel, or the camera would think it's still held.
                        scene.camera.dragging = false
                        scene.wake()
                    }
                }
            }
            .clearAndSetSemantics {
                contentDescription = "Web of Trust globe"
                stateDescription = summary
                customActions = faceKeys.filter { it != center }.map { key ->
                    CustomAccessibilityAction("Go to ${name(key)}") { currentOnTap(key); true }
                } + listOf(
                    CustomAccessibilityAction("Zoom in") { scene.zoomStep(0.3); true },
                    CustomAccessibilityAction("Zoom out") { scene.zoomStep(-0.3); true },
                    CustomAccessibilityAction("Reset view") { scene.reset(); true },
                )
            },
    ) {
        Canvas(Modifier.fillMaxSize()) { scene.drawBack(this, accent) }

        Layout(
            content = {
                for (key in faceKeys) {
                    androidx.compose.runtime.key(key) {
                        val tint = when {
                            key == center && key == me -> accent
                            key == center -> Color.White
                            key == author -> AuthorTint
                            // The core is the author: these are their follows.
                            center == author -> RingColor
                            else -> accent
                        }
                        val profile = profiles[key]
                        AvatarImage(
                            url = profile?.pictureURL,
                            pubkey = key,
                            size = PICTURE_DP.dp,
                            displayName = profile?.bestName,
                            modifier = Modifier.border(4.dp, tint, CircleShape),
                        )
                    }
                }
            },
            modifier = Modifier.fillMaxSize(),
        ) { measurables, constraints ->
            val placeables = measurables.map { it.measure(Constraints()) }
            layout(constraints.maxWidth, constraints.maxHeight) {
                scene.prepare(constraints.maxWidth.toFloat(), constraints.maxHeight.toFloat(), density)
                placeables.forEachIndexed { i, placeable ->
                    val spot = faceKeys.getOrNull(i)?.let(scene::spot)
                    val half = placeable.width / 2f
                    if (spot == null || spot.ember) {
                        placeable.placeWithLayer(0, 0) { alpha = 0f }
                    } else {
                        val s = (spot.r / half).toFloat()
                        placeable.placeWithLayer(
                            (spot.x - half).roundToInt(),
                            (spot.y - placeable.height / 2f).roundToInt(),
                            zIndex = if (spot.core) 10f else spot.depth.toFloat(),
                        ) {
                            scaleX = s
                            scaleY = s
                            alpha = spot.alpha.toFloat()
                        }
                    }
                }
            }
        }

        Canvas(Modifier.fillMaxSize()) { scene.drawLabels(this, textMeasurer, currentName) }
    }
}

/**
 * Everything the globe draws, kept between frames so a frame is one pass with
 * few allocations. Mutated by the frame clock; only [awake], [faceKeys] and two
 * counters are Compose state.
 */
private class GlobeScene(
    /** Draw stars as batched points: the oval paths cost a slow phone a whole frame. */
    private val lite: Boolean = false,
) {
    enum class Kind { RING, MUTUAL, HAZE, CLOSE_HAZE, BRIDGE, VIA }

    private class Star(val key: String, val dir: Vec3, var kind: Kind, var radius: Double) {
        var radiusTarget = radius
        var alpha = 0.0
        var alphaTarget = 1.0
        var isFace = false
    }

    /** One person on screen this frame, in pixels. */
    class Spot(
        val key: String,
        val x: Double,
        val y: Double,
        val r: Double,
        val alpha: Double,
        val depth: Double,
        /** Behind the globe: a warm ember, not a face. */
        val ember: Boolean,
        val core: Boolean,
        val tint: Color,
        val label: Boolean,
    )

    private class Projected(val x: Double, val y: Double, val depth: Double, val scale: Double) {
        /** 0 at the back of the globe, 1 at the front. */
        val front: Double get() = ((depth + 1.7) / 3.4).coerceIn(0.0, 1.0)
    }

    /** False once nothing moves: the frame clock stops until a touch or new data. */
    var awake by mutableStateOf(true)
        private set
    /** Who is drawn with a picture: the core, the author, and the faces. */
    var faceKeys by mutableStateOf(emptyList<String>())
        private set
    /** Bumped every tick and every load, so drawing and placement re-run. */
    private val frameCount = mutableLongStateOf(0L)
    private val version = mutableIntStateOf(0)

    val camera = GlobeCamera()
    var lastTick: Double? = null
    var center = ""
        private set
    var hasLoaded = false
        private set
    private var reduceMotion = false
    private var author = ""
    private var me = ""
    private var bridges: List<String> = emptyList()
    private var chains: List<TrustMap.Chain> = emptyList()
    private var faces: List<String> = emptyList()
    /**
     * How brightly your follows, the Close shell and the rest of the shell
     * are drawn, easing toward the picked layer's ([TrustMap.layerWeights]).
     */
    private var weights = TrustMap.Weights(1.0, 1.0, 1.0)
    private var weightTarget = weights
    /** Faces drawn with a picture last frame, so they keep their seat. */
    private var seated: Set<String> = emptySet()
    private var direct = false

    private var stars = ArrayList<Star>()
    private var index = HashMap<String, Star>()

    private var born = 0.0
    private var threadsBorn = 0.0
    private var threadProgress = 1.0
    private var settling = false

    // ── Data ─────────────────────────────────────────────────────────

    fun load(
        frame: TrustFrame,
        me: String,
        author: String,
        myFollows: Set<String>,
        haze: List<String>,
        closeHaze: Set<String> = emptySet(),
        ringFaces: List<String> = emptyList(),
    ) {
        val now = nowSeconds()
        reduceMotion = Motion.isReduced
        val newCenter = !hasLoaded || frame.center != center
        this.me = me
        this.author = author
        center = frame.center

        // Every star's shell and look for this core.
        val bridgeSet = frame.bridges.toSet()
        val want = HashMap<String, Pair<Kind, Double>>()
        if (frame.center == me) for (key in haze) {
            want[key] = (if (key in closeHaze) Kind.CLOSE_HAZE else Kind.HAZE) to TrustMap.OUTER_RADIUS
        }
        for (key in frame.ring) {
            val kind = when {
                key in bridgeSet -> Kind.BRIDGE
                frame.center != me && key in myFollows -> Kind.MUTUAL
                else -> Kind.RING
            }
            want[key] = kind to TrustMap.RING_RADIUS
        }
        for (chain in frame.chains.orEmpty()) {
            if (want[chain.via]?.first != Kind.BRIDGE) want[chain.via] = Kind.VIA to TrustMap.OUTER_RADIUS
        }
        // A bridge the ring snapshot missed (the follow list changed or loaded
        // late) still gets its star and thread.
        for (key in frame.bridges) if (key !in want) want[key] = Kind.BRIDGE to TrustMap.RING_RADIUS
        want[author] = Kind.BRIDGE to TrustMap.AUTHOR_RADIUS
        want[frame.center] = Kind.RING to 0.0

        for (star in stars) {
            if (star.key !in want) {
                star.radiusTarget = 2.4 // drifts out and fades
                star.alphaTarget = 0.0
            }
        }
        for ((key, look) in want) {
            val (kind, r) = look
            val star = index[key]
            if (star != null) {
                star.kind = kind
                star.radiusTarget = r
                star.alphaTarget = 1.0
            } else {
                val fresh = Star(key, TrustMap.direction(key), kind, r)
                stars.add(fresh)
                index[key] = fresh
            }
        }

        direct = frame.center != author && author in frame.ringSet
        bridges = if (frame.center == author) emptyList() else frame.bridges
        chains = frame.chains.orEmpty()
        val shown = ArrayList<String>()
        val taken = hashSetOf(frame.center, author)
        // The core is the author, so there are no bridges: give the ring faces
        // instead, or there'd be nothing to tap but the core.
        val faceSource = if (frame.center == author) ringFaces.filter { it in frame.ringSet } else TrustMap.spread(bridges, MAX_FACES)
        for (key in faceSource) if (taken.add(key)) shown += key
        for (chain in chains.take(TrustMap.SHOWN_CHAINS)) {
            for (key in listOf(chain.bridge, chain.via)) if (taken.add(key)) shown += key
        }
        faces = shown
        val pictured = shown.toHashSet().apply { add(frame.center); add(author) }
        for (star in stars) star.isFace = star.key in pictured
        val symbols = (if (frame.center == author) listOf(author) else listOf(frame.center, author)) + shown
        if (faceKeys != symbols) faceKeys = symbols

        born = now
        settling = true
        if (newCenter) {
            threadsBorn = now
            threadProgress = if (reduceMotion) 1.0 else 0.0
            val target = GlobeCamera.facing(TrustMap.direction(if (frame.center == author) frame.center else author))
            if (hasLoaded) {
                camera.fly(target, now)
            } else {
                // Opens already turned to show the paths.
                camera.orientation = target
                camera.touch(now)
            }
        }
        hasLoaded = true
        if (reduceMotion) settle()
        version.intValue++
        wake()
    }

    /** Turn toward someone tapped, before their globe has loaded. */
    fun turn(key: String) {
        camera.fly(GlobeCamera.facing(TrustMap.direction(key)), nowSeconds())
        wake()
    }

    fun reset() {
        val target = if (center == author) center else author
        camera.fly(GlobeCamera.facing(TrustMap.direction(target)), nowSeconds())
        wake()
    }

    /** TalkBack's zoom actions. */
    fun zoomStep(step: Double) {
        val range = GlobeCamera.ZOOM_RANGE
        camera.zoomTarget = (camera.zoomTarget + step).coerceIn(range)
        camera.touch(nowSeconds())
        wake()
    }

    /** Lights one layer and dims the rest. Nothing is reloaded. */
    fun focus(layer: TrustMap.Layer) {
        weightTarget = TrustMap.layerWeights(layer)
        if (Motion.isReduced) weights = weightTarget
        wake()
    }

    fun wake() {
        if (!awake) {
            lastTick = null
            awake = true
        }
    }

    /** iOS `onChange(of: reduceMotion)`: drop any spin and redraw once. */
    fun reduceMotionChanged() {
        camera.spin = Vec3.ZERO
        wake()
    }

    // ── Frame clock ──────────────────────────────────────────────────

    fun tick(now: Double) {
        val dt = lastTick?.let { min(GlobeCamera.MAX_STEP, max(0.0, now - it)) } ?: 0.0
        lastTick = now
        reduceMotion = Motion.isReduced
        // Turned on mid-spin: stop, or the spin never decays and the clock never sleeps.
        if (reduceMotion) camera.spin = Vec3.ZERO
        camera.step(dt, now, reduceMotion)
        val fading = weights != weightTarget
        if (fading) {
            val ease = 1 - exp(-dt * 8)
            fun step(from: Double, to: Double) = if (abs(to - from) < 0.005) to else from + (to - from) * ease
            weights = TrustMap.Weights(
                step(weights.follows, weightTarget.follows),
                step(weights.close, weightTarget.close),
                step(weights.further, weightTarget.further),
            )
            frameCount.longValue++
        }
        if (settling) {
            val age = now - born
            val glide = 1 - exp(-dt * 7)
            val fade = 1 - exp(-dt * 6)
            for (star in stars) {
                star.radius += (star.radiusTarget - star.radius) * glide
                // Sweep in by direction so the shell fills like a wave, not a pop.
                if (age > (star.dir.x + 1) * 0.12) star.alpha += (star.alphaTarget - star.alpha) * fade
            }
            threadProgress = ((now - threadsBorn - 0.35) / 0.55).coerceIn(0.0, 1.0)
            if (age > SETTLE_TIME) settle()
        }
        frameCount.longValue++
        if (!settling && !fading && !camera.wantsFrames(now, reduceMotion)) awake = false
    }

    /** Land every star where it's heading and drop the ones that faded out. */
    private fun settle() {
        for (star in stars) {
            star.radius = star.radiusTarget
            star.alpha = star.alphaTarget
        }
        threadProgress = 1.0
        settling = false
        if (stars.all { it.alphaTarget > 0 }) return
        stars = stars.filterTo(ArrayList()) { it.alphaTarget > 0 }
        index = stars.associateByTo(HashMap()) { it.key }
    }

    // ── Projection ───────────────────────────────────────────────────

    /** One camera's projection, worked out once per frame. */
    private class Projector(camera: GlobeCamera, w: Float, h: Float) {
        val m = camera.orientation.matrix()
        val cameraZ = 4.2 / camera.zoom
        val unit = min(w, h) * 0.40 * 4.2 * 0.92
        val midX = w / 2.0
        val midY = h / 2.0

        fun project(d: Vec3, r: Double): Projected? {
            val px = d.x * r; val py = d.y * r; val pz = d.z * r
            val vx = m[0] * px + m[1] * py + m[2] * pz
            val vy = m[3] * px + m[4] * py + m[5] * pz
            val vz = m[6] * px + m[7] * py + m[8] * pz
            val gap = cameraZ - vz
            // Zoomed in, the outer shell passes the camera: drop what's behind the lens.
            if (gap < 0.45) return null
            val s = 1 / gap
            return Projected(midX + vx * s * unit, midY - vy * s * unit, vz, s * cameraZ)
        }
    }

    private fun Projector.of(star: Star) = project(star.dir, star.radius)

    /** Closest front-facing face to a tap, within reach of a fingertip. Zoomed in, plain stars can be tapped too. */
    fun hit(at: Offset, w: Float, h: Float, density: Float): String? {
        val project = Projector(camera, w, h)
        var best: String? = null
        var bestDistance = Double.MAX_VALUE
        fun consider(star: Star, reach: Double) {
            if (star.alpha <= 0.5) return
            val p = project.of(star) ?: return
            if (p.depth <= -0.15) return
            val d = hypot(p.x - at.x, p.y - at.y)
            if (d < reach && d < bestDistance) { best = star.key; bestDistance = d }
        }
        for (star in stars) if (star.isFace) consider(star, 30.0 * density)
        if (best == null && camera.zoom >= 1.6) {
            for (star in stars) if (!star.isFace && star.kind != Kind.HAZE && star.kind != Kind.CLOSE_HAZE) consider(star, 16.0 * density)
        }
        return best
    }

    // ── One frame's picture ──────────────────────────────────────────

    private var preparedFor = LongArray(4) { -1 }
    /** Pixels per dp for the frame last prepared. */
    private var dpPx = 1f
    private var originX = 0.0
    private var originY = 0.0
    private var coreR = 0.0
    private var ready = false

    /** Stars bucketed by kind and brightness: one pass, a few fills. */
    private val buckets = Array(Slot.entries.size) { Array(LEVELS + 1) { Path() } }
    private val glow = Array(4) { Path() }
    private val strong = Array(4) { Path() }
    private val faint = Array(4) { Path() }
    private val dashed = Path()
    private var spots: List<Spot> = emptyList()
    private val spotByKey = HashMap<String, Spot>()
    private val starLabels = ArrayList<Spot>()

    private enum class Slot { HAZE, RING, MUTUAL, HOT }

    /** Lite: one slot, brightness and whole-pixel diameter, drawn in a single drawPoints call. */
    private class PointBucket(val slot: Slot, val level: Int, val diameter: Float) {
        var xy = FloatArray(64)
        var count = 0
        fun add(x: Float, y: Float) {
            if (count * 2 + 2 > xy.size) xy = xy.copyOf(xy.size * 2)
            xy[count * 2] = x
            xy[count * 2 + 1] = y
            count++
        }
    }
    /** Kept between frames and emptied, so a frame allocates nothing once warm. */
    private val pointBuckets = HashMap<Int, PointBucket>()
    private val pointOrder = ArrayList<PointBucket>()
    private val pointPaint = android.graphics.Paint().apply {
        isAntiAlias = true
        strokeCap = android.graphics.Paint.Cap.ROUND
        style = android.graphics.Paint.Style.STROKE
    }

    private fun pointBucket(slot: Slot, level: Int, radius: Double): PointBucket {
        val diameter = max(1, (radius * 2).roundToInt()).coerceAtMost(255)
        val key = (slot.ordinal shl 16) or (level shl 8) or diameter
        return pointBuckets.getOrPut(key) {
            PointBucket(slot, level, diameter.toFloat()).also {
                pointOrder.add(it)
                // Dim to bright, as the oval fills go, so a bright star sits on top.
                pointOrder.sortWith(compareBy({ b -> b.level }, { b -> b.diameter }))
            }
        }
    }

    fun spot(key: String): Spot? = spotByKey[key]

    /**
     * Works out this frame's stars, threads and faces for a [w]×[h] pixel
     * view. Runs once per frame however many times it's asked: placement
     * asks first, then both canvases.
     */
    fun prepare(w: Float, h: Float, density: Float) {
        val f = frameCount.longValue
        val v = version.intValue.toLong()
        val key = longArrayOf(f, v, w.toRawBits().toLong(), h.toRawBits().toLong())
        if (key.contentEquals(preparedFor)) return
        preparedFor = key
        dpPx = density
        for (slot in buckets) for (p in slot) p.reset()
        for (bucket in pointBuckets.values) bucket.count = 0
        for (band in 0 until 4) { glow[band].reset(); strong[band].reset(); faint[band].reset() }
        dashed.reset()
        spotByKey.clear()
        starLabels.clear()
        spots = emptyList()
        ready = false

        val coreStar = index[center]
        if (!hasLoaded || coreStar == null) return
        val project = Projector(camera, w, h)
        val zoom = camera.zoom
        val k = min(1.0, min(w, h) / density / 620.0)
        val core = project.of(coreStar) ?: return
        val origin = project.project(Vec3.ZERO, 0.0) ?: core
        originX = origin.x
        originY = origin.y
        coreR = 22 * k * core.scale * min(zoom, 1.8) * density
        ready = true
        val pad = 8 * density
        val namesOut = zoom > 2.2
        val labelled = ArrayList<Spot>()

        for (star in stars) {
            if (star.isFace) continue
            val a = star.alpha * when (star.kind) {
                Kind.HAZE -> weights.further
                Kind.CLOSE_HAZE -> weights.close
                else -> weights.follows
            }
            if (a <= 0.02) continue
            val p = project.of(star) ?: continue
            if (p.x < -pad || p.y < -pad || p.x > w + pad || p.y > h + pad) continue
            val front = p.front
            val (slot, base, size) = when (star.kind) {
                Kind.HAZE -> Triple(Slot.HAZE, 0.06 + 0.16 * front, 1.2)
                // A touch brighter and bigger: close enough to tell apart in the shell.
                Kind.CLOSE_HAZE -> Triple(Slot.HAZE, 0.10 + 0.22 * front, 1.4)
                Kind.RING -> Triple(Slot.RING, 0.25 + 0.65 * front, 2.1)
                Kind.MUTUAL -> Triple(Slot.MUTUAL, 0.45 + 0.55 * front, 2.4)
                Kind.BRIDGE, Kind.VIA -> Triple(Slot.HOT, 0.35 + 0.65 * front, 2.8)
            }
            val level = (min(1.0, base * a) * LEVELS).roundToInt()
            if (level <= 0) continue
            val r = size * p.scale * zoom * density
            if (lite) {
                pointBucket(slot, min(LEVELS, level), r).add(p.x.toFloat(), p.y.toFloat())
            } else {
                buckets[slot.ordinal][min(LEVELS, level)].addOval(
                    Rect((p.x - r).toFloat(), (p.y - r).toFloat(), (p.x + r).toFloat(), (p.y + r).toFloat()),
                )
            }
            if (namesOut && slot != Slot.HAZE && p.depth > 0.6 && labelled.size < 200) {
                labelled += Spot(star.key, p.x, p.y, r, a, p.depth, ember = false, core = false, tint = Color.White, label = true)
            }
        }

        // Threads: core → bridge → author, drawn out over half a second.
        val authorStar = if (center == author) null else index[author]
        val authorP = authorStar?.let { project.of(it) }
        if (authorP != null) {
            val t = threadProgress
            val leg1 = min(1.0, t * 2)
            val leg2 = max(0.0, t * 2 - 1)
            fun band(front: Double) = min(3, (front * 4).toInt())
            if (direct) {
                strong[3].line(core.x, core.y, lerp(core.x, authorP.x, t), lerp(core.y, authorP.y, t))
                glow[3].line(core.x, core.y, lerp(core.x, authorP.x, t), lerp(core.y, authorP.y, t))
            }
            for (key in bridges) {
                val star = index[key] ?: continue
                if (star.alpha <= 0.05) continue
                val b = project.of(star) ?: continue
                val bandIndex = band(b.front)
                val ix = lerp(core.x, b.x, leg1); val iy = lerp(core.y, b.y, leg1)
                faint[bandIndex].line(core.x, core.y, ix, iy)
                val bright = b.front > 0.62
                if (bright) glow[bandIndex].line(core.x, core.y, ix, iy)
                if (leg2 > 0) {
                    val ox = lerp(b.x, authorP.x, leg2); val oy = lerp(b.y, authorP.y, leg2)
                    strong[bandIndex].line(b.x, b.y, ox, oy)
                    if (bright) glow[bandIndex].line(b.x, b.y, ox, oy)
                }
            }
            if (t >= 1) {
                for (chain in chains) {
                    val b = index[chain.bridge]?.let { project.of(it) } ?: continue
                    val via = index[chain.via]?.let { project.of(it) } ?: continue
                    dashed.moveTo(core.x.toFloat(), core.y.toFloat())
                    dashed.lineTo(b.x.toFloat(), b.y.toFloat())
                    dashed.lineTo(via.x.toFloat(), via.y.toFloat())
                    dashed.lineTo(authorP.x.toFloat(), authorP.y.toFloat())
                }
            }
        }

        // Faces, back to front: bridges, chain steps and the author.
        class Drawn(val key: String, val p: Projected, val tint: Color, val size: Double)
        val drawn = ArrayList<Drawn>()
        for (key in faces) {
            val p = index[key]?.let { project.of(it) } ?: continue
            drawn += Drawn(key, p, if (center == author) RingColor else GlobeAccent, 15.0)
        }
        if (authorP != null) drawn += Drawn(author, authorP, AuthorTint, 24.0)
        drawn.sortBy { it.p.depth }

        // Seats: a face only where it covers no other face and not the core;
        // the rest stay stars until the globe turns them some room.
        val faceR = { d: Drawn -> d.size * k * d.p.scale * min(zoom, 1.8) * density }
        val seats = TrustMap.seatFaces(
            drawn.asReversed().filter { it.p.depth >= -0.1 || it.key == author }
                .map { TrustMap.FaceSpot(it.key, it.p.x, it.p.y, faceR(it)) },
            always = setOf(author),
            kept = seated,
            blocked = listOf(TrustMap.FaceSpot(center, core.x, core.y, coreR)),
        )
        seated = seats

        // Labels: front-most first, skipping any that would cover one placed.
        val placed = arrayListOf(Rect((core.x - 40 * density).toFloat(), (core.y - coreR).toFloat(),
            (core.x + 40 * density).toFloat(), (core.y + coreR + 22 * density).toFloat()))
        // Pictures count as placed too, so a name never runs across a face.
        for (face in drawn) {
            if (face.key !in seats) continue
            val r = faceR(face)
            placed += Rect((face.p.x - r).toFloat(), (face.p.y - r).toFloat(), (face.p.x + r).toFloat(), (face.p.y + r).toFloat())
        }
        val showLabel = HashSet<String>()
        val labelCap = if (zoom < 1.5) 9 else 40
        for (face in drawn.asReversed()) {
            if (face.p.depth <= 0.15 || face.key !in seats || showLabel.size >= labelCap) continue
            val r = face.size * k * face.p.scale * min(zoom, 1.8) * density
            val box = Rect((face.p.x - 46 * density).toFloat(), (face.p.y + r + 2 * density).toFloat(),
                (face.p.x + 46 * density).toFloat(), (face.p.y + r + 18 * density).toFloat())
            if (face.key == author || placed.none { it.overlaps(box) }) {
                placed += box
                showLabel += face.key
            }
        }
        val out = ArrayList<Spot>(drawn.size + 1)
        for (face in drawn) {
            val a = (index[face.key] ?: coreStar).alpha * (if (face.key == author) 1.0 else weights.follows)
            val dim = (0.35 + 0.65 * face.p.front) * a
            val behind = face.p.depth < -0.1 && face.key != author
            // No room for its picture here: a bright star in its colour.
            val held = !behind && face.key !in seats
            val r = if (behind) 3.2 * face.p.scale * zoom * density
            else if (held) 3.6 * face.p.scale * zoom * density
            else faceR(face)
            out += Spot(face.key, face.p.x, face.p.y, r, dim, face.p.depth, ember = behind || held, core = false,
                tint = face.tint, label = face.key in showLabel)
        }
        // The core last: it is always in front of its own shell.
        out += Spot(center, core.x, core.y, coreR, 1.0, core.depth, ember = false, core = true,
            tint = if (center == me) GlobeAccent else Color.White, label = true)
        spots = out
        for (spot in out) spotByKey[spot.key] = spot

        // Names on plain stars once zoomed well in, where they fit.
        if (namesOut) {
            for (star in labelled) {
                if (placed.size >= 60) break
                val box = Rect((star.x - 40 * density).toFloat(), (star.y + star.r + 2 * density).toFloat(),
                    (star.x + 40 * density).toFloat(), (star.y + star.r + 15 * density).toFloat())
                if (placed.any { it.overlaps(box) }) continue
                placed += box
                starLabels += star
            }
        }
    }

    /** Stars, threads, glows and embers: everything under the faces. */
    fun drawBack(scope: DrawScope, accent: Color) = with(scope) {
        prepare(size.width, size.height, density)
        if (!ready) return@with
        val dp = dpPx

        // Glow behind the core.
        val glowR = (coreR * 3).toFloat()
        if (glowR > 0f) {
            drawCircle(
                brush = Brush.radialGradient(listOf(accent.copy(alpha = 0.32f), Color.Transparent),
                    center = Offset(originX.toFloat(), originY.toFloat()), radius = glowR),
                radius = glowR,
                center = Offset(originX.toFloat(), originY.toFloat()),
            )
        }

        fun fill(slot: Slot, color: Color) {
            if (lite) {
                drawIntoCanvas { canvas ->
                    for (bucket in pointOrder) {
                        if (bucket.slot != slot || bucket.count == 0) continue
                        pointPaint.color = color.copy(alpha = bucket.level.toFloat() / LEVELS).toArgb()
                        pointPaint.strokeWidth = bucket.diameter
                        canvas.nativeCanvas.drawPoints(bucket.xy, 0, bucket.count * 2, pointPaint)
                    }
                }
                return
            }
            for (level in 1..LEVELS) {
                val path = buckets[slot.ordinal][level]
                if (!path.isEmpty) drawPath(path, color.copy(alpha = level.toFloat() / LEVELS))
            }
        }
        fill(Slot.HAZE, HazeColor)
        fill(Slot.RING, RingColor)
        fill(Slot.MUTUAL, Color.White)

        // Glow brightens toward the front. No blur on every Android version,
        // so two soft strokes stand in for iOS's blurred layer.
        fun bandAlpha(level: Int): Float {
            val front = (level + 0.5f) / 4
            return 0.10f + 0.75f * front * front
        }
        for (level in 0 until 4) {
            if (glow[level].isEmpty) continue
            val a = bandAlpha(level) * 0.6f
            drawPath(glow[level], accent.copy(alpha = a * 0.25f), style = Stroke(width = 8 * dp, cap = StrokeCap.Round))
            drawPath(glow[level], accent.copy(alpha = a * 0.45f), style = Stroke(width = 4 * dp, cap = StrokeCap.Round))
        }
        for (level in 0 until 4) {
            val a = bandAlpha(level)
            if (!faint[level].isEmpty) drawPath(faint[level], ThreadColor.copy(alpha = a * 0.45f), style = Stroke(width = 0.8f * dp))
            if (!strong[level].isEmpty) drawPath(strong[level], ThreadColor.copy(alpha = a), style = Stroke(width = 1.3f * dp))
        }
        if (!dashed.isEmpty) {
            drawPath(dashed, ThreadColor.copy(alpha = 0.7f), style = Stroke(width = 1.2f * dp, cap = StrokeCap.Round,
                join = StrokeJoin.Round, pathEffect = PathEffect.dashPathEffect(floatArrayOf(5 * dp, 4 * dp))))
        }
        fill(Slot.HOT, accent)

        // A soft tint behind each face, and embers for those behind the globe.
        for (spot in spots) {
            val c = Offset(spot.x.toFloat(), spot.y.toFloat())
            if (spot.ember) {
                drawCircle(accent.copy(alpha = spot.alpha.toFloat().coerceIn(0f, 1f)), radius = spot.r.toFloat(), center = c)
                continue
            }
            val r = spot.r.toFloat()
            if (r <= 0f) continue
            drawCircle(
                brush = Brush.radialGradient(
                    0.6f / 1.9f to spot.tint.copy(alpha = 0.35f * spot.alpha.toFloat()),
                    1f to Color.Transparent,
                    center = c, radius = r * 1.9f,
                ),
                radius = r * 1.9f,
                center = c,
            )
        }
    }

    /** Names under the faces, the core, and plain stars once zoomed in. */
    fun drawLabels(scope: DrawScope, measurer: TextMeasurer, name: (String) -> String) = with(scope) {
        prepare(size.width, size.height, density)
        if (!ready) return@with
        val dp = dpPx
        fun label(text: String, x: Double, y: Double, sizeSp: Float, weight: FontWeight, alpha: Float) {
            val layout = measurer.measure(
                text,
                TextStyle(color = Color.White, fontSize = sizeSp.sp, fontWeight = weight),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                constraints = Constraints(maxWidth = (120 * dp).roundToInt()),
            )
            drawText(layout, topLeft = Offset((x - layout.size.width / 2.0).toFloat(), (y - layout.size.height / 2.0).toFloat()),
                alpha = alpha.coerceIn(0f, 1f))
        }
        for (spot in spots) {
            if (spot.core || spot.ember || !spot.label) continue
            val isAuthor = spot.key == author
            label(name(spot.key), spot.x, spot.y + spot.r + 10 * dp, if (isAuthor) 14f else 11f, FontWeight.SemiBold,
                (0.9 * spot.alpha).toFloat())
        }
        for (star in starLabels) {
            label(name(star.key), star.x, star.y + star.r + 8 * dp, 10f, FontWeight.Normal, (0.6 * star.alpha).toFloat())
        }
        spots.lastOrNull()?.takeIf { it.core }?.let { core ->
            label(name(core.key), core.x, core.y + core.r + 11 * dp, 13f, FontWeight.Bold, 1f)
        }
    }

    private fun Path.line(x0: Double, y0: Double, x1: Double, y1: Double) {
        moveTo(x0.toFloat(), y0.toFloat())
        lineTo(x1.toFloat(), y1.toFloat())
    }

    private fun lerp(a: Double, b: Double, t: Double) = a + (b - a) * t

    companion object {
        /** A new globe fades and glides in over this long, then holds still. */
        const val SETTLE_TIME = 1.8
        /**
         * Star brightness is rounded to this many steps, so each kind of star
         * is a handful of fills however many people there are. Fine enough
         * that the faint haze keeps its front-to-back depth.
         */
        const val LEVELS = 40
    }
}
