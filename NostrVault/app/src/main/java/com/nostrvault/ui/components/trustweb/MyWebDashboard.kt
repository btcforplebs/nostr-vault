package com.nostrvault.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.OpenInNew
import androidx.compose.material.icons.automirrored.filled.Reply
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.filled.FavoriteBorder
import androidx.compose.material.icons.filled.Repeat
import androidx.compose.material.icons.filled.SettingsInputAntenna
import androidx.compose.material.icons.outlined.ChatBubbleOutline
import androidx.compose.material.icons.outlined.Hub
import androidx.compose.material.icons.outlined.People
import androidx.compose.material.icons.outlined.Public
import androidx.compose.material3.BottomSheetDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.data.model.GlobeArcs
import com.nostrvault.data.model.TrustMap
import com.nostrvault.ui.navigation.FloatingButtonRow
import com.nostrvault.ui.screens.dashboard.DashDivider
import com.nostrvault.ui.screens.dashboard.DashRow
import com.nostrvault.ui.screens.dashboard.DashSection
import com.nostrvault.ui.screens.dashboard.RowButton
import com.nostrvault.ui.screens.dashboard.RowIcon
import com.nostrvault.ui.screens.dashboard.RowState
import com.nostrvault.ui.theme.CardBorder
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.NostrVaultIcons
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryGroupedBg
import com.nostrvault.ui.theme.SecondaryText
import com.nostrvault.ui.theme.WindowBackground
import java.text.NumberFormat

/** My Web's words, apart so they can be tested (iOS `MyWebDashboardView`). */
internal object MyWebWords {
    private fun n(value: Int): String = NumberFormat.getIntegerInstance().format(value)

    fun headline(everyone: Int): String = "${n(everyone)} people"

    const val HEADLINE_DETAIL = "in your web: who you follow, and who they follow"

    /** Where follows get cleaned up; this app only links there (Logen 2026-11-01). */
    const val PLEBS_VS_ZOMBIES_URL = "https://plebsvszombies.cc"

    fun layerDetail(layer: TrustMap.Layer, hasVouches: Boolean): String = when (layer) {
        TrustMap.Layer.EVERYONE -> "Your whole web"
        TrustMap.Layer.FOLLOWING -> "People you follow"
        TrustMap.Layer.CLOSE -> "Followed by ${TrustMap.CLOSE_VOUCHES}+ people you follow"
        TrustMap.Layer.FURTHER_OUT ->
            if (hasVouches) "Followed by fewer than ${TrustMap.CLOSE_VOUCHES} people you follow"
            else "Followed by people you follow"
    }

    fun followsBackDetail(followsBack: Int?, follows: Int, checking: Boolean): String = when {
        followsBack != null && follows > 0 -> "${n(followsBack)} of the ${n(follows)} people you follow"
        checking -> "Checking who follows you…"
        else -> "Your vault hasn't seen your followers yet"
    }

    /** [ago] is "3 hours ago", or null when the web has never been saved. */
    fun rebuilt(rebuilding: Boolean, ago: String?): String = when {
        rebuilding -> "Rebuilding now…"
        ago == null -> "Your vault rebuilds it once a day"
        else -> "Last rebuilt $ago. Your vault rebuilds it once a day"
    }

    fun count(value: Int?): String = value?.let(::n) ?: "–"
}

/**
 * The WOT tab's floating button, where the other tabs have Post. It opens
 * My Web, as the Vault tab's button opens the Vault Dashboard (iOS
 * `myWebButton`). It reports its width so the mini player stops short of it.
 */
@Composable
internal fun MyWebButton(onClick: () -> Unit, modifier: Modifier = Modifier) {
    val colors = LocalNostrVaultColors.current
    val density = LocalDensity.current
    val key = remember { Any() }
    DisposableEffect(key) { onDispose { FloatingButtonRow.report(key, null) } }
    Surface(
        onClick = onClick,
        shape = CircleShape,
        shadowElevation = 8.dp,
        color = colors.primary,
        modifier = modifier
            .onSizeChanged { FloatingButtonRow.report(key, with(density) { it.width.toDp() }) }
            .semantics { contentDescription = "My Web, opens your web's dashboard" },
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .background(Brush.linearGradient(listOf(colors.primary, colors.primaryLight)))
                .height(FloatingButtonRow.buttonHeight)
                .padding(horizontal = 18.dp),
        ) {
            Icon(NostrVaultIcons.WebOfTrust, contentDescription = null, tint = PrimaryText, modifier = Modifier.size(18.dp))
            Spacer(Modifier.width(6.dp))
            Text("My Web", color = PrimaryText, fontSize = 14.sp, fontWeight = FontWeight.Bold)
        }
    }
}

/** What My Web shows, read from the WOT tab when it opens. */
internal class MyWebNumbers(
    val counts: Map<TrustMap.Layer, Int>,
    val hasVouches: Boolean,
    val layer: TrustMap.Layer,
    val follows: Int,
    val rebuilding: Boolean,
    /** "3 hours ago", or null before the web was first saved. */
    val rebuiltAgo: String?,
)

/**
 * My Web: what the WOT tab's globe holds, in numbers, and the switches for
 * what flies across it. A count row puts that part of your web on the globe
 * and closes the sheet (iOS `MyWebDashboardView`).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun MyWebSheet(
    numbers: MyWebNumbers,
    filters: WotFilters,
    liveArcs: LiveArcsState,
    onLayer: (TrustMap.Layer) -> Unit,
    onRebuild: () -> Unit,
    onDismiss: () -> Unit,
) {
    LaunchedEffect(Unit) { filters.readFollowsBack() }
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = WindowBackground,
        dragHandle = { BottomSheetDefaults.DragHandle(color = SecondaryText) },
    ) {
        Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.TopCenter) {
            Column(
                verticalArrangement = Arrangement.spacedBy(24.dp),
                modifier = Modifier
                    .widthIn(max = 700.dp)
                    .fillMaxWidth()
                    .verticalScroll(rememberScrollState())
                    .padding(start = 16.dp, end = 16.dp, bottom = 32.dp),
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(NostrVaultIcons.WebOfTrust, contentDescription = null, tint = PrimaryText, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(6.dp))
                    Text("My Web", color = PrimaryText, fontSize = 17.sp, fontWeight = FontWeight.Bold, modifier = Modifier.weight(1f))
                    TextButton(onClick = onDismiss) { Text("Done", color = LocalNostrVaultColors.current.primary) }
                }
                Headline(numbers.counts[TrustMap.Layer.EVERYONE] ?: 0)
                DashSection(title = "Who you can see") {
                    TrustMap.layers(numbers.hasVouches).forEachIndexed { index, item ->
                        if (index > 0) DashDivider()
                        CountRow(item.icon, item.title, MyWebWords.layerDetail(item, numbers.hasVouches),
                            numbers.counts[item] ?: 0, selected = item == numbers.layer) { onLayer(item) }
                    }
                }
                DashSection(title = "With you") {
                    CountRow(TrustMap.Filter.TALK.icon, TrustMap.Filter.TALK.title,
                        "Replies, reposts, likes and zaps, either way",
                        filters.count(TrustMap.Filter.TALK), selected = TrustMap.Filter.TALK in filters.on) {
                        filters.turnOn(TrustMap.Filter.TALK)
                        onDismiss()
                    }
                    DashDivider()
                    val back = filters.count(TrustMap.Filter.FOLLOWS_BACK)
                    CountRow(TrustMap.Filter.FOLLOWS_BACK.icon, TrustMap.Filter.FOLLOWS_BACK.title,
                        MyWebWords.followsBackDetail(back, numbers.follows, filters.followsBackChecking),
                        back, selected = TrustMap.Filter.FOLLOWS_BACK in filters.on) {
                        filters.turnOn(TrustMap.Filter.FOLLOWS_BACK)
                        onDismiss()
                    }
                }
                LiveArrivalsSections(liveArcs)
                DashSection(title = "Upkeep") {
                    DashRow(NostrVaultIcons.Refresh, "Rebuild your web",
                        MyWebWords.rebuilt(numbers.rebuilding, numbers.rebuiltAgo), RowState.INFO) {
                        RowButton("Rebuild", isLoading = numbers.rebuilding, onClick = onRebuild)
                    }
                    DashDivider()
                    // Cleaning up follows happens on Plebs vs. Zombies, not in this app (Logen 2026-11-01).
                    val uriHandler = androidx.compose.ui.platform.LocalUriHandler.current
                    DashRow(Icons.AutoMirrored.Filled.OpenInNew, "Plebs vs Zombies",
                        "Clean up your follows on plebsvszombies.cc", RowState.INFO) {
                        RowButton("Open") { runCatching { uriHandler.openUri(MyWebWords.PLEBS_VS_ZOMBIES_URL) } }
                    }
                }
            }
        }
    }
}

/** The one big number: everyone on your globe. */
@Composable
private fun Headline(everyone: Int) {
    val primary = LocalNostrVaultColors.current.primary
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(14.dp),
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(SecondaryGroupedBg)
            .border(1.dp, CardBorder, RoundedCornerShape(14.dp))
            .semantics(mergeDescendants = true) {}
            .padding(16.dp),
    ) {
        Box(
            contentAlignment = Alignment.Center,
            modifier = Modifier.size(54.dp).background(primary.copy(alpha = 0.14f), RoundedCornerShape(12.dp)),
        ) {
            Icon(NostrVaultIcons.WebOfTrust, contentDescription = null, tint = primary, modifier = Modifier.size(34.dp))
        }
        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(MyWebWords.headline(everyone), color = PrimaryText, fontSize = 26.sp, fontWeight = FontWeight.Bold)
            Text(MyWebWords.HEADLINE_DETAIL, color = SecondaryText, fontSize = 13.sp)
        }
    }
}

/** A count that, tapped, shows those people on the globe. */
@Composable
private fun CountRow(icon: ImageVector, title: String, detail: String, count: Int?, selected: Boolean, onClick: () -> Unit) {
    val primary = LocalNostrVaultColors.current.primary
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        modifier = Modifier
            .fillMaxWidth()
            .clickable(role = Role.Button, onClickLabel = "Show them on the globe", onClick = onClick)
            .semantics(mergeDescendants = true) {
                this.selected = selected
                stateDescription = count?.let { "${MyWebWords.count(it)} people" } ?: "Not known yet"
            }
            .padding(horizontal = 14.dp, vertical = 11.dp),
    ) {
        RowIcon(icon, RowState.INFO)
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(title, color = PrimaryText, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
            Text(detail, color = SecondaryText, fontSize = 12.sp)
        }
        Text(MyWebWords.count(count), color = if (selected) primary else PrimaryText, fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
        Icon(
            if (selected) NostrVaultIcons.Check else NostrVaultIcons.Navigate,
            contentDescription = null,
            tint = if (selected) primary else SecondaryText,
            modifier = Modifier.size(14.dp),
        )
    }
}

/** Live arrivals and What flies: the feeds and sorts behind the bar's antenna. */
@Composable
private fun LiveArrivalsSections(state: LiveArcsState) {
    DashSection(title = "Live arrivals") {
        SwitchRow(Icons.Filled.SettingsInputAntenna, "Stars on the globe", "A star for each new note as it arrives",
            state.on) { state.switchOn(it) }
        DashDivider()
        SwitchRow(Icons.Outlined.People, GlobeArcs.Ring.FOLLOWING.title, "Your follows' notes, from the inner ring. The fewest",
            GlobeArcs.Ring.FOLLOWING in state.rings, enabled = state.on) { state.setRing(GlobeArcs.Ring.FOLLOWING, it) }
        DashDivider()
        SwitchRow(Icons.Outlined.Hub, GlobeArcs.Ring.DISCOVER.title, "Your wider web, from the next ring out. More",
            GlobeArcs.Ring.DISCOVER in state.rings, enabled = state.on) { state.setRing(GlobeArcs.Ring.DISCOVER, it) }
        DashDivider()
        SwitchRow(Icons.Outlined.Public, GlobeArcs.Ring.GLOBAL.title, "The rest of Global, from the outer haze. The most",
            GlobeArcs.Ring.GLOBAL in state.rings, enabled = state.on) { state.setRing(GlobeArcs.Ring.GLOBAL, it) }
    }
    DashSection(title = "What flies") {
        SwitchRow(Icons.Outlined.ChatBubbleOutline, "New notes", "A star for each new note",
            state.show.notes, enabled = state.on) { state.setSort(GlobeArcs.Sort.NOTE, it) }
        DashDivider()
        SwitchRow(Icons.AutoMirrored.Filled.Reply, "Replies", "A star from who replied to who they answered",
            state.show.replies, enabled = state.on) { state.setSort(GlobeArcs.Sort.REPLY, it) }
        DashDivider()
        SwitchRow(Icons.Filled.Repeat, "Reposts", "A star from who reposted to who wrote it",
            state.show.reposts, enabled = state.on) { state.setSort(GlobeArcs.Sort.REPOST, it) }
        DashDivider()
        SwitchRow(Icons.Filled.FavoriteBorder, "Reactions", "A smaller star from who reacted to who they reacted to",
            state.show.reactions, enabled = state.on) { state.setSort(GlobeArcs.Sort.REACTION, it) }
        DashDivider()
        SwitchRow(Icons.Filled.Bolt, "Zaps", "A lightning bolt from the zapper. Bigger zaps strike harder",
            state.show.zaps, enabled = state.on) { state.setSort(GlobeArcs.Sort.ZAP, it) }
    }
}

@Composable
private fun SwitchRow(
    icon: ImageVector,
    title: String,
    detail: String,
    checked: Boolean,
    enabled: Boolean = true,
    onChange: (Boolean) -> Unit,
) {
    DashRow(icon, title, detail, RowState.INFO) {
        Switch(
            checked = checked,
            onCheckedChange = onChange,
            enabled = enabled,
            colors = SwitchDefaults.colors(checkedTrackColor = LocalNostrVaultColors.current.primary),
        )
    }
}
