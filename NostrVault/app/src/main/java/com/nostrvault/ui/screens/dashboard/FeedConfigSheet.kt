package com.nostrvault.ui.screens.dashboard

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.remote.WebSocketClient
import com.nostrvault.service.FeedRelayHealth
import com.nostrvault.service.FeedService
import com.nostrvault.ui.theme.*
import dagger.hilt.EntryPoint
import dagger.hilt.InstallIn
import dagger.hilt.android.EntryPointAccessors
import dagger.hilt.components.SingletonComponent
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * The feed's singletons, reached from the sheet itself so the Noise Filtering
 * and Actions sections work from both places it opens (feed and dashboard)
 * without either caller threading more state through.
 */
@EntryPoint
@InstallIn(SingletonComponent::class)
interface FeedConfigEntryPoint {
    fun feedService(): FeedService
    fun configStore(): ConfigStore
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FeedConfigSheet(
    showReposts: Boolean,
    showReplies: Boolean,
    autoLoadNewNotes: Boolean,
    feedRelays: List<String>,
    /** Each feed relay's socket state; a relay missing here is one the feed is not using. */
    relayStates: Map<String, WebSocketClient.ConnectionState>,
    onToggleReposts: (Boolean) -> Unit,
    onToggleReplies: (Boolean) -> Unit,
    onToggleAutoLoad: (Boolean) -> Unit,
    onManageRelays: () -> Unit,
    onDismiss: () -> Unit,
) {
    val colors = LocalNostrVaultColors.current
    val context = LocalContext.current
    val services = remember(context) {
        EntryPointAccessors.fromApplication(context.applicationContext, FeedConfigEntryPoint::class.java)
    }
    val feedService = services.feedService()
    val config by services.configStore().config.collectAsState()
    val noise = remember(config) { NoiseFilterCounts.of(config) }
    val isLoadingFeed by feedService.isLoadingFeed.collectAsState()
    val pending by feedService.pendingNotes.collectAsState()
    // Counted through the feed's filter, as the New Posts pill counts it, off
    // the main thread (FeedViewModel.pendingNoteCount).
    val pendingCount by produceState(0, pending, config) {
        value = withContext(Dispatchers.Default) { feedService.visiblePendingCount(pending) }
    }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        containerColor = WindowBackground,
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                // Four sections no longer fit a small phone's sheet.
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp)
                .padding(bottom = 32.dp),
        ) {
            // Header
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.fillMaxWidth().padding(bottom = 16.dp),
            ) {
                Icon(
                    imageVector = NostrVaultIcons.Settings,
                    contentDescription = null,
                    tint = colors.primary,
                    modifier = Modifier.size(20.dp),
                )
                Spacer(Modifier.width(8.dp))
                Text(
                    text = "Feed Settings",
                    color = PrimaryText,
                    fontSize = 18.sp,
                    fontWeight = FontWeight.Bold,
                )
            }

            // ── Content Filters ──────────────────────────────────

            Text(
                text = "Content Filters",
                color = SecondaryText,
                fontSize = 13.sp,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.padding(bottom = 8.dp),
            )

            Surface(
                color = SecondaryGroupedBg,
                shape = RoundedCornerShape(12.dp),
                modifier = Modifier.fillMaxWidth(),
            ) {
                Column {
                    ToggleRow(
                        label = "Show Reposts",
                        icon = NostrVaultIcons.Repost,
                        checked = showReposts,
                        onToggle = onToggleReposts,
                    )
                    HorizontalDivider(color = TertiaryText.copy(alpha = 0.15f))
                    ToggleRow(
                        label = "Show Replies",
                        icon = NostrVaultIcons.Reply,
                        checked = showReplies,
                        onToggle = onToggleReplies,
                    )
                    HorizontalDivider(color = TertiaryText.copy(alpha = 0.15f))
                    ToggleRow(
                        label = "Auto-Load New Notes",
                        icon = NostrVaultIcons.AutoLoad,
                        checked = autoLoadNewNotes,
                        onToggle = onToggleAutoLoad,
                    )
                }
            }

            Spacer(Modifier.height(24.dp))

            // ── Noise Filtering ──────────────────────────────────

            Text(
                text = "Noise Filtering",
                color = SecondaryText,
                fontSize = 13.sp,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.padding(bottom = 8.dp),
            )

            Surface(
                color = SecondaryGroupedBg,
                shape = RoundedCornerShape(12.dp),
                modifier = Modifier.fillMaxWidth(),
            ) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.SpaceBetween,
                    modifier = Modifier.fillMaxWidth().padding(12.dp),
                ) {
                    NoiseStat(NostrVaultIcons.Blocked, ZapOrange, "${noise.blocked}", "Blocked")
                    NoiseStat(NostrVaultIcons.TrustOff, ErrorRed.copy(alpha = 0.8f), "${noise.blacklisted}", "Blacklisted")
                    // FeedNote.isNoiseOrSpam runs on every feed; there is no off switch.
                    NoiseStat(NostrVaultIcons.TrustShield, SuccessGreen, "Active", "Spam Filter")
                }
            }

            Text(
                text = "Blocked users' content is hidden from your feed. Spam and noise are filtered automatically.",
                color = TertiaryText,
                fontSize = 11.sp,
                fontStyle = FontStyle.Italic,
                modifier = Modifier.padding(top = 6.dp),
            )

            Spacer(Modifier.height(24.dp))

            // ── Feed Relays ──────────────────────────────────────

            Text(
                text = "Feed Relays",
                color = SecondaryText,
                fontSize = 13.sp,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.padding(bottom = 8.dp),
            )

            Surface(
                color = SecondaryGroupedBg,
                shape = RoundedCornerShape(12.dp),
                modifier = Modifier.fillMaxWidth(),
            ) {
                Column(modifier = Modifier.padding(16.dp)) {
                    if (feedRelays.isEmpty()) {
                        Text(
                            text = "Using default relays",
                            color = TertiaryText,
                            fontSize = 13.sp,
                        )
                    } else {
                        feedRelays.forEachIndexed { index, relay ->
                            // That relay's own socket, not the feed's overall
                            // status, which is "Live" as soon as any notes load.
                            val state = relayStates[FeedRelayHealth.key(relay)]
                            val stateColor = when (state) {
                                WebSocketClient.ConnectionState.CONNECTED -> SuccessGreen
                                WebSocketClient.ConnectionState.CONNECTING,
                                WebSocketClient.ConnectionState.RECONNECTING -> WarningYellow
                                WebSocketClient.ConnectionState.DISCONNECTED -> ErrorRed
                                null -> TertiaryText
                            }
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .padding(vertical = 4.dp),
                            ) {
                                Icon(
                                    imageVector = NostrVaultIcons.Relay,
                                    contentDescription = null,
                                    tint = stateColor,
                                    modifier = Modifier.size(14.dp),
                                )
                                Spacer(Modifier.width(8.dp))
                                Text(
                                    text = relay
                                        .removePrefix("wss://")
                                        .removePrefix("ws://")
                                        .trimEnd('/'),
                                    color = PrimaryText,
                                    fontSize = 13.sp,
                                    modifier = Modifier.weight(1f),
                                )
                                Text(
                                    text = FeedRelayHealth.label(state),
                                    color = stateColor.copy(alpha = 0.8f),
                                    fontSize = 11.sp,
                                    fontWeight = FontWeight.Medium,
                                    fontFamily = FontFamily.Monospace,
                                )
                            }
                            if (index < feedRelays.size - 1) {
                                HorizontalDivider(
                                    color = TertiaryText.copy(alpha = 0.15f),
                                    modifier = Modifier.padding(vertical = 2.dp),
                                )
                            }
                        }
                    }

                    Spacer(Modifier.height(12.dp))

                    OutlinedButton(
                        onClick = onManageRelays,
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Text("Manage Relays", color = colors.primary, fontSize = 13.sp)
                    }
                }
            }

            Spacer(Modifier.height(24.dp))

            // ── Actions ──────────────────────────────────────────

            Text(
                text = "Actions",
                color = SecondaryText,
                fontSize = 13.sp,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.padding(bottom = 8.dp),
            )

            Row(
                horizontalArrangement = Arrangement.spacedBy(10.dp),
                modifier = Modifier.fillMaxWidth(),
            ) {
                ActionButton(
                    icon = NostrVaultIcons.Refresh,
                    title = "Refresh",
                    isLoading = isLoadingFeed,
                    modifier = Modifier.weight(1f),
                    onClick = { feedService.refresh() },
                )
                // Drops the in-memory feed and refetches; forceReload refreshes itself.
                ActionButton(
                    icon = NostrVaultIcons.History,
                    title = "Reload",
                    modifier = Modifier.weight(1f),
                    onClick = { feedService.forceReload() },
                )
                ActionButton(
                    icon = NostrVaultIcons.Received,
                    title = "Load $pendingCount",
                    enabled = pendingCount > 0,
                    modifier = Modifier.weight(1f),
                    onClick = { feedService.applyPendingNotes() },
                )
            }
        }
    }
}

/** One Noise Filtering figure: icon, a monospaced value, and its caption. */
@Composable
private fun NoiseStat(icon: ImageVector, tint: Color, value: String, label: String) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            tint = tint,
            modifier = Modifier.size(16.dp),
        )
        Spacer(Modifier.width(8.dp))
        Column {
            Text(
                text = value,
                color = PrimaryText,
                fontSize = 16.sp,
                fontWeight = FontWeight.Bold,
                fontFamily = FontFamily.Monospace,
            )
            Text(text = label, color = SecondaryText, fontSize = 10.sp)
        }
    }
}

@Composable
private fun ToggleRow(
    label: String,
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    checked: Boolean,
    onToggle: (Boolean) -> Unit,
) {
    val colors = LocalNostrVaultColors.current

    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 4.dp),
    ) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            tint = if (checked) colors.primary else TertiaryText,
            modifier = Modifier.size(20.dp),
        )
        Spacer(Modifier.width(12.dp))
        Text(
            text = label,
            color = PrimaryText,
            fontSize = 14.sp,
            modifier = Modifier.weight(1f),
        )
        Switch(
            checked = checked,
            onCheckedChange = onToggle,
            colors = SwitchDefaults.colors(
                checkedThumbColor = colors.primary,
                checkedTrackColor = colors.primary.copy(alpha = 0.3f),
            ),
        )
    }
}
