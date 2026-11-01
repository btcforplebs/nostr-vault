package com.nostrvault.ui.screens.dashboard

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Cached
import androidx.compose.material.icons.filled.MoreHoriz
import androidx.compose.material.icons.filled.PermMedia
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.relay.RelayForegroundService
import com.nostrvault.service.StatsService
import com.nostrvault.ui.theme.ErrorRed
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.NostrVaultIcons
import com.nostrvault.ui.theme.SecondaryGroupedBg
import com.nostrvault.ui.theme.SecondaryText
import java.util.Locale

/**
 * The dashboard's "In your vault": how much room the vault takes, what it
 * holds by kind, its media files and its cache, in one card. Every row with
 * a breakdown opens it in place; nothing leaves the dashboard. Port of iOS
 * `VaultContentsSection`.
 *
 * Replaces the four tiles that closed the dashboard to open other screens,
 * the Storage card and its breakdown sheet, and Advanced › Relay details ›
 * What's stored.
 */
@Composable
internal fun VaultDashboardContentsSection(viewModel: VaultDashboardViewModel) {
    val kindCounts by viewModel.kindCounts.collectAsState()
    val yourKindCounts by viewModel.yourKindCounts.collectAsState()
    val total by viewModel.totalEvents.collectAsState()
    val isCounting by viewModel.isCounting.collectAsState()
    val countFailed by viewModel.countFailed.collectAsState()
    val publicOnly by viewModel.countsPublicOnly.collectAsState()
    val privateMissing by viewModel.privateMissing.collectAsState()
    val media by viewModel.media.collectAsState()
    val cache by viewModel.cache.collectAsState()
    val isClearingCache by viewModel.isClearingCache.collectAsState()
    val relayStatus by RelayForegroundService.relayStatus.collectAsState()
    val relayData by viewModel.statsService.storageSize.collectAsState()
    val blossom by viewModel.statsService.blossomSize.collectAsState()

    var expanded by rememberSaveable { mutableStateOf(setOf<String>()) }
    fun toggle(id: String) { expanded = if (id in expanded) expanded - id else expanded + id }
    var confirmingClear by rememberSaveable { mutableStateOf(false) }

    val counted = kindCounts.isNotEmpty()
    val split = VaultDashboardModel.storageSplit(relayData, blossom, cache?.bytes ?: 0, 0)
    val header = buildString {
        if (counted) append("${count(total)} ${if (total == 1) "event" else "events"} · ")
        append(VaultDashboardModel.size(split.total))
    }

    DashSection(title = "In your vault", detail = header) {
        StorageBar(split = split)
        DashDivider()

        if (counted) {
            VaultDashboardContents.groupRows(total, kindCounts, yourKindCounts).forEachIndexed { i, row ->
                if (i > 0) DashDivider()
                ExpandingRow(
                    icon = groupIcon(row.group.id),
                    title = row.group.title,
                    value = count(row.count),
                    detail = row.yours?.let { "${count(it)} yours" },
                    expanded = row.group.id in expanded,
                    canExpand = row.kinds.size > 1,
                    onToggle = { toggle(row.group.id) },
                ) {
                    row.kinds.forEach { BreakdownLine(it.title, count(it.count)) }
                }
            }
            if (isCounting || countFailed || publicOnly || privateMissing) {
                DashDivider()
                CountStatus(isCounting, countFailed, publicOnly, privateMissing, relayStatus, viewModel::approvePrivateCounts)
            }
        } else {
            CountStatus(isCounting, countFailed, publicOnly, privateMissing, relayStatus, viewModel::approvePrivateCounts)
        }

        DashDivider()
        val m = media
        ExpandingRow(
            icon = Icons.Filled.PermMedia,
            title = "Media files",
            value = m?.let { count(it.count) } ?: "—",
            detail = m?.let { VaultDashboardModel.size(it.size) },
            expanded = "media" in expanded,
            canExpand = (m?.count ?: 0) > 0,
            onToggle = { toggle("media") },
        ) {
            m?.buckets?.filter { it.count > 0 }?.forEach {
                BreakdownLine(it.type.title, "${count(it.count)} · ${VaultDashboardModel.size(it.size)}")
            }
        }

        DashDivider()
        val c = cache
        ExpandingRow(
            icon = Icons.Filled.Cached,
            title = "Cache",
            value = c?.let { VaultDashboardModel.size(it.bytes) } ?: "—",
            detail = "Other people's media, kept for quick loading",
            expanded = "cache" in expanded,
            canExpand = c != null,
            onToggle = { toggle("cache") },
        ) {
            if (c != null) {
                listOf("Images" to c.images, "Videos" to c.videos, "Video thumbnails" to c.thumbnails, "Other" to c.other)
                    .filter { it.second.first > 0 }
                    .forEach { (title, v) -> BreakdownLine(title, "${count(v.first)} · ${VaultDashboardModel.size(v.second)}") }
                Row(Modifier.fillMaxWidth().padding(top = 4.dp)) {
                    Spacer(Modifier.weight(1f))
                    RowButton(
                        title = "Clear cache",
                        isLoading = isClearingCache,
                        enabled = !isClearingCache && !c.isEmpty,
                        onClick = { confirmingClear = true },
                    )
                }
            }
        }
    }

    if (confirmingClear) {
        AlertDialog(
            onDismissRequest = { confirmingClear = false },
            title = { Text("Clear the cache?") },
            text = {
                Text("Removes the copies of other people's images and videos kept for quick loading. Your own media stays. They download again when needed.")
            },
            confirmButton = {
                TextButton(onClick = {
                    confirmingClear = false
                    viewModel.clearCache()
                }) { Text("Clear", color = ErrorRed) }
            },
            dismissButton = { TextButton(onClick = { confirmingClear = false }) { Text("Cancel") } },
            containerColor = SecondaryGroupedBg,
        )
    }
}

/**
 * Counting, the vault is off, the last count did not get every relay's
 * answer, (watch-only) only the public endpoints were counted, or the
 * /private and /chat login wasn't signed: then a tap asks the signer.
 */
@Composable
private fun CountStatus(
    isCounting: Boolean,
    countFailed: Boolean,
    publicOnly: Boolean,
    privateMissing: Boolean,
    relayStatus: RelayForegroundService.RelayStatus,
    onApprove: () -> Unit,
) {
    val canApprove = privateMissing && !isCounting && !countFailed && !publicOnly &&
        relayStatus == RelayForegroundService.RelayStatus.RUNNING
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        modifier = Modifier.fillMaxWidth()
            .then(if (canApprove) Modifier.clickable(onClick = onApprove) else Modifier)
            .padding(horizontal = 14.dp, vertical = 12.dp),
    ) {
        if (isCounting) {
            CircularProgressIndicator(color = LocalNostrVaultColors.current.primary, strokeWidth = 2.dp, modifier = Modifier.size(14.dp))
        }
        Text(
            when {
                isCounting -> "Counting…"
                relayStatus != RelayForegroundService.RelayStatus.RUNNING -> "Start your vault to count what's in it."
                publicOnly && !countFailed -> StatsService.PUBLIC_ONLY_NOTE
                canApprove -> PRIVATE_MISSING_NOTE
                else -> "Couldn't count. Tap refresh to try again."
            },
            color = if (canApprove) LocalNostrVaultColors.current.primary else SecondaryText,
            fontSize = 13.sp,
        )
    }
}

/** Public counts are showing; /private and /chat wait on the signer's approval. */
internal const val PRIVATE_MISSING_NOTE =
    "Private messages and chat aren't counted: your signer didn't approve the login. Tap to approve."

private fun count(n: Int): String = "%,d".format(Locale.getDefault(), n)

private fun groupIcon(id: String): ImageVector = when (id) {
    "notes" -> NostrVaultIcons.Document
    "articles" -> NostrVaultIcons.Articles
    "highlights" -> NostrVaultIcons.Highlights
    "reactions" -> NostrVaultIcons.HeartFilled
    "zaps" -> NostrVaultIcons.Zap
    "messages" -> NostrVaultIcons.DMs
    "profile" -> NostrVaultIcons.Profile
    else -> Icons.Filled.MoreHoriz
}
