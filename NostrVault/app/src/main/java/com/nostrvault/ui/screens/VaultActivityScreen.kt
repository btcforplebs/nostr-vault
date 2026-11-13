package com.nostrvault.ui.screens

import com.nostrvault.ui.components.rememberFilterNoteState
import com.nostrvault.ui.components.countNote
import com.nostrvault.ui.components.VaultRightPill
import com.nostrvault.data.model.VaultActivityFilter
import androidx.compose.runtime.setValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.local.FollowersSeenStore
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.data.model.FollowerSnapshot
import com.nostrvault.data.model.VaultActivity
import com.nostrvault.data.model.AccountUnread
import com.nostrvault.data.model.VaultAccountChip
import com.nostrvault.data.model.VaultAccountChips
import com.nostrvault.data.model.VaultAccountLine
import com.nostrvault.data.model.VaultContentFilter
import com.nostrvault.data.model.VaultMode
import com.nostrvault.data.model.VaultNoteScope
import com.nostrvault.data.model.VaultOutsideFold
import com.nostrvault.relay.HavenBridge
import com.nostrvault.relay.RelayForegroundService
import com.nostrvault.service.FeedService
import com.nostrvault.service.NostrService
import com.nostrvault.service.ZapValidationService
import com.nostrvault.tutorials.TutorialContent
import com.nostrvault.tutorials.tutorialAnchor
import com.nostrvault.ui.components.GlassScaffold
import com.nostrvault.ui.components.ScrollCondenseEffect
import com.nostrvault.ui.components.chromeFab
import com.nostrvault.ui.components.FoldBlocked
import com.nostrvault.ui.navigation.FloatingButtonRow
import com.nostrvault.ui.navigation.FloatingButtonRow.floatingRowButton
import com.nostrvault.ui.navigation.Screen
import com.nostrvault.ui.navigation.TabReselect
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.NostrVaultIcons
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.longOrNull
import javax.inject.Inject
import com.nostrvault.ui.screens.dashboard.IconFilterButton
import com.nostrvault.ui.components.RevealNewestEffect

/** The "Vault" list, with the tab's pill and Vault button (as the other lists). */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun VaultActivityScreen(
    activity: VaultActivityViewModel,
    zapsOnly: Boolean,
    newModes: Set<VaultMode>,
    dashboardColor: Color,
    onSelect: (VaultMode) -> Unit,
    onOpenDashboard: () -> Unit,
    /** A line was tapped; the flag is true when it is for an account you are not on. */
    onOpenLine: (VaultActivity, Boolean) -> Unit,
) {
    val colors = LocalNostrVaultColors.current
    val all by activity.lines.collectAsState()
    val shownCount by activity.shown.collectAsState()
    val hasLoadedOnce by activity.hasLoadedOnce.collectAsState()
    val isRefreshing by activity.isRefreshing.collectAsState()
    val unreadSince by activity.unreadSince.collectAsState()
    val profiles by activity.profiles.collectAsState()
    val relayStatus by RelayForegroundService.relayStatus.collectAsState()
    val bootStatus by activity.relayBootStatus.collectAsState()
    // All, or only replies, mentions and quotes (the right pill's @; tap it
    // again for All). [outside]: ··· › Outside your web, what All leaves out.
    var filter by rememberSaveable { mutableStateOf(VaultActivityFilter.ALL) }
    var outside by rememberSaveable { mutableStateOf(false) }
    val outsideAll by activity.outsideLines.collectAsState()
    // In Zaps Only mode, likes are hidden.
    val lines = remember(all, outsideAll, shownCount, zapsOnly, filter, outside) {
        // Filtered before the page cap, so a page of likes doesn't hide the
        // mentions behind it.
        if (outside) outsideAll.take(shownCount)
        else all.filter { filter.includes(it.kind) && !(zapsOnly && it.kind == VaultActivity.Kind.REACTION) }.take(shownCount)
    }
    // All's "N from outside your web" line: the likes and reposts All left out.
    val outsideLikes = remember(outsideAll, zapsOnly) { VaultOutsideFold.count(outsideAll, zapsOnly) }
    // More than one account: "All · <acct> · <acct>" chips widen the list.
    val accountHexes by activity.accountHexes.collectAsState()
    val activeHex by activity.activeHex.collectAsState()
    val pickedChip by activity.accountChip.collectAsState()
    val pendingChip by activity.pendingChip.collectAsState()
    val otherLines by activity.otherLines.collectAsState()
    val otherUnreadSince by activity.otherUnreadSince.collectAsState()
    val otherLoading by activity.otherLoading.collectAsState()
    val unreadCounts by activity.accountUnreadState.collectAsState()
    val chips = remember(accountHexes, activeHex) { VaultAccountChips.chips(accountHexes, activeHex) }
    val currentChip = VaultAccountChips.resolve(pickedChip, accountHexes, activeHex)
    // Outside your web is this account's alone: the chips don't widen it.
    val others = !outside && !VaultAccountChips.isDefault(currentChip, activeHex)
    val rows: List<VaultAccountLine> = remember(lines, all, otherLines, currentChip, accountHexes, activeHex, shownCount, zapsOnly, filter, others) {
        if (!others) {
            lines.map { VaultAccountLine(activeHex, it) }
        } else {
            val perAccount = VaultAccountChips.accounts(currentChip, accountHexes).associateWith { hex ->
                (if (hex == activeHex) all else otherLines[hex].orEmpty())
                    .filter { filter.includes(it.kind) && !(zapsOnly && it.kind == VaultActivity.Kind.REACTION) }
            }
            VaultAccountChips.merge(perAccount, accountHexes, shownCount)
        }
    }
    /** A row that tagged several accounts, waiting for "Reply or react as" (VaultAccountPickSheet). */
    var pickFor by remember { mutableStateOf<VaultAccountLine?>(null) }
    fun openRow(row: VaultAccountLine, asAccount: String) {
        pickFor = null
        row.accounts.forEach { activity.openedLine(it) }
        activity.openLineAs(asAccount) { onOpenLine(row.line, asAccount != activeHex) }
    }
    pickFor?.let { row ->
        VaultAccountPickSheet(
            accounts = row.accounts,
            profiles = profiles,
            onPick = { hex -> openRow(row, hex) },
            onDismiss = { pickFor = null },
        )
    }
    val filterNote = rememberFilterNoteState()
    fun pick(next: VaultActivityFilter, toOutside: Boolean = false) {
        val changed = next != filter || toOutside != outside
        val shownAfter = if (changed) activity.filterChanged() else shownCount
        filter = next
        outside = toOutside
        val matching = if (toOutside) outsideAll.size
        else all.count { next.includes(it.kind) && !(zapsOnly && it.kind == VaultActivity.Kind.REACTION) }
        val count = minOf(matching, shownAfter)
        val capped = matching > shownAfter
        filterNote.show(
            when {
                toOutside -> countNote(NostrVaultIcons.OutsideNetwork, "Outside your web", count, capped, "Nothing from outside your web")
                next == VaultActivityFilter.MENTIONS -> countNote(NostrVaultIcons.At, "Mentions", count, capped, "No mentions yet")
                else -> countNote(NostrVaultIcons.Layers, "Everything", count, capped, "Nothing new yet")
            },
        )
    }
    val listState = rememberLazyListState()

    val atEnd by remember {
        derivedStateOf {
            val last = listState.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: 0
            last >= listState.layoutInfo.totalItemsCount - 3
        }
    }
    LaunchedEffect(atEnd, rows.size) { if (atEnd && rows.isNotEmpty()) activity.loadMore() }

    ScrollCondenseEffect(
        scrollKey = listState,
        firstVisibleItemIndex = { listState.firstVisibleItemIndex },
        firstVisibleItemScrollOffset = { listState.firstVisibleItemScrollOffset },
    )
    LaunchedEffect(Unit) {
        TabReselect.of(Screen.Dashboard).collect { listState.animateScrollToItem(0) }
    }
    // New lines (a refresh on coming back to the tab, a tick) land above the
    // top line: show them rather than keep the old top line in place.
    RevealNewestEffect(listState) { rows.map { if (others) it.key else it.line.id } }

    GlassScaffold(
        toolbar = {
            Column {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier
                        .fillMaxWidth()
                        .statusBarsPadding()
                        // The account pictures sit close under the top bar.
                        .padding(start = 12.dp, end = 12.dp, top = 8.dp, bottom = if (chips.isNotEmpty()) 2.dp else 8.dp),
                ) {
                    VaultModePill(
                        mode = VaultMode.ACTIVITY,
                        zapsOnly = zapsOnly,
                        newModes = newModes,
                        onSelect = onSelect,
                        onOpenDashboard = onOpenDashboard,
                        modifier = Modifier.tutorialAnchor(TutorialContent.VAULT_MODES),
                    )
                    Spacer(Modifier.weight(1f))
                    // Search · @ · ···, as bare icons; the note says what a tap
                    // picked. No All button: All is nothing lit (Logen 2026-11-04).
                    VaultRightPill {
                        val mentions = filter == VaultActivityFilter.MENTIONS && !outside
                        IconFilterButton(
                            icon = NostrVaultIcons.At,
                            contentDescription = "Mentions",
                            isSelected = mentions,
                            onClick = { pick(if (mentions) VaultActivityFilter.ALL else VaultActivityFilter.MENTIONS) },
                        )
                        VaultActivityMore(
                            outside = outside,
                            onOutside = { pick(VaultActivityFilter.ALL, toOutside = !outside) },
                        )
                    }
                }
                if (chips.isNotEmpty()) {
                    AccountChipRow(
                        chips = chips,
                        // A pick still reading shows its ring at once; the list stays.
                        selected = pendingChip ?: currentChip,
                        activeHex = activeHex,
                        profiles = profiles,
                        counts = unreadCounts,
                        onPick = activity::pickAccountChip,
                        modifier = Modifier.padding(bottom = 8.dp),
                    )
                }
            }
        },
        floatingActionButton = {
            // FoldBlocked alone reads the fold: its halfway flip never recomposes
            // the button (#1437).
            FoldBlocked(whenFolded = true, modifier = Modifier.chromeFab()) {
                Surface(
                    onClick = onOpenDashboard,
                    modifier = Modifier
                        .floatingRowButton()
                        .tutorialAnchor(TutorialContent.VAULT_RELAY),
                    color = dashboardColor,
                    shape = CircleShape,
                    shadowElevation = 8.dp,
                ) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier
                            .height(FloatingButtonRow.buttonHeight)
                            .padding(horizontal = 18.dp),
                    ) {
                        Icon(NostrVaultIcons.TabVault, contentDescription = null, tint = PrimaryText, modifier = Modifier.size(18.dp))
                        Spacer(Modifier.width(6.dp))
                        Text("Vault", color = PrimaryText, fontSize = 14.sp, fontWeight = FontWeight.Bold)
                    }
                }
            }
        },
    ) { padding ->
        // No pull to refresh: the relay's inbox tick keeps the list current.
        Box(modifier = Modifier.fillMaxSize()) {
            val booting = relayStatus != RelayForegroundService.RelayStatus.RUNNING
            val showsFold = !outside && !others && filter == VaultActivityFilter.ALL && outsideLikes > 0
            when {
                rows.isEmpty() && !showsFold && (
                    if (others) otherLoading || (currentChip == VaultAccountChip.All && !hasLoadedOnce)
                    else !hasLoadedOnce || isRefreshing || booting
                    ) -> Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.Center,
                    modifier = Modifier.fillMaxSize().padding(top = padding.calculateTopPadding()),
                ) {
                    CircularProgressIndicator(color = colors.primary, modifier = Modifier.size(32.dp))
                    Spacer(Modifier.height(16.dp))
                    Text(
                        if (booting) bootStatus.ifBlank { "Starting relay..." } else "Loading your vault...",
                        color = PrimaryText, fontSize = 18.sp, fontWeight = FontWeight.Bold,
                    )
                }
                rows.isEmpty() && !showsFold -> Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.Center,
                    modifier = Modifier.fillMaxSize().padding(top = padding.calculateTopPadding()),
                ) {
                    Icon(NostrVaultIcons.Activity, contentDescription = null, tint = colors.primary, modifier = Modifier.size(48.dp))
                    Spacer(Modifier.height(16.dp))
                    Text(
                        when {
                            outside -> "Nothing from outside your web"
                            filter == VaultActivityFilter.MENTIONS -> "No mentions yet"
                            else -> "Nothing new yet"
                        },
                        color = PrimaryText, fontSize = 18.sp, fontWeight = FontWeight.Bold,
                    )
                    Spacer(Modifier.height(8.dp))
                    Text(
                        when {
                            outside -> "Posts that tag you, likes and reposts from people outside your web of trust land here"
                            filter == VaultActivityFilter.MENTIONS -> "Replies, mentions and quotes land here"
                            else -> "Replies, likes, zaps and new followers land here"
                        },
                        color = SecondaryText, fontSize = 13.sp,
                        fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace,
                        textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                        modifier = Modifier.padding(horizontal = 24.dp),
                    )
                }
                else -> LazyColumn(
                    state = listState,
                    contentPadding = PaddingValues(
                        top = padding.calculateTopPadding(),
                        bottom = padding.calculateBottomPadding() + 88.dp,
                    ),
                    verticalArrangement = Arrangement.spacedBy(10.dp),
                    modifier = Modifier.fillMaxSize(),
                ) {
                    if (showsFold) {
                        item(key = "outside-fold") {
                            VaultOutsideFoldRow(
                                count = outsideLikes,
                                onOpen = { pick(VaultActivityFilter.ALL, toOutside = true) },
                                modifier = Modifier.padding(horizontal = 16.dp),
                            )
                        }
                    }
                    items(rows, key = { if (others) it.key else it.line.id }) { row ->
                        val line = row.line
                        // New if newer than any of its accounts' seen marks (one row for an event that tagged several).
                        val sinceOf = { hex: String -> if (hex != activeHex) otherUnreadSince[hex] ?: Long.MAX_VALUE else unreadSince }
                        VaultActivityRow(
                            line = line,
                            isUnread = row.accounts.any { line.createdAt > sinceOf(it) },
                            profiles = profiles,
                            accounts = if (others) row.accounts else emptyList(),
                            onClick = {
                                // Opening clears it for every account it tagged; several ask which one replies or reacts.
                                if (row.accounts.size > 1) pickFor = row
                                else openRow(row, row.account)
                            },
                            modifier = Modifier.padding(horizontal = 16.dp),
                        )
                    }
                }
            }
        }
    }
}

/**
 * The Vault page's ···: Outside your web, the posts tagging you from people
 * outside your web of trust that the list leaves out. It moved here from the
 * Notes toolbar's person-with-? (toolbar audit, Logen 2026-11-04).
 */
@Composable
private fun VaultActivityMore(outside: Boolean, onOutside: () -> Unit) {
    var open by remember { mutableStateOf(false) }
    Box {
        IconFilterButton(
            icon = NostrVaultIcons.More,
            contentDescription = "More filters",
            isSelected = outside,
            onClick = { open = true },
        )
        androidx.compose.material3.DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            androidx.compose.material3.DropdownMenuItem(
                text = { Text("Outside your web") },
                leadingIcon = { Icon(NostrVaultIcons.OutsideNetwork, contentDescription = null, modifier = Modifier.size(18.dp)) },
                trailingIcon = if (outside) {
                    { Icon(NostrVaultIcons.Check, contentDescription = "On", modifier = Modifier.size(16.dp)) }
                } else null,
                onClick = {
                    open = false
                    onOutside()
                },
            )
        }
    }
}
