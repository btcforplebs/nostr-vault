package com.nostrvault.ui.screens.dashboard

import android.widget.Toast
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowCircleDown
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Collections
import androidx.compose.material.icons.filled.Dns
import androidx.compose.material.icons.filled.Error
import androidx.compose.material.icons.filled.FolderZip
import androidx.compose.material.icons.filled.Groups
import androidx.compose.material.icons.filled.Hub
import androidx.compose.material.icons.filled.Image
import androidx.compose.material.icons.filled.Laptop
import androidx.compose.material.icons.filled.MoreHoriz
import androidx.compose.material.icons.filled.PanTool
import androidx.compose.material.icons.filled.PhotoLibrary
import androidx.compose.material.icons.filled.PowerSettingsNew
import androidx.compose.material.icons.filled.SettingsInputAntenna
import androidx.compose.material.icons.filled.UploadFile
import androidx.compose.material.icons.filled.VerifiedUser
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import com.nostrvault.data.model.VaultMode
import com.nostrvault.relay.LogStore
import com.nostrvault.relay.RelayForegroundService
import com.nostrvault.tutorials.TutorialContent
import com.nostrvault.tutorials.tutorialAnchor
import com.nostrvault.ui.navigation.Screen
import com.nostrvault.ui.screens.DashboardViewModel
import com.nostrvault.ui.screens.dashboard.VaultDashboardModel.RunState
import com.nostrvault.ui.theme.CardBorder
import com.nostrvault.ui.theme.InfoBlue
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.Motion
import com.nostrvault.ui.theme.NostrVaultIcons
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryGroupedBg
import com.nostrvault.ui.theme.SecondaryText
import com.nostrvault.ui.theme.SuccessGreen
import com.nostrvault.ui.theme.TertiaryGroupedBg
import com.nostrvault.ui.theme.ZapOrange
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * The Vault Dashboard (v2): one page that answers four questions about the
 * vault, in order. Is it running? Is it safe? Who can reach me? Is it
 * complete? Relay internals, mirrors and raw logs sit under Advanced.
 * Port of iOS `VaultDashboardView`.
 *
 * Rows that open a settings page close the sheet and open it (iOS pushes it
 * inside the sheet); Relay details and Media server details are pages inside
 * the sheet, as on iOS.
 */
@Composable
internal fun VaultDashboardContent(
    vaultViewModel: DashboardViewModel,
    logStore: LogStore,
    /** Close the sheet and open [Screen]. */
    onOpenScreen: (Screen) -> Unit,
    /** Close the sheet and switch the Vault tab to [VaultMode]. */
    onOpenMode: (VaultMode) -> Unit,
    onOpenRelayDetails: () -> Unit,
    onOpenMediaDetails: () -> Unit,
    viewModel: VaultDashboardViewModel = hiltViewModel(),
) {
    val colors = LocalNostrVaultColors.current
    val context = LocalContext.current
    val cfg by viewModel.configStore.config.collectAsState()
    val relayStatus by RelayForegroundService.relayStatus.collectAsState()
    val isLocked by RelayForegroundService.isLocked.collectAsState()
    val isPortConflict by RelayForegroundService.isPortConflict.collectAsState()
    val logs by logStore.logs.collectAsState()
    val history by viewModel.history.collectAsState()
    val wot by viewModel.wotPubkeys.collectAsState()
    val kindCounts by viewModel.kindCounts.collectAsState()
    val mediaCount by viewModel.mediaCount.collectAsState()
    val macSync by viewModel.macSync.collectAsState()
    val followSavedAt by viewModel.followListSavedAt.collectAsState()
    val hasLocalKey by viewModel.hasLocalKey.collectAsState()
    val startedAt by viewModel.relayStartedAt.collectAsState()
    val storageSize by viewModel.statsService.storageSize.collectAsState()
    val blossomSize by viewModel.statsService.blossomSize.collectAsState()
    val cacheSize by viewModel.statsService.cacheSize.collectAsState()
    val thumbnailSize by viewModel.statsService.thumbnailSize.collectAsState()
    val isImporting by vaultViewModel.isImporting.collectAsState()
    val importProgress by vaultViewModel.importProgress.collectAsState()
    val importStatus by vaultViewModel.importStatusMessage.collectAsState()
    val importCompleted by vaultViewModel.importCompleted.collectAsState()
    val exportingNotes by vaultViewModel.isExportingJsonl.collectAsState()
    val exportingMedia by vaultViewModel.isExportingMedia.collectAsState()
    val exportStatus by vaultViewModel.exportStatus.collectAsState()
    val exportIsError by vaultViewModel.exportStatusIsError.collectAsState()
    val mirror by vaultViewModel.blossomMirrorRun.collectAsState()

    // "Last ran" lines and the uptime read the clock; keep them fresh.
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(Unit) {
        viewModel.refresh()
        while (true) {
            delay(30_000)
            now = System.currentTimeMillis()
        }
    }
    LaunchedEffect(history, followSavedAt, macSync) { now = System.currentTimeMillis() }
    // A finished import's result stays a moment, then the row goes back to its "last ran" line.
    LaunchedEffect(importCompleted) {
        if (importCompleted) {
            delay(3_000)
            vaultViewModel.dismissImport()
        }
    }

    val isExternal = cfg.useExternalRelay
    val running = relayStatus == RelayForegroundService.RelayStatus.RUNNING
    val runState = if (isExternal) RunState.RUNNING else VaultDashboardModel.runState(
        isBooting = relayStatus == RelayForegroundService.RelayStatus.BOOTING,
        isRunning = running,
        isImporting = isImporting || relayStatus == RelayForegroundService.RelayStatus.IMPORTING,
        isLocked = isLocked,
        isPortConflict = isPortConflict,
    )
    val usesSigner = viewModel.usesSigner(cfg)
    val keyOk = hasLocalKey || usesSigner
    val macConfigured = cfg.macRelayURL.isNotBlank()
    val exportBusy = exportingNotes || exportingMedia
    val actionsEnabled = running || isImporting

    var showStorageBreakdown by remember { mutableStateOf(false) }

    Column(
        verticalArrangement = Arrangement.spacedBy(24.dp),
        modifier = Modifier
            .fillMaxWidth()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 16.dp)
            .padding(top = 4.dp, bottom = 32.dp),
    ) {
        // Header
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
            Icon(NostrVaultIcons.TabVault, contentDescription = null, tint = colors.primary, modifier = Modifier.size(20.dp))
            Spacer(Modifier.width(8.dp))
            Text("Vault Dashboard", color = PrimaryText, fontSize = 18.sp, fontWeight = FontWeight.Bold)
            Spacer(Modifier.weight(1f))
            IconButton(onClick = viewModel::pullToRefresh, modifier = Modifier.size(32.dp)) {
                Icon(NostrVaultIcons.Refresh, "Refresh", tint = SecondaryText, modifier = Modifier.size(18.dp))
            }
        }

        // ── Is it running? ─────────────────────────────────────
        StatusCard(
            runState = runState,
            isExternal = isExternal,
            isPortConflict = isPortConflict,
            port = cfg.relayPort,
            address = cfg.nostrURL,
            subtitle = when {
                isExternal -> "On your external relay"
                runState == RunState.IMPORTING -> importStatus.ifEmpty { "Importing your notes…" }
                runState == RunState.RUNNING -> VaultDashboardModel.uptime(startedAt, now)
                else -> null
            },
            onStart = { RelayForegroundService.start(context) },
            onStop = { RelayForegroundService.stop(context) },
            onRestart = {
                RelayForegroundService.stop(context)
                android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
                    RelayForegroundService.start(context)
                }, 1500)
            },
            onForceRestart = { RelayForegroundService.forceRestart(context) },
        )

        // ── Is it safe? ────────────────────────────────────────
        val backupAt = history.notesBackup
        DashSection(
            title = "Is it safe?",
            detail = "${VaultDashboardModel.safetyDoneCount(keyOk, followSavedAt != null, macConfigured, backupAt != null)} of 4",
        ) {
            DashRowLink(
                icon = NostrVaultIcons.Key,
                title = VaultDashboardModel.keyTitle(usesSigner, hasLocalKey),
                detail = VaultDashboardModel.keyDetail(usesSigner, hasLocalKey),
                state = if (keyOk) RowState.DONE else RowState.TODO,
                onClick = { onOpenScreen(Screen.AccountSettings) },
            )
            DashDivider()
            DashRowLink(
                icon = Icons.Filled.Groups,
                title = "Follow list saved",
                detail = VaultDashboardModel.followListDetail(followSavedAt, now),
                state = if (followSavedAt == null) RowState.TODO else RowState.DONE,
                onClick = { onOpenScreen(Screen.FollowingBackup) },
            )
            DashDivider()
            DashRowLink(
                icon = Icons.Filled.Laptop,
                title = "Second copy on your Mac",
                detail = VaultDashboardModel.macSyncDetail(macConfigured, macSync?.finishedAt, now),
                state = if (macConfigured) RowState.DONE else RowState.TODO,
                onClick = { onOpenScreen(Screen.HavenRelaySettings) },
            )
            DashDivider()
            DashRow(
                icon = Icons.Filled.FolderZip,
                title = "Backup file",
                detail = VaultDashboardModel.backupFileDetail(backupAt, now),
                state = if (backupAt == null) RowState.TODO else RowState.DONE,
            ) {
                RowButton(
                    title = if (backupAt == null) "Make one" else "Make new",
                    isLoading = exportingNotes,
                    enabled = !exportBusy && running,
                    onClick = { vaultViewModel.exportJsonl(context) },
                )
            }
        }

        // ── Who can reach you ──────────────────────────────────
        DashSection(title = "Who can reach you") {
            DashRowLink(
                icon = NostrVaultIcons.People,
                title = VaultDashboardModel.trustTitle(wot.size),
                detail = VaultDashboardModel.trustDetail(cfg.chatRelayWotDepth),
                state = RowState.INFO,
                onClick = { onOpenScreen(Screen.RelayAccessSettings) },
            )
            DashDivider()
            DashRowLink(
                icon = Icons.Filled.PanTool,
                title = "Blocked",
                detail = VaultDashboardModel.blockedDetail(cfg.blockedForActiveAccount().size),
                state = RowState.INFO,
                onClick = { onOpenScreen(Screen.BlockedSettings) },
            )
            if (viewModel.hasPublishableOwnRelay(cfg)) {
                val publishes = viewModel.publishesRelayList(cfg)
                DashDivider()
                DashRow(
                    icon = Icons.Filled.Hub,
                    title = if (publishes) "Your relay list points here" else "Your relay list leaves out your vault",
                    detail = if (publishes) "Other apps find you at your vault." else "Other apps can't find you here until you publish it.",
                    state = if (publishes) RowState.DONE else RowState.TODO,
                ) {
                    if (!publishes) {
                        RowButton(title = "Publish", enabled = keyOk, onClick = viewModel::publishRelayList)
                    }
                }
            }
        }

        // ── In your vault ──────────────────────────────────────
        DashSection(title = "In your vault", framed = false) {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    OwnedTile(NostrVaultIcons.Document, "Notes", VaultDashboardModel.kindCount(kindCounts, 1), Modifier.weight(1f)) {
                        onOpenMode(VaultMode.NOTES)
                    }
                    OwnedTile(NostrVaultIcons.Articles, "Articles", VaultDashboardModel.kindCount(kindCounts, 30023), Modifier.weight(1f)) {
                        onOpenMode(VaultMode.ARTICLES)
                    }
                }
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    OwnedTile(NostrVaultIcons.TabMedia, "Media", mediaCount, Modifier.weight(1f)) {
                        onOpenMode(VaultMode.MEDIA)
                    }
                    OwnedTile(NostrVaultIcons.DMs, "Messages", VaultDashboardModel.messagesCount(kindCounts), Modifier.weight(1f)) {
                        onOpenScreen(Screen.DMInbox)
                    }
                }
            }
        }

        // ── Storage ────────────────────────────────────────────
        val split = VaultDashboardModel.storageSplit(storageSize, blossomSize, cacheSize, thumbnailSize)
        DashSection(title = "Storage", detail = VaultDashboardModel.size(split.total)) {
            StorageBar(split = split, onClick = { showStorageBreakdown = true })
        }
        if (showStorageBreakdown) {
            StorageBreakdownSheet(statsService = viewModel.statsService, onDismiss = { showStorageBreakdown = false })
        }

        // ── Keep it full ───────────────────────────────────────
        DashSection(title = "Keep it full") {
            DashRow(
                icon = Icons.Filled.ArrowCircleDown,
                title = "Import notes",
                detail = if (isImporting || importCompleted) importStatus.ifEmpty { "Importing…" }
                else VaultDashboardModel.importNotesDetail(cfg.importStartDate, history.notesImport, now),
                state = RowState.INFO,
                progress = if (isImporting) importProgress else null,
            ) {
                RowButton(
                    title = "Import",
                    isLoading = isImporting,
                    enabled = !isImporting && actionsEnabled,
                    onClick = { vaultViewModel.importNotes(context) },
                )
            }
            DashDivider()
            DashRow(
                icon = Icons.Filled.PhotoLibrary,
                title = "Import media",
                detail = if (mirror.running) mirror.status.ifEmpty { "Copying media…" }
                else VaultDashboardModel.importMediaDetail(history.mediaImport, now),
                state = RowState.INFO,
                progress = if (mirror.running) mirror.progress else null,
            ) {
                RowButton(
                    title = "Import",
                    isLoading = mirror.running,
                    enabled = !mirror.running && actionsEnabled,
                    onClick = vaultViewModel::importBlossom,
                )
            }
            DashDivider()
            DashRow(
                icon = Icons.Filled.Collections,
                title = "Back up media",
                detail = VaultDashboardModel.lastMade(history.mediaBackup, now),
                state = RowState.INFO,
            ) {
                RowButton(
                    title = "Back up",
                    isLoading = exportingMedia,
                    enabled = !exportBusy && actionsEnabled,
                    onClick = { vaultViewModel.exportMedia(context) },
                )
            }
            DashDivider()
            DashRow(
                icon = Icons.Filled.UploadFile,
                title = "Export notes",
                detail = VaultDashboardModel.lastMade(history.notesBackup, now),
                state = RowState.INFO,
            ) {
                RowButton(
                    title = "Export",
                    isLoading = exportingNotes,
                    enabled = !exportBusy && actionsEnabled,
                    onClick = { vaultViewModel.exportJsonl(context) },
                )
            }
            if (!actionsEnabled || exportStatus.isNotEmpty()) {
                DashDivider()
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 10.dp),
                ) {
                    if (exportStatus.isNotEmpty()) {
                        Icon(
                            if (exportIsError) Icons.Filled.Error else Icons.Filled.CheckCircle,
                            contentDescription = null,
                            tint = if (exportIsError) ZapOrange else SuccessGreen,
                            modifier = Modifier.size(14.dp),
                        )
                    }
                    Text(
                        exportStatus.ifEmpty { "Start your vault to import or back up." },
                        color = SecondaryText,
                        fontSize = 12.sp,
                    )
                }
            }
        }

        // ── Vault settings ─────────────────────────────────────
        DashSection(title = "Vault settings") {
            SettingLink(Icons.Filled.SettingsInputAntenna, "Relays", "${viewModel.relayCount(cfg)}") {
                onOpenScreen(Screen.Relays)
            }
            DashDivider()
            SettingLink(Icons.Filled.VerifiedUser, "Who Can Reach You", VaultDashboardModel.hops(cfg.chatRelayWotDepth)) {
                onOpenScreen(Screen.RelayAccessSettings)
            }
            DashDivider()
            SettingLink(Icons.Filled.Dns, "Media Servers", "${cfg.blossomMirrors.size}") {
                onOpenScreen(Screen.BlossomSettings)
            }
            DashDivider()
            SettingLink(Icons.Filled.Laptop, "Sync with Mac", if (macConfigured) "On" else "Off") {
                onOpenScreen(Screen.HavenRelaySettings)
            }
            DashDivider()
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable(role = Role.Switch) { viewModel.setAutoStart(!cfg.autoStartRelay) }
                    .padding(horizontal = 14.dp, vertical = 6.dp),
            ) {
                RowLabel(Icons.Filled.PowerSettingsNew, "Start automatically", Modifier.weight(1f))
                Switch(
                    checked = cfg.autoStartRelay,
                    onCheckedChange = null,
                    colors = SwitchDefaults.colors(checkedThumbColor = PrimaryText, checkedTrackColor = colors.primary),
                )
            }
        }

        // ── Activity ───────────────────────────────────────────
        CompactLogConsole(
            logs = logs,
            onViewAll = { onOpenScreen(Screen.RelayActivity) },
            modifier = Modifier.tutorialAnchor(TutorialContent.RELAY_ACTIVITY),
        )

        // ── Advanced ───────────────────────────────────────────
        DashSection(title = "Advanced") {
            SettingLink(Icons.Filled.Dns, "Relay details", null, onClick = onOpenRelayDetails)
            DashDivider()
            SettingLink(Icons.Filled.Image, "Media server details", null, onClick = onOpenMediaDetails)
            DashDivider()
            SettingLink(NostrVaultIcons.Logs, "Raw logs", null) { onOpenScreen(Screen.LogViewer) }
        }
    }
}

// ═══════════════════════════════════════════════════════════════════
// Status card
// ═══════════════════════════════════════════════════════════════════

@Composable
private fun StatusCard(
    runState: RunState,
    isExternal: Boolean,
    isPortConflict: Boolean,
    port: Int,
    address: String?,
    subtitle: String?,
    onStart: () -> Unit,
    onStop: () -> Unit,
    onRestart: () -> Unit,
    onForceRestart: () -> Unit,
) {
    val colors = LocalNostrVaultColors.current
    val context = LocalContext.current
    val clipboard = LocalClipboardManager.current
    val scope = rememberCoroutineScope()
    var didCopy by remember { mutableStateOf(false) }
    var menuOpen by remember { mutableStateOf(false) }

    val problem = if (isExternal) null else VaultDashboardModel.problemText(runState, isPortConflict, port)
    val statusColor = if (runState == RunState.RUNNING) SuccessGreen else ZapOrange
    val background by animateColorAsState(
        if (problem == null) SecondaryGroupedBg else ZapOrange.copy(alpha = 0.08f),
        animationSpec = Motion.toggle(), label = "statusBg",
    )
    val border = if (problem == null) CardBorder else ZapOrange.copy(alpha = 0.35f)

    fun copyAddress() {
        val text = address ?: return
        clipboard.setText(AnnotatedString(text))
        Toast.makeText(context, "Address copied", Toast.LENGTH_SHORT).show()
        didCopy = true
        scope.launch {
            delay(1_600)
            didCopy = false
        }
    }

    Column(
        verticalArrangement = Arrangement.spacedBy(14.dp),
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(background)
            .border(1.dp, border, RoundedCornerShape(14.dp))
            .padding(16.dp)
            .tutorialAnchor(TutorialContent.RELAY_STATUS),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            StatusDot(color = statusColor, pulses = VaultDashboardModel.pulses(runState))
            Spacer(Modifier.width(14.dp))
            Column(verticalArrangement = Arrangement.spacedBy(3.dp), modifier = Modifier.weight(1f)) {
                Text(
                    VaultDashboardModel.statusTitle(runState),
                    color = PrimaryText,
                    fontSize = 17.sp,
                    fontWeight = FontWeight.Bold,
                )
                if (subtitle != null) {
                    Text(subtitle, color = SecondaryText, fontSize = 13.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
                if (address != null) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(5.dp),
                        modifier = Modifier
                            .tutorialAnchor(TutorialContent.RELAY_ADDRESS)
                            .heightIn(min = 32.dp)
                            .clickable(onClickLabel = "Copy the address") { copyAddress() }
                            .semantics { contentDescription = "Vault address: $address. Tap to copy." },
                    ) {
                        Text(
                            address,
                            color = SecondaryText,
                            fontSize = 11.sp,
                            fontFamily = FontFamily.Monospace,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.weight(1f, fill = false),
                        )
                        Icon(
                            if (didCopy) NostrVaultIcons.Check else NostrVaultIcons.Copy,
                            contentDescription = null,
                            tint = if (didCopy) SuccessGreen else SecondaryText,
                            modifier = Modifier.size(12.dp),
                        )
                    }
                }
            }
            Spacer(Modifier.width(8.dp))
            Box {
                Surface(
                    onClick = { menuOpen = true },
                    enabled = runState != RunState.STARTING,
                    shape = CircleShape,
                    color = TertiaryGroupedBg,
                    modifier = Modifier.size(36.dp).semantics { contentDescription = "Vault controls" },
                ) {
                    Box(contentAlignment = Alignment.Center) {
                        Icon(Icons.Filled.MoreHoriz, contentDescription = null, tint = SecondaryText, modifier = Modifier.size(20.dp))
                    }
                }
                DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                    if (address != null) {
                        DropdownMenuItem(
                            text = { Text("Copy Address") },
                            leadingIcon = { Icon(NostrVaultIcons.Copy, null) },
                            onClick = { menuOpen = false; copyAddress() },
                        )
                    }
                    // An external relay belongs to another app: nothing here to start or stop.
                    if (!isExternal) {
                        if (runState == RunState.RUNNING || runState == RunState.IMPORTING) {
                            DropdownMenuItem(
                                text = { Text("Restart") },
                                leadingIcon = { Icon(NostrVaultIcons.Refresh, null) },
                                onClick = { menuOpen = false; onRestart() },
                            )
                            DropdownMenuItem(
                                text = { Text("Stop", color = MaterialErrorRed) },
                                leadingIcon = { Icon(NostrVaultIcons.Stop, null, tint = MaterialErrorRed) },
                                onClick = { menuOpen = false; onStop() },
                            )
                        } else if (runState != RunState.STARTING) {
                            DropdownMenuItem(
                                text = { Text("Start") },
                                leadingIcon = { Icon(NostrVaultIcons.PlayArrow, null) },
                                onClick = { menuOpen = false; onStart() },
                            )
                        }
                    }
                }
            }
        }

        if (problem != null) {
            Text(problem, color = SecondaryText, fontSize = 13.sp)
            Surface(
                onClick = { if (runState == RunState.NEEDS_FIX) onForceRestart() else onStart() },
                shape = RoundedCornerShape(10.dp),
                color = colors.primary,
                modifier = Modifier.fillMaxWidth().heightIn(min = 44.dp),
            ) {
                Box(contentAlignment = Alignment.Center, modifier = Modifier.heightIn(min = 44.dp)) {
                    Text(VaultDashboardModel.fixButtonTitle(runState), color = Color.White, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
                }
            }
        }
    }
}

private val MaterialErrorRed = com.nostrvault.ui.theme.ErrorRed

/** The halo pulses on its own; nothing else in the sheet picks the loop up. */
@Composable
private fun StatusDot(color: Color, pulses: Boolean) {
    val spec = if (pulses) Motion.ambientPulse else null
    val haloScale = if (spec == null) {
        1f
    } else {
        val transition = rememberInfiniteTransition(label = "halo")
        val scale by transition.animateFloat(1f, 1.25f, spec, label = "haloScale")
        scale
    }
    Box(contentAlignment = Alignment.Center, modifier = Modifier.size(32.dp)) {
        Box(Modifier.size(28.dp).scale(haloScale).background(color.copy(alpha = 0.18f), CircleShape))
        Box(Modifier.size(12.dp).background(color, CircleShape))
    }
}

// ═══════════════════════════════════════════════════════════════════
// Storage bar
// ═══════════════════════════════════════════════════════════════════

@Composable
private fun StorageBar(split: VaultDashboardModel.StorageSplit, onClick: () -> Unit) {
    val colors = LocalNostrVaultColors.current
    val parts = listOf(
        Triple("Notes", split.notes, colors.primary),
        Triple("Media", split.media, InfoBlue),
        Triple("Cache", split.cache, SecondaryText),
    )
    val total = maxOf(1L, split.total)
    Column(
        verticalArrangement = Arrangement.spacedBy(12.dp),
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClickLabel = "Storage breakdown", onClick = onClick)
            .padding(14.dp),
    ) {
        BoxWithConstraints(
            modifier = Modifier
                .fillMaxWidth()
                .height(10.dp)
                .clip(CircleShape)
                .background(TertiaryGroupedBg),
        ) {
            val width = maxWidth - 4.dp
            Row(horizontalArrangement = Arrangement.spacedBy(2.dp)) {
                parts.filter { it.second > 0 }.forEach { (_, bytes, color) ->
                    val w = maxOf(3.dp, width * (bytes.toFloat() / total.toFloat()))
                    Box(Modifier.width(w).height(10.dp).background(color))
                }
            }
        }
        Row(verticalAlignment = Alignment.CenterVertically) {
            parts.forEach { (label, bytes, color) ->
                Column(verticalArrangement = Arrangement.spacedBy(2.dp), modifier = Modifier.weight(1f)) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                        Box(Modifier.size(7.dp).background(color, CircleShape))
                        Text(label, color = PrimaryText, fontSize = 12.sp, maxLines = 1)
                    }
                    Text(
                        VaultDashboardModel.size(bytes),
                        color = SecondaryText,
                        fontSize = 12.sp,
                        maxLines = 1,
                        modifier = Modifier.padding(start = 12.dp),
                    )
                }
            }
            Icon(NostrVaultIcons.Navigate, contentDescription = null, tint = SecondaryText.copy(alpha = 0.6f), modifier = Modifier.size(16.dp))
        }
    }
}

// ═══════════════════════════════════════════════════════════════════
// Building blocks
// ═══════════════════════════════════════════════════════════════════

/** A titled card of rows: the section style every Vault Dashboard block uses. */
@Composable
private fun DashSection(
    title: String,
    detail: String? = null,
    /** Off for content that draws its own cards, like the tiles. */
    framed: Boolean = true,
    content: @Composable () -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.fillMaxWidth().padding(horizontal = 4.dp).semantics(mergeDescendants = true) { heading() },
        ) {
            Text(title, color = SecondaryText, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
            if (detail != null) {
                Text(detail, color = SecondaryText, fontSize = 13.sp, fontWeight = FontWeight.Medium)
            }
        }
        if (framed) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(12.dp))
                    .background(SecondaryGroupedBg)
                    .border(1.dp, CardBorder, RoundedCornerShape(12.dp)),
            ) { content() }
        } else {
            content()
        }
    }
}

@Composable
private fun DashDivider() {
    HorizontalDivider(color = CardBorder, modifier = Modifier.padding(start = 52.dp))
}

private enum class RowState { DONE, TODO, INFO }

@Composable
private fun RowState.color(): Color = when (this) {
    RowState.DONE -> SuccessGreen
    RowState.TODO -> ZapOrange
    RowState.INFO -> LocalNostrVaultColors.current.primary
}

private fun RowState.spoken(): String = when (this) {
    RowState.DONE -> "Done"
    RowState.TODO -> "Needs attention"
    RowState.INFO -> ""
}

@Composable
private fun RowIcon(icon: ImageVector, state: RowState) {
    val tint = state.color()
    Box(modifier = Modifier.size(30.dp)) {
        Box(
            contentAlignment = Alignment.Center,
            modifier = Modifier.size(30.dp).background(tint.copy(alpha = 0.14f), RoundedCornerShape(8.dp)),
        ) {
            Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(16.dp))
        }
        if (state != RowState.INFO) {
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier
                    .align(Alignment.BottomEnd)
                    .offset(x = 4.dp, y = 4.dp)
                    .size(13.dp)
                    .background(Color.White, CircleShape),
            ) {
                Icon(
                    if (state == RowState.DONE) Icons.Filled.CheckCircle else Icons.Filled.Error,
                    contentDescription = null,
                    tint = tint,
                    modifier = Modifier.size(13.dp),
                )
            }
        }
    }
}

@Composable
private fun RowText(title: String, detail: String, modifier: Modifier = Modifier) {
    Column(verticalArrangement = Arrangement.spacedBy(2.dp), modifier = modifier) {
        Text(title, color = PrimaryText, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
        Text(detail, color = SecondaryText, fontSize = 12.sp)
    }
}

/** A row with a trailing control (a button) and an optional progress bar. */
@Composable
private fun DashRow(
    icon: ImageVector,
    title: String,
    detail: String,
    state: RowState,
    progress: Float? = null,
    trailing: @Composable () -> Unit,
) {
    Column(
        verticalArrangement = Arrangement.spacedBy(8.dp),
        modifier = Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 11.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            RowIcon(icon, state)
            RowText(
                title,
                detail,
                Modifier.weight(1f).semantics(mergeDescendants = true) { stateDescription = state.spoken() },
            )
            trailing()
        }
        if (progress != null) {
            LinearProgressIndicator(
                progress = { progress.coerceIn(0f, 1f) },
                color = LocalNostrVaultColors.current.primary,
                trackColor = TertiaryGroupedBg,
                modifier = Modifier.fillMaxWidth().padding(start = 42.dp),
            )
        }
    }
}

/** A row that opens a settings page. */
@Composable
private fun DashRowLink(
    icon: ImageVector,
    title: String,
    detail: String,
    state: RowState,
    onClick: () -> Unit,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        modifier = Modifier
            .fillMaxWidth()
            .clickable(role = Role.Button, onClick = onClick)
            .semantics(mergeDescendants = true) { stateDescription = state.spoken() }
            .padding(horizontal = 14.dp, vertical = 11.dp),
    ) {
        RowIcon(icon, state)
        RowText(title, detail, Modifier.weight(1f))
        if (state == RowState.TODO) {
            Text("Fix", color = ZapOrange, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
        }
        Icon(NostrVaultIcons.Navigate, contentDescription = null, tint = SecondaryText.copy(alpha = 0.6f), modifier = Modifier.size(16.dp))
    }
}

@Composable
private fun RowLabel(icon: ImageVector, title: String, modifier: Modifier = Modifier) {
    val primary = LocalNostrVaultColors.current.primary
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp), modifier = modifier) {
        Box(
            contentAlignment = Alignment.Center,
            modifier = Modifier.size(30.dp).background(primary.copy(alpha = 0.14f), RoundedCornerShape(8.dp)),
        ) {
            Icon(icon, contentDescription = null, tint = primary, modifier = Modifier.size(16.dp))
        }
        Text(title, color = PrimaryText, fontSize = 15.sp, fontWeight = FontWeight.Medium)
    }
}

/** A quick link to one of the vault's own settings, showing its current value. */
@Composable
private fun SettingLink(icon: ImageVector, title: String, value: String?, onClick: () -> Unit) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 48.dp)
            .clickable(role = Role.Button, onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 8.dp),
    ) {
        RowLabel(icon, title, Modifier.weight(1f))
        if (value != null) {
            Text(value, color = SecondaryText, fontSize = 15.sp)
        }
        Icon(NostrVaultIcons.Navigate, contentDescription = null, tint = SecondaryText.copy(alpha = 0.6f), modifier = Modifier.size(16.dp))
    }
}

@Composable
private fun RowButton(title: String, isLoading: Boolean = false, enabled: Boolean = true, onClick: () -> Unit) {
    val primary = LocalNostrVaultColors.current.primary
    Surface(
        onClick = onClick,
        enabled = enabled && !isLoading,
        shape = CircleShape,
        color = primary.copy(alpha = 0.12f),
        modifier = Modifier.heightIn(min = 30.dp),
    ) {
        Box(contentAlignment = Alignment.Center, modifier = Modifier.heightIn(min = 30.dp).padding(horizontal = 12.dp)) {
            if (isLoading) {
                CircularProgressIndicator(color = primary, strokeWidth = 2.dp, modifier = Modifier.size(14.dp))
            } else {
                Text(
                    title,
                    color = primary.copy(alpha = if (enabled) 1f else 0.4f),
                    fontSize = 13.sp,
                    fontWeight = FontWeight.SemiBold,
                )
            }
        }
    }
}

/** One thing the vault holds: a count that opens its list in the Vault tab. */
@Composable
private fun OwnedTile(icon: ImageVector, title: String, count: Int?, modifier: Modifier = Modifier, onClick: () -> Unit) {
    val primary = LocalNostrVaultColors.current.primary
    Surface(
        onClick = onClick,
        shape = RoundedCornerShape(12.dp),
        color = SecondaryGroupedBg,
        modifier = modifier
            .border(1.dp, CardBorder, RoundedCornerShape(12.dp))
            .semantics(mergeDescendants = true) {
                contentDescription = "$title, ${count?.let { "%,d".format(it) } ?: "Loading"}. Opens ${title.lowercase()} in the Vault tab"
            },
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.padding(14.dp)) {
            Icon(icon, contentDescription = null, tint = primary, modifier = Modifier.size(18.dp))
            Text(
                count?.let { "%,d".format(it) } ?: "—",
                color = if (count == null) SecondaryText else PrimaryText,
                fontSize = 22.sp,
                fontWeight = FontWeight.Bold,
                maxLines = 1,
            )
            Text(title, color = SecondaryText, fontSize = 13.sp)
        }
    }
}
