package com.nostrvault.ui.screens.dashboard

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.data.remote.WebSocketClient
import com.nostrvault.service.FeedRelayHealth
import com.nostrvault.ui.theme.*

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

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        containerColor = WindowBackground,
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
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
                                    fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace,
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
