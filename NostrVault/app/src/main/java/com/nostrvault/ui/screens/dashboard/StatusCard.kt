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
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.MoreHoriz
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.tutorials.TutorialContent
import com.nostrvault.tutorials.tutorialAnchor
import com.nostrvault.ui.screens.dashboard.VaultDashboardModel.RunState
import com.nostrvault.ui.theme.CardBorder
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

// ═══════════════════════════════════════════════════════════════════
// Status card
// ═══════════════════════════════════════════════════════════════════

@Composable
internal fun StatusCard(
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
