package com.nostrvault.ui.components

import androidx.activity.compose.BackHandler
import androidx.compose.animation.core.animate
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
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
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.PointMode
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.nostrvault.data.model.ContactList
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.data.model.TrustMap
import com.nostrvault.data.model.TrustPath
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.Motion
import com.nostrvault.ui.theme.NostrVaultIcons
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText
import com.nostrvault.ui.theme.Surface1
import com.nostrvault.ui.theme.Surface2
import com.nostrvault.ui.theme.WindowBackground
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.launch
import java.text.NumberFormat
import kotlin.math.abs
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sqrt

/**
 * One map: who is in the middle and what we know about their follows.
 */
private data class TrustFrame(
    val center: String,
    /** Everyone [center] follows: the dots on the ring. */
    val ring: List<String>,
    /**
     * False when no relay had [center]'s follow list, so the empty ring means
     * "unknown", not "follows no one".
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
    /** Each ring member's spot, worked out once so pinching only scales. */
    val points: Map<String, Pair<Double, Double>> = ring.associateWith { TrustMap.dot(it) },
) {
    val ringSet: Set<String> get() = points.keys
}

/**
 * The Trust Path card opened up into a map, full screen. Someone sits in the
 * middle (you, at first) with every person they follow as a dot on a ring
 * around them, and the author past it. Dots that follow the author light up.
 * Each dot's spot comes from its key ([TrustMap.angle]), so nothing is ever
 * laid out twice: pinching and panning only move the camera, and re-centering
 * on someone swaps the ring for theirs.
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
        Surface(color = WindowBackground, modifier = Modifier.fillMaxSize()) {
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

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun TrustWebContent(
    author: String,
    path: TrustPath,
    onProfileClick: ((String) -> Unit)?,
    onDismiss: () -> Unit,
) {
    val services = rememberTrustPathServices()
    val trust = services.trustPathService()
    val nostrService = services.nostrService()
    val profiles by nostrService.profiles.collectAsState()
    val accent = LocalNostrVaultColors.current.primary
    val scope = rememberCoroutineScope()

    val me = remember { trust.me }
    val myFollows = remember { trust.myFollows().toSet() }
    var crumbs by remember { mutableStateOf(listOf(me)) }
    var frames by remember { mutableStateOf(mapOf(me to TrustFrame(me, trust.myFollows(), true, path))) }
    /** Null until picked: then each frame opens on its own shortest reach. */
    var pickedHops by remember { mutableStateOf<Int?>(null) }
    var peek by remember { mutableStateOf<String?>(null) }
    // Per person, so re-centering mid-load neither blocks nor mislabels the
    // next person's map.
    var loadingMore by remember { mutableStateOf(emptySet<String>()) }
    var lookingDeeper by remember { mutableStateOf(emptySet<String>()) }
    // No relay answered: offer a retry instead of a final answer.
    var failed by remember { mutableStateOf(emptySet<String>()) }
    var deeperFailed by remember { mutableStateOf(emptySet<String>()) }
    var showingList by remember { mutableStateOf(false) }

    val centerKey = crumbs.last()
    val frame = frames[centerKey]
    val hops = pickedHops ?: if (frame?.path?.reach == TrustPath.Reach.FOLLOW) 1 else 2

    fun name(pubkey: String): String =
        if (pubkey == me) "You" else profiles[pubkey]?.bestName ?: "npub…${pubkey.takeLast(6)}"

    LaunchedEffect(Unit) { nostrService.fetchMissingProfiles(listOf(me, author) + path.bridges) }

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

    // 3 hops is a download; don't carry it onto the next person.
    fun recenter() { if (pickedHops == 3) pickedHops = null }

    fun jump(index: Int) {
        if (index >= crumbs.size - 1) return
        peek = null
        crumbs = crumbs.take(index + 1)
        recenter()
    }

    fun tapped(pubkey: String) {
        if (peek != null) { peek = null; return }
        if (pubkey == crumbs.last()) return
        val index = crumbs.indexOf(pubkey)
        if (index >= 0) return jump(index)
        crumbs = crumbs + pubkey
        recenter()
        if (frames[pubkey] != null) return
        scope.launch {
            val list = trust.followList(pubkey)
            val ring = list.orEmpty()
            val found = trust.path(author, pubkey, ring)
            frames = frames + (pubkey to TrustFrame(pubkey, ring, list != null, found))
            nostrService.fetchMissingProfiles(listOf(pubkey) + found.bridges)
            if (pickedHops == 3 && crumbs.last() == pubkey) lookDeeper()
        }
    }

    /**
     * "Show everyone": batches of 20 lists until no relay has more, lighting
     * dots as each batch lands. Stops at [TrustMap.MAX_BATCHED_LISTS] a tap.
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

    fun openProfile(pubkey: String) {
        peek = null
        showingList = false
        onProfileClick?.invoke(pubkey)
    }

    // Back steps along the breadcrumbs before it closes the map.
    BackHandler(enabled = crumbs.size > 1) { jump(crumbs.size - 2) }

    Column(Modifier.fillMaxSize().safeDrawingPadding()) {
        TopBar(
            title = if (centerKey == me) "Web of Trust" else name(centerKey),
            onDone = onDismiss,
            onList = { showingList = true },
        )

        // ── Header ──────────────────────────────────────────────
        Column(
            verticalArrangement = Arrangement.spacedBy(10.dp),
            modifier = Modifier.fillMaxWidth().padding(top = 4.dp, bottom = 4.dp),
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp),
                modifier = Modifier.horizontalScroll(rememberScrollState()).padding(horizontal = 16.dp),
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
            HopSwitch(hops = hops, onSelect = { picked ->
                pickedHops = picked
                if (picked == 3 && frames[crumbs.last()]?.chains == null) lookDeeper()
            })
            Text(
                text = explainer(frame, hops, me, author, centerKey, ::name, myFollows,
                    lookingDeeper = frame?.center in lookingDeeper,
                    deeperFailed = frame?.center in deeperFailed, accent = accent),
                color = SecondaryText,
                fontSize = 13.sp,
                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp),
            )
        }

        // ── Map ─────────────────────────────────────────────────
        Box(Modifier.weight(1f).fillMaxWidth().clipToBounds()) {
            if (frame != null) {
                // A fresh camera per person: re-centering starts zoomed out.
                key(frame.center) {
                    TrustMapCanvas(
                        frame = frame, me = me, author = author, hops = hops, myFollows = myFollows,
                        accent = accent, profiles = profiles, name = ::name,
                        onTap = ::tapped, onPeek = { peek = it },
                        onFaces = { nostrService.fetchMissingProfiles(it) },
                    )
                }
            } else {
                CircularProgressIndicator(color = accent, modifier = Modifier.align(Alignment.Center))
            }
            peek?.let { pubkey ->
                PeekCard(
                    pubkey = pubkey, name = name(pubkey), profile = profiles[pubkey], accent = accent,
                    line = listOfNotNull(
                        when { pubkey == me -> "You"; pubkey in myFollows -> "You follow"; else -> "Not someone you follow" },
                        when {
                            pubkey == author -> null
                            frame?.bridges?.contains(pubkey) == true || frame?.chains?.any { it.via == pubkey } == true ->
                                "follows ${name(author)}"
                            else -> "not seen following ${name(author)}"
                        },
                    ).joinToString(" · "),
                    onProfile = onProfileClick?.let { { openProfile(pubkey) } },
                    modifier = Modifier.align(Alignment.BottomStart),
                )
            }
        }

        // ── Footer ──────────────────────────────────────────────
        Column(
            verticalArrangement = Arrangement.spacedBy(10.dp),
            modifier = Modifier.fillMaxWidth().padding(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 12.dp),
        ) {
            if (frame != null && frame.listFound) {
                val count = "${frame.bridges.size}${if (frame.exhausted) "" else "+"}"
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    LegendDot(SecondaryText)
                    Text(
                        "${NumberFormat.getIntegerInstance().format(frame.ring.size)} " +
                            if (frame.center == me) "you follow" else "${name(frame.center)} follows",
                        color = SecondaryText, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f, fill = false),
                    )
                    Spacer(Modifier.weight(1f).widthIn(min = 8.dp))
                    if (frame.bridges.isNotEmpty() && hops >= 2) {
                        LegendDot(accent)
                        Text("$count follow ${name(author)}", color = accent, fontSize = 12.sp, maxLines = 1,
                            overflow = TextOverflow.Ellipsis)
                    }
                }
                if (hops == 3 && frame.center in deeperFailed) {
                    FooterButton("Try again", accent, filled = false, onClick = ::lookDeeper)
                } else if (canLoadMore(frame, hops)) {
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
            if (centerKey != me && onProfileClick != null) {
                FooterButton("View ${name(centerKey)}'s profile", accent, filled = true) { openProfile(centerKey) }
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

private fun canLoadMore(frame: TrustFrame, hops: Int): Boolean =
    hops >= 2 && !frame.exhausted && frame.bridges.isNotEmpty() &&
        (frame.path.hasMore || frame.bridges.size > TrustPath.SHOWN_BRIDGES)

private fun explainer(
    frame: TrustFrame?,
    hops: Int,
    me: String,
    author: String,
    centerKey: String,
    name: (String) -> String,
    myFollows: Set<String>,
    lookingDeeper: Boolean,
    deeperFailed: Boolean,
    accent: Color,
): AnnotatedString = buildAnnotatedString {
    if (frame == null) {
        append("Loading who ${name(centerKey)} follows…")
        return@buildAnnotatedString
    }
    val them = name(author)
    val center = if (frame.center == me) null else name(frame.center)
    fun count(text: String, color: Color = accent) =
        withStyle(SpanStyle(color = color, fontWeight = FontWeight.Bold)) { append(text) }
    val bridges = "${frame.bridges.size}${if (frame.exhausted) "" else "+"}"
    when {
        !frame.listFound -> append("No relay checked had ${name(frame.center)}'s follow list, so their ring can't be drawn.")
        hops == 3 -> {
            val chains = frame.chains
            when {
                lookingDeeper -> append("Looking two steps further out. This downloads a few MB of follow lists.")
                deeperFailed -> append("Couldn't reach the relays to look deeper.")
                chains != null && chains.isNotEmpty() -> {
                    count("${chains.map { it.via }.toSet().size}")
                    append(" people who follow $them are followed by ${center?.let { "people $it follows" } ?: "people you follow"} · 3 hops.")
                }
                chains != null -> append("No 3-hop route turned up in the follow lists checked.")
                else -> append("Looking deeper: two steps further out.")
            }
        }
        frame.center == author -> append("Everyone $them follows. Tap a face to see their path.")
        author in frame.ringSet && hops == 1 ->
            append("${center ?: "You"} ${if (center == null) "follow" else "follows"} $them directly · 1 hop.")
        frame.bridges.isNotEmpty() && hops == 2 -> if (center != null) {
            append("$center reaches $them through ")
            count(bridges)
            append(" of their follows · 2 hops. ")
            count("${frame.ring.count { it in myFollows }}", PrimaryText)
            append(" of $center's follows are people you follow too (bright dots).")
        } else {
            append("Followed by ")
            count(bridges)
            append(" people you follow · 2 hops. Pinch to zoom, tap a face to follow their path.")
        }
        author in frame.ringSet ->
            append("${center ?: "You"} ${if (center == null) "follow" else "follows"} $them directly. Switch to 2 hops to see who else does.")
        else -> append(
            when (frame.path.reach) {
                TrustPath.Reach.WEB -> "In your Web of Trust through people further out. 3 hops looks deeper."
                TrustPath.Reach.OUTSIDE -> "Not in your web. No one you follow follows them, in the lists checked."
                TrustPath.Reach.UNKNOWN -> if (center != null) "None of $center's follows that were checked follow $them. 3 hops looks deeper."
                    else "Your trust graph hasn't loaded yet."
                else -> "Pinch to zoom, tap a face to follow their path."
            },
        )
    }
}

// ── Small pieces ─────────────────────────────────────────────────────

@Composable
private fun TopBar(title: String, onDone: () -> Unit, onList: (() -> Unit)?) {
    val accent = LocalNostrVaultColors.current.primary
    Box(Modifier.fillMaxWidth().height(48.dp).padding(horizontal = 8.dp)) {
        TextButton(onClick = onDone, modifier = Modifier.align(Alignment.CenterStart)) {
            Text("Done", color = accent, fontSize = 16.sp)
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
        if (onList != null) {
            IconButton(onClick = onList, modifier = Modifier.align(Alignment.CenterEnd)) {
                Icon(NostrVaultIcons.PeopleList, contentDescription = "People on this map", tint = accent)
            }
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
            .background(if (on) accent.copy(alpha = 0.18f) else Surface2)
            .then(if (destination) Modifier.border(1.dp, accent.copy(alpha = 0.5f), shape) else Modifier)
            .then(if (onClick != null) Modifier.clickable(role = Role.Button, onClickLabel = "Go back to this step", onClick = onClick) else Modifier)
            .padding(start = 3.dp, end = 10.dp, top = 3.dp, bottom = 3.dp)
            .then(if (destination) Modifier.clearAndSetSemantics { contentDescription = "Looking for $name" } else Modifier),
    ) {
        AvatarImage(url = profile?.pictureURL, pubkey = pubkey, size = 22.dp, displayName = profile?.bestName)
        Text(name, color = if (destination) accent else PrimaryText, fontSize = 13.sp, maxLines = 1)
    }
}

/** 1 / 2 / 3 hops, in the same segmented style as the follow list's tabs. */
@Composable
private fun HopSwitch(hops: Int, onSelect: (Int) -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp)
            .height(36.dp)
            .clip(RoundedCornerShape(10.dp))
            .background(Surface1)
            .padding(3.dp),
    ) {
        for (option in 1..3) {
            val selected = option == hops
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier
                    .weight(1f)
                    .fillMaxSize()
                    .clip(RoundedCornerShape(8.dp))
                    .background(if (selected) Surface2 else Color.Transparent)
                    .clickable(role = Role.Tab) { onSelect(option) },
            ) {
                Text(
                    if (option == 1) "1 hop" else "$option hops",
                    color = PrimaryText,
                    fontSize = 13.sp,
                    fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
                    maxLines = 1,
                )
            }
        }
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
            .background(if (filled) accent else Surface2)
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

/** The map as a list: for TalkBack, and anyone who'd rather read. */
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
                item { ListHeader("3 hops") }
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
                    Text("No one on this map follows ${name(author)} yet.", color = SecondaryText, fontSize = 15.sp,
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

// ── The map ──────────────────────────────────────────────────────────

/** Lit people drawn as faces; the rest stay dots. */
private const val MAX_FACES = 12
/** Extra faces when zoomed in on part of the ring. */
private const val MAX_ZOOM_FACES = 40
private const val ZOOM_FACES_AT = 3.5f
private const val NAMES_AT = 1.8f
private const val OUTER_R = 1.45
private const val VIA_R = 1.24
private const val MAX_SCALE = 16f

private class Face(
    val pubkey: String,
    val point: Offset,
    /** Avatar diameter, dp. */
    val size: Float,
    val ring: Color,
    val lit: Boolean,
    val label: Boolean,
    val main: Boolean,
)

/**
 * The map itself: one Canvas for the ring, dots and lines, plus a few dozen
 * faces on top. World units: the ring has radius 1 around the centre.
 */
@OptIn(FlowPreview::class)
@Composable
private fun TrustMapCanvas(
    frame: TrustFrame,
    me: String,
    author: String,
    hops: Int,
    myFollows: Set<String>,
    accent: Color,
    profiles: Map<String, FeedProfile>,
    name: (String) -> String,
    onTap: (String) -> Unit,
    onPeek: (String) -> Unit,
    /** The faces on screen after a gesture, so their pictures can load. */
    onFaces: (List<String>) -> Unit,
) {
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val density = LocalDensity.current
        val w = constraints.maxWidth.toFloat()
        val h = constraints.maxHeight.toFloat()
        val dp = density.density
        var scale by remember { mutableFloatStateOf(1f) }
        var offset by remember { mutableStateOf(Offset.Zero) }
        val baseR = min(w, h) / 2f / 1.62f

        fun screen(p: Pair<Double, Double>): Offset {
            val k = baseR * scale
            return Offset(w / 2 + offset.x + p.first.toFloat() * k, h / 2 + offset.y + p.second.toFloat() * k)
        }

        fun world(pubkey: String): Pair<Double, Double> = when {
            pubkey == frame.center -> 0.0 to 0.0
            else -> frame.points[pubkey]
                ?: TrustMap.polar(TrustMap.angle(pubkey), if (pubkey == author || pubkey == me) OUTER_R else VIA_R)
        }

        val litBridges = if (hops >= 2) frame.bridges else emptyList()
        val chains = if (hops == 3) frame.chains.orEmpty() else emptyList()

        // Everyone drawn as a face besides the centre, most important first. A
        // face only goes where it doesn't cover one already placed; whoever
        // doesn't fit stays a dot until zooming makes room.
        val faces = run {
            val out = ArrayList<Face>()
            val placed = hashSetOf(frame.center)
            val taken = arrayListOf(screen(0.0 to 0.0) to Offset(30 * dp, 34 * dp))
            val pad = 12 * dp
            fun add(pubkey: String, size: Float, color: Color, lit: Boolean, label: Boolean, always: Boolean = false) {
                if (pubkey in placed) return
                val point = screen(world(pubkey))
                // Half the box the face (and its name, which hangs below) needs.
                val half = Offset(
                    (if (label) maxOf(size / 2, 26f) else size / 2 + 2) * dp,
                    (if (label) size / 2 + 9 else size / 2 + 2) * dp,
                )
                if (!always) {
                    if (point.x < -pad || point.y < -pad || point.x > w + pad || point.y > h + pad) return
                    val clear = taken.all { (p, o) -> abs(p.x - point.x) >= o.x + half.x || abs(p.y - point.y) >= o.y + half.y }
                    if (!clear) return
                }
                placed += pubkey
                taken += point to half
                out += Face(pubkey, point, size, color, lit, label, main = pubkey == author)
            }
            val grow = min(1.5f, sqrt(scale))
            val named = scale >= NAMES_AT
            if (frame.center != author) add(author, 38f, accent, lit = true, label = true, always = true)
            if (frame.center != me) add(me, 28f, SecondaryText, lit = false, label = true, always = true)
            for (pubkey in TrustMap.spread(litBridges, MAX_FACES)) add(pubkey, 24 * grow, accent, lit = true, label = named)
            for (chain in chains.take(TrustMap.SHOWN_CHAINS)) {
                add(chain.via, 22 * grow, accent, lit = true, label = named)
                add(chain.bridge, 22 * grow, accent, lit = true, label = named)
            }
            if (scale >= ZOOM_FACES_AT) {
                val lit = litBridges.toSet()
                val before = out.size
                // Lit people first, so a zoomed arc names who matters before
                // everyone else around them.
                for (pubkey in litBridges + frame.ring.filter { it !in lit }) {
                    if (out.size - before >= MAX_ZOOM_FACES) break
                    val isLit = pubkey in lit
                    add(pubkey, 20 * grow, if (isLit) accent else SecondaryText.copy(alpha = 0.5f), lit = isLit, label = true)
                }
            }
            out += Face(frame.center, screen(0.0 to 0.0), 46f, if (frame.center == me) PrimaryText else accent,
                lit = true, label = true, main = true)
            out
        }
        val faceKeys = faces.mapTo(HashSet()) { it.pubkey }
        val currentFaces by rememberUpdatedState(faces)

        // After a gesture settles: keep some of the ring on screen however far
        // it was dragged, and load pictures for whoever became a face.
        LaunchedEffect(w, h) {
            // Debounced, not collectLatest: the glide below writes offset every
            // frame, and each write would otherwise cancel the glide.
            snapshotFlow { scale to offset }.debounce(200).collect { (s, o) ->
                val limit = baseR * s * 1.5f
                val clamped = Offset(o.x.coerceIn(-limit, limit), o.y.coerceIn(-limit, limit))
                if (clamped != o) {
                    if (Motion.isReduced) offset = clamped
                    else animate(0f, 1f, animationSpec = tween(250)) { v, _ -> offset = o + (clamped - o) * v }
                }
                onFaces(currentFaces.map { it.pubkey })
            }
        }

        val scope = rememberCoroutineScope()
        fun reset() {
            val fromScale = scale
            val fromOffset = offset
            if (Motion.isReduced) { scale = 1f; offset = Offset.Zero; return }
            scope.launch {
                animate(0f, 1f, animationSpec = tween(350)) { v, _ ->
                    scale = fromScale + (1f - fromScale) * v
                    offset = fromOffset * (1f - v)
                }
            }
        }

        Box(
            Modifier
                .fillMaxSize()
                .pointerInput(frame.center) {
                    detectTapGestures(onDoubleTap = { reset() }, onTap = { onTap(frame.center) })
                }
                .pointerInput(frame.center, w, h) {
                    detectTransformGestures { centroid, pan, zoom, _ ->
                        val newScale = (scale * zoom).coerceIn(1f, MAX_SCALE)
                        val k = newScale / scale
                        // Zoom about the pinch point, not the middle of the view.
                        val anchor = centroid - Offset(w / 2, h / 2)
                        offset = anchor + (offset - anchor) * k + pan
                        scale = newScale
                    }
                }
                .semantics { contentDescription = "Web of Trust map" },
        ) {
            Canvas(Modifier.fillMaxSize().clearAndSetSemantics { }) {
                val k = baseR * scale
                val c = screen(0.0 to 0.0)
                val authorOnRing = author in frame.ringSet
                val authorPoint = screen(world(author))
                val lit = litBridges.toSet()

                // The ring as a soft band.
                drawCircle(Color.White.copy(alpha = 0.06f), radius = k, center = c,
                    style = Stroke(width = (2 * TrustMap.BAND_WIDTH.toFloat() + 0.04f) * k))

                // Lines first, under the dots.
                val faint = Path(); val strong = Path(); val dashed = Path(); val grey = Path()
                fun Path.line(vararg points: Offset) {
                    moveTo(points[0].x, points[0].y)
                    for (p in points.drop(1)) lineTo(p.x, p.y)
                }
                for (pubkey in litBridges) {
                    val p = screen(world(pubkey))
                    if (pubkey in faceKeys) strong.line(c, p, authorPoint) else faint.line(p, authorPoint)
                }
                if (authorOnRing && frame.center != author) strong.line(c, authorPoint)
                for (chain in chains) {
                    val b = screen(world(chain.bridge)); val v = screen(world(chain.via))
                    if (chain.via in faceKeys) dashed.line(c, b, v, authorPoint) else faint.line(v, authorPoint)
                }
                if (frame.center != me) grey.line(screen(world(me)), c)
                if (hops == 2 && litBridges.isEmpty() && !authorOnRing && frame.center != author) {
                    when (frame.path.reach) {
                        TrustPath.Reach.WEB -> dashed.line(c, authorPoint)
                        TrustPath.Reach.OUTSIDE, TrustPath.Reach.UNKNOWN ->
                            grey.line(c, screen(TrustMap.polar(TrustMap.angle(author), 1.12)))
                        else -> Unit
                    }
                }
                drawPath(faint, accent.copy(alpha = 0.18f), style = Stroke(width = 1 * dp))
                drawPath(grey, SecondaryText.copy(alpha = 0.6f), style = Stroke(width = 1.5f * dp, cap = StrokeCap.Round,
                    pathEffect = PathEffect.dashPathEffect(floatArrayOf(4 * dp, 4 * dp))))
                drawPath(dashed, accent.copy(alpha = 0.85f), style = Stroke(width = 1.6f * dp, cap = StrokeCap.Round,
                    join = StrokeJoin.Round, pathEffect = PathEffect.dashPathEffect(floatArrayOf(5 * dp, 4 * dp))))
                drawPath(strong, accent.copy(alpha = 0.9f), style = Stroke(width = 1.8f * dp, cap = StrokeCap.Round,
                    join = StrokeJoin.Round))

                // Dots: three draws for the whole ring, however many people are on it.
                val grow = min(2f, sqrt(scale))
                val dim = ArrayList<Offset>(); val bright = ArrayList<Offset>(); val hot = ArrayList<Offset>()
                val showMutual = frame.center != me
                for ((pubkey, point) in frame.points) {
                    if (pubkey in faceKeys) continue
                    val p = screen(point)
                    if (p.x < -8 * dp || p.y < -8 * dp || p.x > w + 8 * dp || p.y > h + 8 * dp) continue
                    when {
                        pubkey in lit -> hot += p
                        showMutual && pubkey in myFollows -> bright += p
                        else -> dim += p
                    }
                }
                for (chain in chains) if (chain.via !in faceKeys) hot += screen(world(chain.via))
                drawPoints(dim, PointMode.Points, Color.White.copy(alpha = 0.28f), strokeWidth = 2 * 1.4f * grow * dp, cap = StrokeCap.Round)
                drawPoints(bright, PointMode.Points, Color.White.copy(alpha = 0.7f), strokeWidth = 2 * 1.9f * grow * dp, cap = StrokeCap.Round)
                drawPoints(hot, PointMode.Points, accent, strokeWidth = 2 * 2.6f * grow * dp, cap = StrokeCap.Round)
            }

            // Each face centred on its point (the avatar, not avatar + name).
            Layout(
                content = {
                    for (face in faces) {
                        FaceView(face, name(face.pubkey), profiles[face.pubkey], isCenter = face.pubkey == frame.center,
                            onTap = onTap, onPeek = onPeek)
                    }
                },
                modifier = Modifier.fillMaxSize(),
            ) { measurables, constraints ->
                val placeables = measurables.map { it.measure(Constraints()) }
                layout(constraints.maxWidth, constraints.maxHeight) {
                    placeables.forEachIndexed { i, placeable ->
                        val face = faces[i]
                        placeable.place(
                            (face.point.x - placeable.width / 2f).roundToInt(),
                            (face.point.y - face.size * dp / 2f).roundToInt(),
                        )
                    }
                }
            }

            if (scale > 1.05f) {
                Text(
                    String.format("%.1f×", scale),
                    color = SecondaryText,
                    fontSize = 11.sp,
                    fontFamily = FontFamily.Monospace,
                    modifier = Modifier.align(Alignment.BottomStart).padding(10.dp).clearAndSetSemantics { },
                )
            }
        }
    }
}

@Composable
private fun FaceView(
    face: Face,
    name: String,
    profile: FeedProfile?,
    isCenter: Boolean,
    onTap: (String) -> Unit,
    onPeek: (String) -> Unit,
) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(3.dp),
        modifier = Modifier
            .pointerInput(face.pubkey) {
                detectTapGestures(onTap = { onTap(face.pubkey) }, onLongPress = { onPeek(face.pubkey) })
            }
            .clearAndSetSemantics {
                contentDescription = name
                role = Role.Button
                onClick(label = if (isCenter) null else "Move them to the middle of the map") { onTap(face.pubkey); true }
                customActions = listOf(CustomAccessibilityAction("Details") { onPeek(face.pubkey); true })
            },
    ) {
        AvatarImage(
            url = profile?.pictureURL,
            pubkey = face.pubkey,
            size = face.size.dp,
            displayName = profile?.bestName,
            modifier = Modifier
                .background(WindowBackground, CircleShape)
                .border(2.dp, face.ring, CircleShape),
        )
        if (face.label) {
            Text(
                name,
                color = if (face.lit) PrimaryText else SecondaryText,
                fontSize = if (face.main) 12.sp else 10.sp,
                fontWeight = if (face.lit) FontWeight.SemiBold else FontWeight.Normal,
                maxLines = 1,
                // Lines run under the labels; a backing keeps names legible.
                modifier = Modifier
                    .background(WindowBackground.copy(alpha = 0.75f), RoundedCornerShape(50))
                    .padding(horizontal = 4.dp),
            )
        }
    }
}
