package com.nostrvault.ui.screens

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import com.nostrvault.ui.screens.dashboard.*
import com.nostrvault.ui.theme.*

/**
 * Blossom's dashboard (stats, mirror management, pull/push sync, activity
 * log), as the Vault Dashboard's lower half: its sections under a Blossom
 * heading with a refresh button (iOS `BlossomDashboardView(embedded: true)`).
 * It used to be a screen of its own, opened from the Media tab.
 */
@Composable
internal fun BlossomDashboardSections(
    onOpenSettings: () -> Unit,
    viewModel: BlossomDashboardViewModel = hiltViewModel(),
) {
    LaunchedEffect(viewModel) { viewModel.reloadIfStale() }
    val colors = LocalNostrVaultColors.current
    Column {
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth().padding(bottom = 12.dp)) {
            Icon(NostrVaultIcons.Blossom, contentDescription = null, tint = colors.primary, modifier = Modifier.size(20.dp))
            Spacer(Modifier.width(8.dp))
            Text("Blossom", color = PrimaryText, fontSize = 18.sp, fontWeight = FontWeight.Bold)
            Spacer(Modifier.weight(1f))
            // iOS embeddedBody's gearshape: opens the Media Servers settings.
            IconButton(onClick = onOpenSettings, modifier = Modifier.size(32.dp)) {
                Icon(NostrVaultIcons.Settings, "Blossom settings", tint = SecondaryText, modifier = Modifier.size(18.dp))
            }
            IconButton(onClick = viewModel::loadDashboard, modifier = Modifier.size(32.dp)) {
                Icon(NostrVaultIcons.Refresh, "Refresh Blossom", tint = SecondaryText, modifier = Modifier.size(18.dp))
            }
        }
        BlossomDashboardBody(viewModel)
    }
}

/** Blossom's stats, quick actions, mirrors and activity log. */
@Composable
private fun ColumnScope.BlossomDashboardBody(viewModel: BlossomDashboardViewModel) {
    val totalFiles by viewModel.totalFiles.collectAsState()
    val totalSize by viewModel.totalSize.collectAsState()
    val isLoadingStats by viewModel.isLoadingStats.collectAsState()
    val backedUpCount by viewModel.backedUpCount.collectAsState()
    val mirrors by viewModel.mirrors.collectAsState()
    val isPulling by viewModel.isPulling.collectAsState()
    val isPushing by viewModel.isPushing.collectAsState()
    val syncMessage by viewModel.syncMessage.collectAsState()
    val syncProgress by viewModel.syncProgress.collectAsState()
    val activityLogs by viewModel.activityLogs.collectAsState()

    val colors = LocalNostrVaultColors.current
    val activeMirrors = mirrors.count { it.isHealthy == true }
    val backupPercentage = if (totalFiles > 0) (backedUpCount * 100) / totalFiles else 0
    val needsBackupCount = (totalFiles - backedUpCount).coerceAtLeast(0)


            // ── Stats cards ──────────────────────────────────────

            if (isLoadingStats) {
                Box(
                    contentAlignment = Alignment.Center,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(32.dp),
                ) {
                    CircularProgressIndicator(color = colors.primary)
                }
            } else {
                Row(
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    BlossomStatCard(
                        title = "Total Files",
                        value = totalFiles.toString(),
                        icon = NostrVaultIcons.Blossom,
                        modifier = Modifier.weight(1f),
                    )
                    BlossomStatCard(
                        title = "Storage Used",
                        value = formatSize(totalSize),
                        icon = NostrVaultIcons.Storage,
                        modifier = Modifier.weight(1f),
                    )
                }

                Spacer(Modifier.height(12.dp))

                Row(
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    BlossomStatCard(
                        title = "Active Mirrors",
                        value = "$activeMirrors",
                        icon = NostrVaultIcons.Relay,
                        modifier = Modifier.weight(1f),
                    )
                    BlossomStatCard(
                        title = "Backed Up",
                        value = "$backupPercentage%",
                        icon = NostrVaultIcons.Verified,
                        iconTint = if (backupPercentage == 100) SuccessGreen else ZapOrange,
                        modifier = Modifier.weight(1f),
                    )
                }
            }

            Spacer(Modifier.height(24.dp))

            // ── Quick actions ────────────────────────────────────

            Text(
                text = "Quick Actions",
                color = PrimaryText,
                fontSize = 16.sp,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.padding(bottom = 12.dp),
            )

            Row(
                horizontalArrangement = Arrangement.spacedBy(12.dp),
                modifier = Modifier.fillMaxWidth(),
            ) {
                ActionButton(
                    icon = NostrVaultIcons.Import,
                    title = "Pull",
                    isLoading = isPulling,
                    enabled = !isPulling && !isPushing,
                    modifier = Modifier.weight(1f),
                    onClick = viewModel::pullFromNotes,
                )
                ActionButton(
                    icon = NostrVaultIcons.UploadIcon,
                    title = if (needsBackupCount > 0) "Backup $needsBackupCount" else "100% Backed Up",
                    isLoading = isPushing,
                    enabled = !isPulling && !isPushing && needsBackupCount > 0,
                    modifier = Modifier.weight(1f),
                    onClick = viewModel::pushToMirrors,
                )
                ActionButton(
                    icon = NostrVaultIcons.Refresh,
                    title = "Refresh",
                    enabled = !isPulling && !isPushing,
                    modifier = Modifier.weight(1f),
                    onClick = viewModel::loadDashboard,
                )
            }

            // Inline sync progress while a pull/push is running (matches iOS)
            if (isPulling || isPushing) {
                Spacer(Modifier.height(12.dp))
                Surface(
                    color = SecondaryGroupedBg,
                    shape = RoundedCornerShape(8.dp),
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Column(
                        modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp),
                        verticalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        LinearProgressIndicator(
                            progress = { syncProgress },
                            color = colors.primary,
                            trackColor = TertiaryGroupedBg,
                            modifier = Modifier.fillMaxWidth(),
                        )
                        if (syncMessage.isNotBlank()) {
                            Text(
                                text = syncMessage,
                                color = SecondaryText,
                                fontSize = 11.sp,
                                fontFamily = FontFamily.Monospace,
                            )
                        }
                    }
                }
            } else if (syncMessage.isNotBlank()) {
                // Idle completion message (e.g. "Push complete")
                Spacer(Modifier.height(8.dp))
                Text(
                    text = syncMessage,
                    color = SecondaryText,
                    fontSize = 12.sp,
                )
            }

            Spacer(Modifier.height(24.dp))

            // ── Mirror status ────────────────────────────────────

            MirrorStatusSection(
                mirrors = mirrors,
                onRefreshHealth = viewModel::checkMirrorHealth,
            )

            Spacer(Modifier.height(24.dp))

            // ── Storage overview (iOS StorageBreakdownSection) ───

            Text(
                text = "Storage Overview",
                color = PrimaryText,
                fontSize = 16.sp,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.padding(bottom = 12.dp),
            )
            Surface(
                color = SecondaryGroupedBg,
                shape = RoundedCornerShape(10.dp),
                modifier = Modifier.fillMaxWidth(),
            ) {
                Column {
                    BlossomStorageRow("Total Files", "$totalFiles", NostrVaultIcons.Document, InfoBlue)
                    HorizontalDivider(color = TertiaryText.copy(alpha = 0.15f))
                    BlossomStorageRow("Total Size", formatSize(totalSize), NostrVaultIcons.Storage, colors.primary)
                    HorizontalDivider(color = TertiaryText.copy(alpha = 0.15f))
                    BlossomStorageRow("Backed Up", "$backedUpCount ($backupPercentage%)", NostrVaultIcons.Verified, SuccessGreen)
                    HorizontalDivider(color = TertiaryText.copy(alpha = 0.15f))
                    BlossomStorageRow("Needs Backup", "$needsBackupCount", NostrVaultIcons.Alert, ZapOrange)
                }
            }

            Spacer(Modifier.height(24.dp))

            // ── Activity log ─────────────────────────────────────

            Text(
                text = "Activity",
                color = PrimaryText,
                fontSize = 16.sp,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.padding(bottom = 12.dp),
            )

            BlossomActivityLogView(logs = activityLogs)
}


@Composable
private fun BlossomStorageRow(
    label: String,
    value: String,
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    tint: androidx.compose.ui.graphics.Color,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 10.dp),
    ) {
        Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(18.dp))
        Spacer(Modifier.width(12.dp))
        Text(label, color = PrimaryText, fontSize = 13.sp, fontWeight = FontWeight.Medium, modifier = Modifier.weight(1f))
        Text(value, color = SecondaryText, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
    }
}

@Composable
private fun BlossomStatCard(
    title: String,
    value: String,
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    modifier: Modifier = Modifier,
    iconTint: androidx.compose.ui.graphics.Color? = null,
) {
    val colors = LocalNostrVaultColors.current

    Surface(
        color = SecondaryGroupedBg,
        shape = RoundedCornerShape(12.dp),
        modifier = modifier,
    ) {
        Column(modifier = Modifier.padding(16.dp)) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                tint = iconTint ?: colors.primary,
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
