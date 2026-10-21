package com.nostrvault.ui.screens.dashboard

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material3.Icon
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
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import com.nostrvault.relay.RelayForegroundService
import com.nostrvault.ui.theme.NostrVaultIcons
import com.nostrvault.ui.theme.SecondaryText
import com.nostrvault.ui.theme.SuccessGreen
import kotlinx.coroutines.delay

/**
 * Advanced › Relay details: where the vault is, its address, port and how
 * long it has run (iOS RelayDetailsPage). What it holds is on the dashboard,
 * under In your vault.
 */
@Composable
internal fun RelayDetailsPage(
    onBack: () -> Unit,
    viewModel: VaultDashboardViewModel = hiltViewModel(),
) {
    val cfg by viewModel.configStore.config.collectAsState()
    val relayStatus by RelayForegroundService.relayStatus.collectAsState()
    val startedAt by viewModel.relayStartedAt.collectAsState()
    val clipboard = LocalClipboardManager.current
    var copied by remember { mutableStateOf(false) }
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(Unit) {
        while (true) {
            delay(30_000)
            now = System.currentTimeMillis()
        }
    }
    LaunchedEffect(copied) {
        if (copied) {
            delay(1_600)
            copied = false
        }
    }

    val address = cfg.nostrURL.orEmpty()
    val runningFor = when (relayStatus) {
        RelayForegroundService.RelayStatus.RUNNING ->
            VaultDashboardModel.uptime(startedAt, now)?.removePrefix("Up ") ?: "Running"
        RelayForegroundService.RelayStatus.BOOTING -> "Starting…"
        else -> "Not running"
    }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 16.dp)
            .padding(bottom = 32.dp),
    ) {
        SheetPageHeader(title = "Relay details", onBack = onBack)
        DashSection(title = "Your relay") {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(min = 48.dp)
                    .clickable(role = Role.Button, enabled = address.isNotEmpty(), onClickLabel = "Copy the address") {
                        clipboard.setText(AnnotatedString(address))
                        copied = true
                    }
                    .semantics(mergeDescendants = true) { contentDescription = "Address, ${if (copied) "Copied" else address}" }
                    .padding(horizontal = 14.dp, vertical = 8.dp),
            ) {
                RowLabel(NostrVaultIcons.LinkIcon, "Address")
                Text(
                    if (copied) "Copied" else address,
                    color = if (copied) SuccessGreen else SecondaryText,
                    fontSize = 13.sp,
                    fontFamily = if (copied) null else FontFamily.Monospace,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f).padding(start = 8.dp),
                    textAlign = androidx.compose.ui.text.style.TextAlign.End,
                )
                Icon(
                    if (copied) Icons.Filled.Check else Icons.Filled.ContentCopy,
                    contentDescription = null,
                    tint = if (copied) SuccessGreen else SecondaryText.copy(alpha = 0.6f),
                    modifier = Modifier.size(14.dp),
                )
            }
            DashDivider()
            ValueRow(NostrVaultIcons.TagIcon, "Port", "${cfg.relayPort}")
            DashDivider()
            ValueRow(Icons.Filled.Schedule, "Running for", runningFor)
        }
    }
}

@Composable
private fun ValueRow(icon: androidx.compose.ui.graphics.vector.ImageVector, title: String, value: String) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 48.dp)
            .semantics(mergeDescendants = true) {}
            .padding(horizontal = 14.dp, vertical = 8.dp),
    ) {
        RowLabel(icon, title, Modifier.weight(1f))
        Text(value, color = SecondaryText, fontSize = 15.sp, maxLines = 1)
    }
}
