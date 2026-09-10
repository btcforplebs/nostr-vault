package com.nostrvault.ui.screens.dashboard

import android.widget.Toast
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.relay.RelayForegroundService.RelayStatus
import com.nostrvault.ui.theme.*

@Composable
fun RelayStatusHeader(
    relayStatus: RelayStatus,
    relayAddress: String?,
    isLocked: Boolean,
    isPortConflict: Boolean,
    onStartRelay: () -> Unit,
    onStopRelay: () -> Unit,
    onRestartRelay: () -> Unit,
    onForceRestart: () -> Unit,
    onClearLocks: () -> Unit,
) {
    val colors = LocalNostrVaultColors.current
    val clipboard = LocalClipboardManager.current
    val context = LocalContext.current

    val statusColor = when (relayStatus) {
        RelayStatus.RUNNING -> SuccessGreen
        RelayStatus.BOOTING, RelayStatus.IMPORTING -> WarningYellow
        RelayStatus.OFFLINE -> ErrorRed
    }

    val statusText = when (relayStatus) {
        RelayStatus.RUNNING -> "ONLINE"
        RelayStatus.BOOTING -> "BOOTING..."
        RelayStatus.IMPORTING -> "IMPORTING..."
        RelayStatus.OFFLINE -> "OFFLINE"
    }

    val isTransitioning = relayStatus == RelayStatus.BOOTING || relayStatus == RelayStatus.IMPORTING

    Column(modifier = Modifier.fillMaxWidth()) {
        // Status row
        Surface(
            color = SecondaryGroupedBg,
            shape = RoundedCornerShape(12.dp),
            modifier = Modifier.fillMaxWidth(),
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.padding(16.dp),
            ) {
                // Pulsing status dot. The pulse was 800ms here against the iOS
                // ambientPulse's 1600ms — twice as fast for the same "relay is
                // transitioning" signal — so it now takes the shared token.
                // Under Reduce Motion that token is null and the dot holds at
                // full opacity: still visibly the transitioning colour, just
                // not moving. Holding at the 0.3 target instead would read as a
                // dimmed, half-broken dot.
                val pulseSpec = if (isTransitioning) Motion.ambientPulse else null
                val dotAlpha = if (pulseSpec == null) {
                    1f
                } else {
                    val infiniteTransition = rememberInfiniteTransition(label = "pulse")
                    val animated by infiniteTransition.animateFloat(
                        initialValue = 1f,
                        targetValue = 0.3f,
                        animationSpec = pulseSpec,
                        label = "pulseAlpha",
                    )
                    animated
                }
                Box(
                    modifier = Modifier
                        .size(10.dp)
                        .alpha(dotAlpha)
                        .background(statusColor, CircleShape),
                )

                Spacer(Modifier.width(12.dp))

                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = "Relay Status",
                        color = SecondaryText,
                        fontSize = 12.sp,
                    )
                    Text(
                        text = statusText,
                        color = statusColor,
                        fontSize = 16.sp,
                        fontWeight = FontWeight.Bold,
                        fontFamily = FontFamily.Monospace,
                    )

                    // The single most useful thing on a screen named after the
                    // relay: where it actually is. Was nowhere on this screen.
                    if (relayAddress != null) {
                        // The row, not the glyph run, is the tap target: a 12sp
                        // line is ~16dp tall, a third of the 48dp minimum.
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(6.dp),
                            modifier = Modifier
                                .heightIn(min = 48.dp)
                                .clickable {
                                    clipboard.setText(AnnotatedString(relayAddress))
                                    Toast.makeText(context, "Address copied", Toast.LENGTH_SHORT).show()
                                }
                                .semantics { contentDescription = "Relay address: $relayAddress. Tap to copy." },
                        ) {
                            Text(
                                text = relayAddress,
                                color = SecondaryText,
                                fontSize = 12.sp,
                                fontFamily = FontFamily.Monospace,
                            )
                            // Without a glyph, tap-to-copy is undiscoverable —
                            // the text is styled exactly like the label above it.
                            Icon(
                                NostrVaultIcons.Copy,
                                contentDescription = null,
                                tint = SecondaryText,
                                modifier = Modifier.size(14.dp),
                            )
                        }
                    }
                }

                // Control button
                when (relayStatus) {
                    RelayStatus.OFFLINE -> {
                        Button(
                            onClick = onStartRelay,
                            colors = ButtonDefaults.buttonColors(
                                containerColor = colors.primary,
                            ),
                            contentPadding = PaddingValues(horizontal = 16.dp, vertical = 8.dp),
                        ) {
                            Icon(
                                NostrVaultIcons.PlayArrow,
                                contentDescription = null,
                                modifier = Modifier.size(16.dp),
                            )
                            Spacer(Modifier.width(4.dp))
                            Text("Start", fontSize = 13.sp)
                        }
                    }
                    RelayStatus.RUNNING -> {
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            // Stop was already reachable from Advanced Settings and
                            // the persistent notification, just not from the screen
                            // named after the relay.
                            OutlinedButton(
                                onClick = onStopRelay,
                                contentPadding = PaddingValues(horizontal = 16.dp, vertical = 8.dp),
                            ) {
                                Icon(
                                    NostrVaultIcons.Stop,
                                    contentDescription = null,
                                    tint = SecondaryText,
                                    modifier = Modifier.size(16.dp),
                                )
                                Spacer(Modifier.width(4.dp))
                                Text("Stop", fontSize = 13.sp, color = SecondaryText)
                            }
                            OutlinedButton(
                                onClick = onRestartRelay,
                                contentPadding = PaddingValues(horizontal = 16.dp, vertical = 8.dp),
                            ) {
                                Icon(
                                    NostrVaultIcons.Refresh,
                                    contentDescription = null,
                                    tint = colors.primary,
                                    modifier = Modifier.size(16.dp),
                                )
                                Spacer(Modifier.width(4.dp))
                                Text("Restart", fontSize = 13.sp, color = colors.primary)
                            }
                        }
                    }
                    RelayStatus.BOOTING, RelayStatus.IMPORTING -> {
                        CircularProgressIndicator(
                            color = colors.primary,
                            strokeWidth = 2.dp,
                            modifier = Modifier.size(24.dp),
                        )
                    }
                }
            }
        }

        // Error recovery banner
        if (isLocked || isPortConflict) {
            Spacer(Modifier.height(8.dp))

            Surface(
                color = ErrorRed.copy(alpha = 0.15f),
                shape = RoundedCornerShape(12.dp),
                modifier = Modifier.fillMaxWidth(),
            ) {
                Column(modifier = Modifier.padding(16.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(
                            NostrVaultIcons.Alert,
                            contentDescription = null,
                            tint = ErrorRed,
                            modifier = Modifier.size(18.dp),
                        )
                        Spacer(Modifier.width(8.dp))
                        Text(
                            text = if (isPortConflict) {
                                "Port is already in use by another process."
                            } else {
                                "Database lock detected. The relay may have crashed."
                            },
                            color = PrimaryText,
                            fontSize = 13.sp,
                            modifier = Modifier.weight(1f),
                        )
                    }

                    Spacer(Modifier.height(12.dp))

                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Button(
                            onClick = onForceRestart,
                            colors = ButtonDefaults.buttonColors(containerColor = ErrorRed),
                            contentPadding = PaddingValues(horizontal = 12.dp, vertical = 6.dp),
                            modifier = Modifier.weight(1f),
                        ) {
                            Text("Force Restart", fontSize = 12.sp)
                        }

                        if (isLocked) {
                            OutlinedButton(
                                onClick = onClearLocks,
                                contentPadding = PaddingValues(horizontal = 12.dp, vertical = 6.dp),
                                modifier = Modifier.weight(1f),
                            ) {
                                Text("Clear Locks", fontSize = 12.sp, color = PrimaryText)
                            }
                        }
                    }
                }
            }
        }
    }
}
