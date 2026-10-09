package com.nostrvault.ui.screens

import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.saveable.rememberSaveableStateHolder
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import com.nostrvault.data.model.VaultDots
import com.nostrvault.data.model.VaultMode
import com.nostrvault.relay.LogStore
import com.nostrvault.relay.RelayForegroundService
import com.nostrvault.service.FeedService
import com.nostrvault.tutorials.TutorialCenter
import com.nostrvault.tutorials.TutorialContent
import com.nostrvault.tutorials.TutorialID
import com.nostrvault.tutorials.tutorialAnchor
import com.nostrvault.ui.components.GlassPill
import com.nostrvault.ui.components.chromeFold
import com.nostrvault.ui.navigation.Screen
import com.nostrvault.ui.navigation.VaultSection
import com.nostrvault.ui.theme.ErrorRed
import com.nostrvault.ui.theme.NostrVaultIcons
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SuccessGreen
import com.nostrvault.ui.theme.ZapOrange

/**
 * The Vault tab: what used to be the Media and Relay tabs, in one (iOS
 * VaultTabView, #443). The relay half lists Notes, Articles, Highlights,
 * Likes, Zaps and Followers; the Media half is the Blossom gallery. The
 * pill at the top left switches between them and ends with the Vault
 * Dashboard, which this tab presents over either half.
 *
 * Only the half on screen is composed. Both view models live as long as the
 * tab, and the saveable state holder keeps each half's scroll position, so
 * switching back lands where you were.
 */
@Composable
fun VaultTabScreen(
    onNavigate: (Screen) -> Unit,
    onNoteClick: (String) -> Unit,
    onArticleClick: (String) -> Unit,
    onProfileClick: (String) -> Unit,
    onMediaClick: (Int) -> Unit,
    logStore: LogStore,
    feedService: FeedService,
    viewModel: DashboardViewModel = hiltViewModel(),
) {
    // The half survives Android killing the app (the photo picker opened
    // from Media is the usual case): restored before anything reads it, so
    // Media composes first and its picker gets the result. A route that
    // picked a half in this process wins; see VaultSection.restore.
    var restored = true
    val savedHalf = rememberSaveable { restored = false; mutableStateOf(VaultSection.showsMedia.value) }
    if (restored) remember { VaultSection.restore(media = savedHalf.value) }
    val showsMedia by VaultSection.showsMedia.collectAsState()
    SideEffect { savedHalf.value = showsMedia }
    val halves = rememberSaveableStateHolder()
    var showDashboard by remember { mutableStateOf(false) }
    val openDashboard: () -> Unit = {
        viewModel.loadStats()
        showDashboard = true
    }

    // The relay half's connection and follower ledger serve both halves (the
    // pill's dot shows on Media too), so they follow the tab, not the half:
    // flipping halves doesn't re-send subscriptions or restart the poll.
    LifecycleEventEffect(Lifecycle.Event.ON_RESUME) { viewModel.onResume() }
    // Save a snapshot when the app goes to background so the next cold launch is instant.
    LifecycleEventEffect(Lifecycle.Event.ON_STOP) { viewModel.persistSnapshot() }
    val lifecycleOwner = LocalLifecycleOwner.current
    LaunchedEffect(lifecycleOwner) {
        // Every minute while the tab is on screen and the app is in front.
        lifecycleOwner.repeatOnLifecycle(Lifecycle.State.RESUMED) { viewModel.pollFollowers() }
    }

    // The folded bar's corner button opens the Vault Dashboard (iOS parity).
    LaunchedEffect(Unit) { feedService.relayDashboardRequest.collect { openDashboard() } }
    // Your Vault starts the first time the Vault tab shows, on either half
    // (after Fill your vault; see TutorialProgress), and again when a status
    // changes quietly. Each half carries its pill and Vault button.
    val tutorialRevision by TutorialCenter.revision.collectAsState()
    LaunchedEffect(tutorialRevision) {
        TutorialCenter.startIfEligible(TutorialID.VAULT, viewModel.nostrService.activeHexPubkey)
    }

    // Pocket Relay's cards are on the dashboard: open it for them, on
    // whichever half you're on (Your Vault's "Next", or a replay).
    val activeTutorial by TutorialCenter.active.collectAsState()
    LaunchedEffect(activeTutorial) {
        if (activeTutorial == TutorialID.POCKET_RELAY && !showDashboard) openDashboard()
    }

    if (showsMedia) {
        halves.SaveableStateProvider("media") {
            // The same health colour the relay half shows, from the same connection.
            val connectionColor by viewModel.connectionColor.collectAsState()
            val newModes by viewModel.newModes.collectAsState()
            val statusColor = connectionDotColor(connectionColor)
            MediaGalleryScreen(
                feedService = feedService,
                onMediaClick = onMediaClick,
                onNoteClick = onNoteClick,
                onOpenDashboard = openDashboard,
                modePill = {
                    VaultModePill(
                        mode = VaultMode.MEDIA,
                        zapsOnly = com.nostrvault.ui.theme.LocalZapsOnlyMode.current,
                        newModes = newModes,
                        statusColor = statusColor,
                        onSelect = viewModel::selectMode,
                        onOpenDashboard = openDashboard,
                        modifier = Modifier.tutorialAnchor(TutorialContent.VAULT_MODES),
                    )
                },
                dashboardColor = statusColor,
            )
        }
    } else {
        halves.SaveableStateProvider("relay") {
            DashboardScreen(
                onNoteClick = onNoteClick,
                onArticleClick = onArticleClick,
                onProfileClick = onProfileClick,
                feedService = feedService,
                onOpenDashboard = openDashboard,
                viewModel = viewModel,
            )
        }
    }

    if (showDashboard) {
        VaultDashboardSheet(
            viewModel = viewModel,
            logStore = logStore,
            onNavigate = onNavigate,
            onDismiss = { showDashboard = false },
        )
    }
}

/** The relay's health as the Vault button's colour (the folded bar's tint too). */
fun relayStatusColor(status: RelayForegroundService.RelayStatus): Color = when (status) {
    RelayForegroundService.RelayStatus.RUNNING -> SuccessGreen
    RelayForegroundService.RelayStatus.BOOTING,
    RelayForegroundService.RelayStatus.IMPORTING -> ZapOrange
    RelayForegroundService.RelayStatus.OFFLINE -> ErrorRed
}

private val VaultMode.icon: ImageVector
    get() = when (this) {
        VaultMode.NOTES -> NostrVaultIcons.Document
        VaultMode.ARTICLES -> NostrVaultIcons.Articles
        VaultMode.HIGHLIGHTS -> NostrVaultIcons.Highlights
        VaultMode.MEDIA -> NostrVaultIcons.TabMedia
        VaultMode.LIKES -> NostrVaultIcons.HeartFilled
        VaultMode.ZAPS -> NostrVaultIcons.Zap
        VaultMode.FOLLOWERS -> NostrVaultIcons.People
    }

/**
 * The Vault tab's mode picker, built like the Feed tab's `Following ▾`: the
 * mode's icon with the relay's health dot, its name, and a chevron. The menu
 * lists the modes, then the Vault Dashboard, as the feed menu ends with its
 * dashboard. A red dot on the icon means something new in another mode.
 * Port of iOS VaultModePill.
 */
@Composable
internal fun VaultModePill(
    mode: VaultMode,
    zapsOnly: Boolean,
    newModes: Set<VaultMode>,
    statusColor: Color,
    onSelect: (VaultMode) -> Unit,
    onOpenDashboard: () -> Unit,
    modifier: Modifier = Modifier,
) {
    var expanded by remember { mutableStateOf(false) }
    val newElsewhere = VaultDots.hasNewElsewhere(newModes, mode)
    Box(modifier) {
        GlassPill(
            horizontalArrangement = Arrangement.Start,
            modifier = Modifier
                .clip(CircleShape)
                .clickable(onClickLabel = "Switch Vault lists") { expanded = true }
                .semantics {
                    contentDescription = "Vault: ${mode.displayName}"
                    if (newElsewhere) stateDescription = "New activity"
                },
        ) {
            Box(modifier = Modifier.size(30.dp), contentAlignment = Alignment.Center) {
                Icon(mode.icon, contentDescription = null, tint = PrimaryText, modifier = Modifier.size(18.dp))
                // The relay's health, as on the Feed pill.
                Box(
                    modifier = Modifier
                        .align(Alignment.BottomEnd)
                        .offset(x = (-1).dp, y = (-1).dp)
                        .size(8.dp)
                        .shadow(3.dp, CircleShape)
                        .clip(CircleShape)
                        .background(statusColor),
                )
                androidx.compose.animation.AnimatedVisibility(
                    visible = newElsewhere,
                    enter = scaleIn() + fadeIn(),
                    exit = scaleOut() + fadeOut(),
                    modifier = Modifier.align(Alignment.TopEnd).offset(x = 1.dp, y = (-1).dp),
                ) {
                    Box(Modifier.size(8.dp).background(ErrorRed, CircleShape))
                }
            }
            Box(Modifier.chromeFold(leadingGap = 6.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(mode.displayName, color = PrimaryText, fontSize = 17.sp, fontWeight = FontWeight.Bold, maxLines = 1)
                    Spacer(Modifier.width(2.dp))
                    Icon(NostrVaultIcons.ChevronDown, contentDescription = null, tint = PrimaryText, modifier = Modifier.size(16.dp))
                    Spacer(Modifier.width(6.dp))
                }
            }
        }

        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            VaultMode.menu(zapsOnly).forEach { m ->
                DropdownMenuItem(
                    text = {
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            Text(m.displayName, fontWeight = if (m == mode) FontWeight.SemiBold else FontWeight.Normal)
                            if (m in newModes) Text("New", color = ErrorRed, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
                        }
                    },
                    leadingIcon = { Icon(m.icon, contentDescription = null, modifier = Modifier.size(18.dp)) },
                    trailingIcon = if (m == mode) {
                        { Icon(NostrVaultIcons.Check, contentDescription = "Current list", modifier = Modifier.size(16.dp)) }
                    } else null,
                    onClick = {
                        expanded = false
                        onSelect(m)
                    },
                )
            }
            HorizontalDivider()
            DropdownMenuItem(
                text = { Text("Vault Dashboard") },
                leadingIcon = { Icon(NostrVaultIcons.TabVault, contentDescription = null, modifier = Modifier.size(18.dp)) },
                onClick = {
                    expanded = false
                    onOpenDashboard()
                },
            )
        }
    }
}
