package com.nostrvault.ui.screens.dashboard

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
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
import androidx.compose.material.icons.filled.PanTool
import androidx.compose.material.icons.filled.PhotoLibrary
import androidx.compose.material.icons.filled.PowerSettingsNew
import androidx.compose.material.icons.filled.SettingsInputAntenna
import androidx.compose.material.icons.filled.UploadFile
import androidx.compose.material.icons.filled.VerifiedUser
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
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
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import com.nostrvault.data.model.VaultMode
import com.nostrvault.relay.LogStore
import com.nostrvault.relay.RelayForegroundService
import com.nostrvault.tutorials.TutorialContent
import com.nostrvault.tutorials.tutorialAnchor
import com.nostrvault.ui.navigation.Screen
import com.nostrvault.ui.screens.dashboard.VaultDashboardModel.RunState
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.NostrVaultIcons
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText
import com.nostrvault.ui.theme.SuccessGreen
import com.nostrvault.ui.theme.ZapOrange
import kotlinx.coroutines.delay

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
