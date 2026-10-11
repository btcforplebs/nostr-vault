package com.nostrvault.ui.screens.dashboard

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import com.nostrvault.tutorials.TutorialContent
import com.nostrvault.tutorials.tutorialAnchor
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.data.model.*
import com.nostrvault.relay.RelayForegroundService
import com.nostrvault.service.StatsService
import com.nostrvault.ui.theme.*
import kotlinx.coroutines.*
import kotlinx.serialization.json.*

// ═══════════════════════════════════════════════════════════════════
// Dashboard bottom sheet content
// ═══════════════════════════════════════════════════════════════════

@Composable
internal fun DashboardSheetContent(
    /** The page title; the back arrow shows when [onBack] is set. */
    title: String,
    onBack: (() -> Unit)?,
    totalEvents: Int,
    storageUsed: String,
    noteCount: Int,
    dmCount: Int,
    mediaCount: Int,
    mediaSize: String,
    isLoading: Boolean,
    relayStatus: RelayForegroundService.RelayStatus,
    relayAddress: String?,
    isExternalRelay: Boolean,
    isLocked: Boolean,
    isPortConflict: Boolean,
    onRefresh: () -> Unit,
    /** Blossom's dashboard sections under the relay's; null to leave them out. */
    blossomSection: (@Composable () -> Unit)?,
    onStartRelay: () -> Unit,
    onStopRelay: () -> Unit,
    onRestartRelay: () -> Unit,
    onForceRestart: () -> Unit,
    onClearLocks: () -> Unit,
    logs: List<com.nostrvault.relay.RelayLogParser.LogEntry>,
    onViewAllLogs: () -> Unit,
    statsService: StatsService,
    ownerPubkey: String,
    cacheDir: String?,
    cacheTTLDays: Int,
    isImporting: Boolean,
    importProgress: Float,
    importStatusMessage: String,
    importCompleted: Boolean,
    isExportingJsonl: Boolean,
    isExportingMedia: Boolean,
    isImportingBlossom: Boolean,
    onImportNotes: () -> Unit,
    onImportBlossom: () -> Unit,
    onExportJsonl: () -> Unit,
    onExportMedia: () -> Unit,
    onDismissImport: () -> Unit,
) {
    val colors = LocalNostrVaultColors.current

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 16.dp)
            .padding(bottom = 32.dp),
    ) {
        // Header
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .fillMaxWidth()
                .padding(bottom = 16.dp),
        ) {
            if (onBack != null) {
                IconButton(onClick = onBack, modifier = Modifier.size(32.dp)) {
                    Icon(NostrVaultIcons.Back, "Back to Vault Dashboard", tint = colors.primary, modifier = Modifier.size(20.dp))
                }
            } else {
                Icon(
                    imageVector = NostrVaultIcons.TabVault,
                    contentDescription = null,
                    tint = colors.primary,
                    modifier = Modifier.size(20.dp),
                )
            }
            Spacer(Modifier.width(8.dp))
            Text(
                text = title,
                color = PrimaryText,
                fontSize = 18.sp,
                fontWeight = FontWeight.Bold,
            )
            Spacer(Modifier.weight(1f))

            IconButton(onClick = onRefresh, modifier = Modifier.size(32.dp)) {
                Icon(
                    NostrVaultIcons.Refresh,
                    "Refresh",
                    tint = SecondaryText,
                    modifier = Modifier.size(18.dp),
                )
            }
        }

        // Relay status header
        com.nostrvault.ui.screens.dashboard.RelayStatusHeader(
            relayStatus = relayStatus,
            relayAddress = relayAddress,
            isExternalRelay = isExternalRelay,
            isLocked = isLocked,
            isPortConflict = isPortConflict,
            onStartRelay = onStartRelay,
            onStopRelay = onStopRelay,
            onRestartRelay = onRestartRelay,
            onForceRestart = onForceRestart,
            onClearLocks = onClearLocks,
        )

        Spacer(Modifier.height(12.dp))

        // Compact log console
        if (logs.isNotEmpty()) {
            com.nostrvault.ui.screens.dashboard.CompactLogConsole(
                logs = logs,
                onViewAll = onViewAllLogs,
                modifier = Modifier.tutorialAnchor(TutorialContent.RELAY_ACTIVITY),
            )
            Spacer(Modifier.height(12.dp))
        }

        if (isLoading) {
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(32.dp),
            ) {
                CircularProgressIndicator(color = colors.primary)
            }
        } else {
            // Breakdown sheet state
            var showEventBreakdown by remember { mutableStateOf(false) }
            var showStorageBreakdown by remember { mutableStateOf(false) }
            var showBlossomBreakdown by remember { mutableStateOf(false) }
            var showCacheBreakdown by remember { mutableStateOf(false) }

            // Stats grid -- clickable cards that open breakdown sheets
            Row(
                horizontalArrangement = Arrangement.spacedBy(12.dp),
                modifier = Modifier.fillMaxWidth(),
            ) {
                StatsCard(
                    title = "Total Events",
                    value = totalEvents.toString(),
                    icon = NostrVaultIcons.AppIcon,
                    modifier = Modifier.weight(1f),
                    onClick = { showEventBreakdown = true },
                )
                StatsCard(
                    title = "Storage",
                    value = storageUsed,
                    icon = NostrVaultIcons.Storage,
                    modifier = Modifier.weight(1f),
                    onClick = { showStorageBreakdown = true },
                )
            }

            Spacer(Modifier.height(12.dp))

            Row(
                horizontalArrangement = Arrangement.spacedBy(12.dp),
                modifier = Modifier.fillMaxWidth(),
            ) {
                StatsCard(
                    title = "Notes",
                    value = noteCount.toString(),
                    icon = NostrVaultIcons.Feed,
                    modifier = Modifier.weight(1f),
                )
                StatsCard(
                    title = "DMs",
                    value = dmCount.toString(),
                    icon = NostrVaultIcons.DMs,
                    modifier = Modifier.weight(1f),
                )
            }

            Spacer(Modifier.height(12.dp))

            Row(
                horizontalArrangement = Arrangement.spacedBy(12.dp),
                modifier = Modifier.fillMaxWidth(),
            ) {
                StatsCard(
                    title = "Blossom Media",
                    value = mediaCount.toString(),
                    icon = NostrVaultIcons.Blossom,
                    modifier = Modifier.weight(1f),
                    onClick = { showBlossomBreakdown = true },
                )
                StatsCard(
                    title = "Media Cache",
                    value = mediaSize,
                    icon = NostrVaultIcons.Media,
                    modifier = Modifier.weight(1f),
                    onClick = { showCacheBreakdown = true },
                )
            }

            // Breakdown sheets
            if (showEventBreakdown) {
                com.nostrvault.ui.screens.dashboard.EventKindBreakdownSheet(
                    statsService = statsService,
                    onDismiss = { showEventBreakdown = false },
                )
            }
            if (showStorageBreakdown) {
                com.nostrvault.ui.screens.dashboard.StorageBreakdownSheet(
                    statsService = statsService,
                    onDismiss = { showStorageBreakdown = false },
                )
            }
            if (showBlossomBreakdown) {
                com.nostrvault.ui.screens.dashboard.BlossomBreakdownSheet(
                    statsService = statsService,
                    ownerPubkey = ownerPubkey,
                    onDismiss = { showBlossomBreakdown = false },
                )
            }
            if (showCacheBreakdown) {
                com.nostrvault.ui.screens.dashboard.CacheBreakdownSheet(
                    statsService = statsService,
                    cacheDir = cacheDir,
                    cacheTTLDays = cacheTTLDays,
                    onDismiss = { showCacheBreakdown = false },
                )
            }

            Spacer(Modifier.height(24.dp))

            // Import/Export actions
            com.nostrvault.ui.screens.dashboard.ImportExportSection(
                isImporting = isImporting,
                importProgress = importProgress,
                importStatusMessage = importStatusMessage,
                importCompleted = importCompleted,
                isExportingJsonl = isExportingJsonl,
                isExportingMedia = isExportingMedia,
                isImportingBlossom = isImportingBlossom,
                actionsEnabled = isImporting ||
                    relayStatus == RelayForegroundService.RelayStatus.RUNNING ||
                    relayStatus == RelayForegroundService.RelayStatus.IMPORTING,
                onImportNotes = onImportNotes,
                onImportBlossom = onImportBlossom,
                onExportJsonl = onExportJsonl,
                onExportMedia = onExportMedia,
                onDismissImport = onDismissImport,
            )

            Spacer(Modifier.height(24.dp))

            // Blossom's sections, under the relay's (iOS BlossomDashboardView(embedded:)).
            if (blossomSection != null) {
                HorizontalDivider(modifier = Modifier.padding(bottom = 16.dp))
                blossomSection()
            }
        }
    }
}

// ═══════════════════════════════════════════════════════════════════
// Stats card
// ═══════════════════════════════════════════════════════════════════

@Composable
private fun StatsCard(
    title: String,
    value: String,
    icon: ImageVector,
    modifier: Modifier = Modifier,
    onClick: (() -> Unit)? = null,
) {
    val colors = LocalNostrVaultColors.current

    Surface(
        color = SecondaryGroupedBg,
        shape = RoundedCornerShape(12.dp),
        onClick = onClick ?: {},
        enabled = onClick != null,
        modifier = modifier,
    ) {
        Column(
            modifier = Modifier.padding(16.dp),
        ) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                tint = colors.primary,
                modifier = Modifier.size(20.dp),
            )
            Spacer(Modifier.height(8.dp))
            Text(
                text = value,
                color = PrimaryText,
                fontSize = 22.sp,
                fontWeight = FontWeight.Bold,
            )
            Text(
                text = title,
                color = SecondaryText,
                fontSize = 12.sp,
            )
        }
    }
}
