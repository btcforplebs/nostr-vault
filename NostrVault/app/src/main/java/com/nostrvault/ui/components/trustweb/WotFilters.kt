package com.nostrvault.ui.components

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.SwapHoriz
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Stable
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.vector.ImageVector
import com.nostrvault.data.model.FollowerSnapshot
import com.nostrvault.data.model.TrustMap
import com.nostrvault.relay.HavenBridge
import com.nostrvault.ui.theme.NostrVaultIcons
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** The filter icons, iOS `TrustMap.Filter.symbolName`. */
internal val TrustMap.Filter.icon: ImageVector
    get() = when (this) {
        TrustMap.Filter.TALK -> NostrVaultIcons.Chat
        TrustMap.Filter.FOLLOWS_BACK -> Icons.Filled.SwapHoriz
    }

/** What the filters are measured against, read fresh on every change. */
internal data class WotFilterInputs(
    val follows: Set<String>,
    /** Your whole web from the relay, follows included. */
    val web: Set<String>,
    /** How much you and each person interact ([TrustMap.engagementScores]). */
    val engagement: Map<String, Int>,
)

/**
 * The WOT tab's filters: which are on, who each matches, and who they leave
 * lit. Talk with you comes from your engagement, Follow you back from the
 * relay's follower ledger. iOS `TrustWebView` filters (`TrustWebView+FacesAndFilters`).
 */
@Stable
internal class WotFilters(
    private val me: String,
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

    private val matches by derivedStateOf {
        val now = inputs()
        mapOf(
            TrustMap.Filter.TALK to now.engagement.keys.filterTo(HashSet()) { it in now.follows || it in now.web },
            TrustMap.Filter.FOLLOWS_BACK to followsBack.intersect(now.follows),
        )
    }

    /**
     * Who the filters that are on leave lit; null when none is on. Until the
     * ledger is read Follow you back dims no one.
     */
    val lit: Set<String>? by derivedStateOf {
        var ready = on
        if (followsBackLoaded != true) ready = ready - TrustMap.Filter.FOLLOWS_BACK
        // None on: skip building the matches, which run over your whole web.
        if (ready.isEmpty()) null else TrustMap.lit(ready, matches)
    }

    /** How many [filter] matches; null for Follow you back until the ledger is read. */
    fun count(filter: TrustMap.Filter): Int? =
        if (filter == TrustMap.Filter.FOLLOWS_BACK && followsBackLoaded != true) null
        else matches[filter]?.size ?: 0

    /** The ledger hasn't been read yet. */
    val followsBackChecking: Boolean get() = followsBackLoaded == null

    /** Reads the follower ledger once, for My Web's Follow you back row. */
    fun readFollowsBack() {
        if (followsBackLoaded == null) loadFollowsBack()
    }

    /** Turns [filter] on; one already on stays on (My Web's rows). */
    fun turnOn(filter: TrustMap.Filter) {
        if (filter !in on) toggle(filter)
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
            on.size <= 1 && isOn -> tapped.count(matches[tapped]?.size ?: 0)
            else -> lit?.let { lit ->
                val n = java.text.NumberFormat.getIntegerInstance().format(lit.size)
                "$n ${if (lit.size == 1) "matches" else "match"} ${if (on.size == 2) "both" else "all ${on.size}"}"
            } ?: "${tapped.title} off"
        }
        note.show(FilterNote(if (isOn) tapped.icon else NostrVaultIcons.FilterOff, text))
    }

    private var loadingFollowsBack = false

    private fun loadFollowsBack() {
        if (loadingFollowsBack) return
        loadingFollowsBack = true
        scope.launch {
            val followers = withContext(Dispatchers.IO) {
                runCatching { FollowerSnapshot.parse(HavenBridge.getFollowers(me)) }.getOrNull()
                    ?.current?.mapTo(HashSet()) { it.pubkey }
            }
            followsBack = followers.orEmpty()
            followsBackLoaded = followers != null
            loadingFollowsBack = false
            // The note still says "Checking…": say what it found.
            if (TrustMap.Filter.FOLLOWS_BACK in on && note.note != null) showNote(TrustMap.Filter.FOLLOWS_BACK)
        }
    }
}

/** The WOT tab's filters for [me]. */
@Composable
internal fun rememberWotFilters(me: String, inputs: WotFilterInputs): WotFilters {
    val note = rememberFilterNoteState()
    val scope = rememberCoroutineScope()
    val latest = rememberUpdatedState(inputs)
    val filters = remember(me) {
        WotFilters(me, scope, note) { latest.value }
    }
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
