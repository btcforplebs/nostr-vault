package com.nostrvault.ui.screens.profile

import androidx.compose.foundation.layout.PaddingValues
import com.nostrvault.ui.navigation.FloatingNavBarInset
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import com.nostrvault.ui.theme.Motion
import kotlinx.coroutines.flow.filter
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.relay.HavenBridge
import com.nostrvault.ui.theme.NostrVaultIcons
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText
import com.nostrvault.ui.theme.SeparatorColor
import com.nostrvault.ui.theme.WindowBackground
import kotlinx.coroutines.flow.map

// ── Screen ───────────────────────────────────────────────────────────

/**
 * The page a profile's FOLLOWING / FOLLOWERS counts open: a Following |
 * Followers switch and search pinned on a solid header, then three groups
 * with sticky headers. Tapping a row opens that profile on the same back
 * stack. Port of iOS `FollowListView`.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun FollowListScreen(
    onProfileClick: (String) -> Unit,
    onBack: () -> Unit,
    viewModel: FollowListViewModel = hiltViewModel(),
) {
    val following by viewModel.following.collectAsState()
    val followers by viewModel.followers.collectAsState()
    val exhausted by viewModel.followersExhausted.collectAsState()
    val pagesDone by viewModel.pagesDone.collectAsState()
    val isOwnLedger by viewModel.isOwnLedger.collectAsState()
    val followersTotal by viewModel.followersTotal.collectAsState()
    val followsViewer by viewModel.followsViewer.collectAsState()
    val hidden by viewModel.hidden.collectAsState()
    val blocked by viewModel.blocked.collectAsState()
    val webOfTrust by viewModel.webOfTrust.collectAsState()
    val trustRank by viewModel.trustRank.collectAsState()
    val followedList by viewModel.followed.collectAsState()
    val queued by viewModel.queued.collectAsState()
    val profiles by viewModel.profiles.collectAsState()
    val followed = remember(followedList) { followedList.toHashSet() }
    val accountChanged by viewModel.accountChanged.collectAsState()
    LaunchedEffect(accountChanged) { if (accountChanged) onBack() }

    var tab by rememberSaveable { mutableStateOf(viewModel.startTab) }
    var query by rememberSaveable { mutableStateOf("") }
    var showOutside by rememberSaveable { mutableStateOf(false) }
    var sorts by remember { mutableStateOf(FollowListSortMemory.sorts.toMap()) }
    val sort = sorts[tab] ?: FollowListSort.TRUSTED
    // Stops at the profile's own count: no further pages, and no "N+" (iOS).
    val haveMore = FollowListLogic.followersHaveMore(isOwnLedger, exhausted, followersTotal, followers.size)
    val listState = rememberLazyListState()
    val keyboard = LocalSoftwareKeyboardController.current
    val focusManager = LocalFocusManager.current
    // Scrolling the list hides the keyboard (iOS scrollDismissesKeyboard).
    LaunchedEffect(listState) {
        snapshotFlow { listState.isScrollInProgress }.filter { it }.collect {
            keyboard?.hide()
            focusManager.clearFocus()
        }
    }

    val people = remember(tab, following, followers, profiles) {
        when (tab) {
            FollowListTab.FOLLOWING -> following.mapIndexed { i, key -> person(key, i.toLong(), profiles[key]) }
            FollowListTab.FOLLOWERS -> followers.map { (key, at) -> person(key, at, profiles[key]) }
        }
    }
    val dropped = remember(hidden, blocked) { FollowListLogic.dropped(hidden, blocked) }
    val sections = remember(people, followed, webOfTrust, trustRank, dropped, sort, query) {
        FollowListLogic.sections(people, followed, webOfTrust, trustRank, dropped, sort, query)
    }
    val subjectName = profiles[viewModel.subject]?.bestName ?: FollowListLogic.shortPubkey(viewModel.subject)
    // The counts count what the lists show, so a blocked person is gone from
    // both the rows and the number.
    val followersShown = FollowListLogic.shownCount(followers.keys, dropped)
    val followersLabel = followersTotal?.takeIf { it > followersShown }
        ?.let { FollowListLogic.countText(it, more = false) }
        ?: FollowListLogic.countText(followersShown, more = haveMore)

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(WindowBackground),
    ) {
        // Solid, never scrolls: rows and the group headers pass under it.
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .background(WindowBackground)
                .statusBarsPadding()
                .padding(horizontal = 12.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth().height(52.dp)) {
                IconButton(onClick = onBack, modifier = Modifier.size(48.dp)) {
                    Icon(NostrVaultIcons.Back, "Back", tint = PrimaryText, modifier = Modifier.size(24.dp))
                }
                Text(
                    subjectName,
                    color = PrimaryText,
                    fontSize = 17.sp,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    textAlign = TextAlign.Center,
                    modifier = Modifier.weight(1f),
                )
                SortMenu(sort) { picked ->
                    FollowListSortMemory.sorts[tab] = picked
                    sorts = FollowListSortMemory.sorts.toMap()
                }
            }
            // Search and the switch stop at 720 on a tablet, like the rows.
            Column(Modifier.widthIn(max = MAX_WIDTH).align(Alignment.CenterHorizontally)) {
                SearchField(query, placeholder = "Search ${tab.title.lowercase()}") { query = it }
                Spacer(Modifier.height(10.dp))
                TabSwitch(
                    tab = tab,
                    followingLabel = "Following ${FollowListLogic.countText(FollowListLogic.shownCount(following, dropped), more = false)}",
                    followersLabel = "Followers $followersLabel",
                    onSelect = { tab = it },
                )
                Spacer(Modifier.height(10.dp))
            }
        }
        HorizontalDivider(color = SeparatorColor, thickness = 0.5.dp)

        // Clear of the bottom bar, which a pushed list keeps.
        // Rows stop at 720 on a tablet, centred (iOS).
        LazyColumn(
            state = listState,
            contentPadding = PaddingValues(bottom = FloatingNavBarInset.height.value),
            modifier = Modifier.fillMaxHeight().widthIn(max = MAX_WIDTH).fillMaxWidth().align(Alignment.CenterHorizontally),
        ) {
            if (sections.isEmpty()) {
                item(key = "empty") {
                    Text(
                        when {
                            query.isNotBlank() -> "No one matches “${query.trim()}”"
                            tab == FollowListTab.FOLLOWING -> "Not following anyone yet"
                            else -> "No followers found yet"
                        },
                        color = SecondaryText,
                        fontSize = 14.sp,
                        textAlign = TextAlign.Center,
                        modifier = Modifier.fillMaxWidth().padding(vertical = 48.dp),
                    )
                }
            }
            for (section in sections) {
                val collapsible = section.group == FollowListGroup.OUTSIDE && query.isBlank()
                stickyHeader(key = "h-${section.group}") {
                    SectionHeader(section, collapsible, open = showOutside) { showOutside = !showOutside }
                }
                if (!collapsible || showOutside) {
                    items(section.people, key = { "${section.group}-${it.pubkey}" }) { p ->
                        val isViewer = p.pubkey == viewModel.viewer
                        LaunchedEffect(p.pubkey) { viewModel.needProfile(p.pubkey) }
                        // The outside group's rows fade in and out as it opens and closes.
                        Column(
                            if (collapsible) Modifier.animateItem(fadeInSpec = Motion.fade(), placementSpec = null, fadeOutSpec = Motion.fade())
                            else Modifier,
                        ) {
                        FollowListRow(
                            pubkey = p.pubkey,
                            name = p.name,
                            profile = profiles[p.pubkey],
                            followsYou = !isViewer &&
                                !(tab == FollowListTab.FOLLOWERS && isOwnLedger) &&
                                p.pubkey in followsViewer,
                            followState = if (isViewer) null else viewModel.state(p.pubkey, followed, queued),
                            onOpen = {
                                // This page already shows that profile, and you are
                                // not someone to open from a list of your own.
                                if (!isViewer && p.pubkey != viewModel.subject) onProfileClick(p.pubkey)
                            },
                            onToggleFollow = { viewModel.toggle(p.pubkey) },
                        )
                        HorizontalDivider(color = SeparatorColor, thickness = 0.5.dp, modifier = Modifier.padding(start = 72.dp))
                        }
                    }
                }
            }
            if (tab == FollowListTab.FOLLOWERS && haveMore) {
                item(key = "more-$pagesDone") {
                    // A new key per finished page, so a loader still on screen
                    // after a page asks for the next one.
                    LaunchedEffect(pagesDone) { viewModel.loadMoreFollowers() }
                    Box(Modifier.fillMaxWidth().padding(vertical = 20.dp), contentAlignment = Alignment.Center) {
                        CircularProgressIndicator(color = SecondaryText, strokeWidth = 2.dp, modifier = Modifier.size(22.dp))
                    }
                }
            }
        }
    }
}

private fun person(key: String, recency: Long, profile: FeedProfile?) = FollowListPerson(
    pubkey = key,
    name = profile?.bestName ?: shortNpub(key),
    nip05 = profile?.nip05.orEmpty(),
    recency = recency,
)

private val MAX_WIDTH = 720.dp

internal fun shortNpub(hex: String): String {
    val npub = runCatching { HavenBridge.encodeNpub(hex) }.getOrNull() ?: hex
    return npub.take(16) + "…"
}
