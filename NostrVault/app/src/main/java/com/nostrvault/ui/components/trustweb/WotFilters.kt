package com.nostrvault.ui.components

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.SwapHoriz
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.Stable
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import com.nostrvault.data.model.FollowerSnapshot
import com.nostrvault.data.model.TrustMap
import com.nostrvault.relay.HavenBridge
import com.nostrvault.ui.theme.NostrVaultIcons
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.Json
import java.io.File

/** The filter icons, iOS `TrustMap.Filter.symbolName`. */
internal val TrustMap.Filter.icon: ImageVector
    get() = when (this) {
        TrustMap.Filter.TALK -> NostrVaultIcons.Chat
        TrustMap.Filter.FOLLOWS_BACK -> Icons.Filled.SwapHoriz
        TrustMap.Filter.NEW -> NostrVaultIcons.Sparkles
    }

/** What the filters are measured against, read fresh on every change. */
internal data class WotFilterInputs(
    val follows: Set<String>,
    /** Your whole web from the relay, follows included. */
    val web: Set<String>,
    /** How much you and each person interact ([TrustMap.engagementScores]). */
    val engagement: Map<String, Int>,
    /** People a running rebuild has found that weren't on the old map. */
    val arrivals: Set<String>,
)

/**
 * The WOT tab's filters: which are on, who each matches, and who they leave
 * lit. Talk with you comes from your engagement, Follow you back from the
 * relay's follower ledger, and New from your web as of your last look, kept
 * per account. iOS `TrustWebView` filters (`TrustWebView+FacesAndFilters`).
 */
@Stable
internal class WotFilters(
    private val me: String,
    private val seenFile: File,
    private val scope: CoroutineScope,
    val note: FilterNoteState,
    private val inputs: () -> WotFilterInputs,
) {
    /** The filter icons that are on. */
    var on by mutableStateOf(emptySet<TrustMap.Filter>())
        private set
    /** Your follows who follow you, from the relay's follower ledger. */
    private var followsBack by mutableStateOf(emptySet<String>())
    /** The ledger was read: null before, false when the relay had none. */
    private var followsBackLoaded by mutableStateOf<Boolean?>(null)
    /** Your web as of your last look, for New; null before a first look. */
    private var seenWeb by mutableStateOf<Set<String>?>(null)

    private val matches by derivedStateOf {
        val now = inputs()
        mapOf(
            TrustMap.Filter.TALK to now.engagement.keys.filterTo(HashSet()) { it in now.follows || it in now.web },
            TrustMap.Filter.FOLLOWS_BACK to followsBack.intersect(now.follows),
            TrustMap.Filter.NEW to TrustMap.newcomers(now.web, seenWeb) + now.arrivals,
        )
    }

    /**
     * Who the filters that are on leave lit; null when none is on. Until the
     * ledger is read Follow you back dims no one, nor does New before there's
     * a last look to compare with.
     */
    val lit: Set<String>? by derivedStateOf {
        var ready = on
        if (followsBackLoaded != true) ready = ready - TrustMap.Filter.FOLLOWS_BACK
        if (seenWeb == null && inputs().arrivals.isEmpty()) ready = ready - TrustMap.Filter.NEW
        // None on: skip building the matches, which run over your whole web.
        if (ready.isEmpty()) null else TrustMap.lit(ready, matches)
    }

    fun toggle(filter: TrustMap.Filter) {
        on = if (filter in on) on - filter else on + filter
        if (filter == TrustMap.Filter.FOLLOWS_BACK && filter in on && followsBackLoaded != true) loadFollowsBack()
        showNote(filter)
    }

    /** "214 talk with you" for one filter on; with more, how many match them all. */
    private fun showNote(tapped: TrustMap.Filter) {
        val isOn = tapped in on
        val text = when {
            isOn && tapped == TrustMap.Filter.FOLLOWS_BACK && followsBackLoaded == false -> "Your relay has no follower list yet"
            isOn && tapped == TrustMap.Filter.FOLLOWS_BACK && followsBackLoaded == null -> "Checking who follows you back…"
            // Nothing to compare with yet: the first look sets the baseline.
            on.size <= 1 && isOn && tapped == TrustMap.Filter.NEW && seenWeb == null && inputs().arrivals.isEmpty() ->
                "New people show from your next visit"
            on.size <= 1 && isOn -> tapped.count(matches[tapped]?.size ?: 0)
            else -> lit?.let { lit ->
                val n = java.text.NumberFormat.getIntegerInstance().format(lit.size)
                "$n ${if (lit.size == 1) "matches" else "match"} ${if (on.size == 2) "both" else "all ${on.size}"}"
            } ?: "${tapped.title} off"
        }
        note.show(FilterNote(if (isOn) tapped.icon else NostrVaultIcons.FilterOff, text))
    }

    private fun loadFollowsBack() {
        scope.launch {
            val followers = withContext(Dispatchers.IO) {
                runCatching { FollowerSnapshot.parse(HavenBridge.getFollowers(me)) }.getOrNull()
                    ?.current?.mapTo(HashSet()) { it.pubkey }
            }
            followsBack = followers.orEmpty()
            followsBackLoaded = followers != null
            // The note still says "Checking…": say what it found.
            if (TrustMap.Filter.FOLLOWS_BACK in on && note.note != null) showNote(TrustMap.Filter.FOLLOWS_BACK)
        }
    }

    suspend fun loadSeenWeb() {
        seenWeb = withContext(Dispatchers.IO) {
            runCatching { Json.decodeFromString(SEEN_SERIALIZER, seenFile.readText()).toSet() }.getOrNull()
        }
    }

    /** Leaving the tab: what's here now is what the next look compares with. */
    fun saveSeenWeb() {
        val current = inputs().web.toList()
        if (current.isEmpty()) return
        // The tab's own scope is cancelled as it goes, so the write runs on its own.
        CoroutineScope(SupervisorJob() + Dispatchers.IO).launch {
            runCatching {
                val temp = File(seenFile.parentFile, seenFile.name + ".tmp")
                temp.writeText(Json.encodeToString(SEEN_SERIALIZER, current))
                temp.renameTo(seenFile)
            }
        }
    }

    private companion object {
        val SEEN_SERIALIZER = ListSerializer(String.serializer())
    }
}

/**
 * The WOT tab's filters for [me]: they start off each visit, and the visit's
 * web is saved as you leave. Not [active] (a post's globe), nothing is read
 * or saved, so a popup never moves the tab's last look.
 */
@Composable
internal fun rememberWotFilters(me: String, inputs: WotFilterInputs, active: Boolean): WotFilters {
    val context = LocalContext.current
    val note = rememberFilterNoteState()
    val scope = rememberCoroutineScope()
    val latest = rememberUpdatedState(inputs)
    val filters = remember(me) {
        WotFilters(me, File(context.cacheDir, "wot_seen_$me.json"), scope, note) { latest.value }
    }
    LaunchedEffect(filters, active) { if (active) filters.loadSeenWeb() }
    DisposableEffect(filters, active) { onDispose { if (active) filters.saveSeenWeb() } }
    return filters
}

/**
 * Who a filter's faces are drawn from: the people it lights past your follows,
 * the ones you interact with most first, then the most vouched for.
 */
internal fun filterFaceCandidates(
    lit: Set<String>?,
    follows: Set<String>,
    engagement: Map<String, Int>,
    vouches: Map<String, Int>?,
    count: Int,
): List<String> {
    if (lit == null) return emptyList()
    return (lit - follows).sortedWith(
        compareByDescending<String> { engagement[it] ?: 0 }.thenByDescending { vouches?.get(it) ?: 0 }.thenBy { it },
    ).take(count)
}
