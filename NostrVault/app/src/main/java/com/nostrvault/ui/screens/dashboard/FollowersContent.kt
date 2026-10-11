package com.nostrvault.ui.screens.dashboard

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.data.model.*
import com.nostrvault.relay.RelayForegroundService
import com.nostrvault.ui.components.AvatarImage
import com.nostrvault.ui.components.formatTimestamp
import com.nostrvault.ui.theme.*
import kotlinx.coroutines.*
import kotlinx.serialization.json.*

// ═══════════════════════════════════════════════════════════════════
// Followers content (relay follower ledger, iOS #136)
// ═══════════════════════════════════════════════════════════════════

@Composable
internal fun FollowersContent(
    snapshot: FollowerSnapshot?,
    filter: VaultFollowersFilter,
    listState: androidx.compose.foundation.lazy.LazyListState,
    allProfiles: Map<String, FeedProfile>,
    padding: PaddingValues,
    onProfileClick: (String) -> Unit,
) {
    val colors = LocalNostrVaultColors.current
    if (snapshot == null) {
        val relayStatus by RelayForegroundService.relayStatus.collectAsState()
        val running = relayStatus == RelayForegroundService.RelayStatus.RUNNING
        Box(
            contentAlignment = Alignment.Center,
            modifier = Modifier
                .fillMaxSize()
                .padding(top = padding.calculateTopPadding()),
        ) {
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                CircularProgressIndicator(color = colors.primary, modifier = Modifier.size(32.dp))
                Spacer(Modifier.height(16.dp))
                Text(
                    text = if (running) "Loading followers..." else "Followers show once the relay is running",
                    color = SecondaryText,
                    fontSize = 15.sp,
                    fontWeight = FontWeight.SemiBold,
                )
            }
        }
        return
    }
    val entries = remember(snapshot, filter) { snapshot.entries(filter) }
    LazyColumn(
        state = listState,
        contentPadding = PaddingValues(
            top = padding.calculateTopPadding(),
            bottom = padding.calculateBottomPadding() + 88.dp,
        ),
        modifier = Modifier.fillMaxSize(),
    ) {
        item(key = "followers-summary") {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.padding(start = 16.dp, end = 16.dp, top = 4.dp, bottom = 12.dp),
            ) {
                Icon(
                    imageVector = NostrVaultIcons.People,
                    contentDescription = null,
                    tint = colors.primary,
                    modifier = Modifier.size(18.dp),
                )
                Spacer(Modifier.width(6.dp))
                Text(
                    text = "${snapshot.counts.total} followers",
                    color = PrimaryText,
                    fontSize = 15.sp,
                    fontWeight = FontWeight.Bold,
                )
            }
        }
        if (entries.isEmpty()) {
            item(key = "followers-empty") {
                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    modifier = Modifier.fillMaxWidth().padding(top = 60.dp),
                ) {
                    Icon(
                        imageVector = NostrVaultIcons.PeopleOutline,
                        contentDescription = null,
                        tint = colors.primary,
                        modifier = Modifier.size(40.dp),
                    )
                    Spacer(Modifier.height(8.dp))
                    Text(
                        text = "No followers here yet",
                        color = PrimaryText,
                        fontSize = 17.sp,
                        fontWeight = FontWeight.Bold,
                    )
                }
            }
        } else {
            items(entries, key = { it.pubkey }) { entry ->
                FollowerRow(
                    entry = entry,
                    profile = allProfiles[entry.pubkey],
                    onClick = { onProfileClick(entry.pubkey) },
                )
                HorizontalDivider(color = SeparatorColor, thickness = 0.5.dp)
            }
        }
    }
}

@Composable
private fun FollowerRow(
    entry: FollowerSnapshot.Entry,
    profile: FeedProfile?,
    onClick: () -> Unit,
) {
    val colors = LocalNostrVaultColors.current
    val name = profile?.bestName
        ?: remember(entry.pubkey) {
            (com.nostrvault.relay.HavenBridge.encodeNpub(entry.pubkey) ?: entry.pubkey).take(16) + "…"
        }
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 10.dp),
    ) {
        AvatarImage(
            url = profile?.pictureURL,
            pubkey = entry.pubkey,
            size = 40.dp,
            displayName = profile?.bestName,
        )
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text(
                text = name,
                color = PrimaryText,
                fontSize = 15.sp,
                fontWeight = FontWeight.SemiBold,
                maxLines = 1,
                overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis,
            )
            profile?.nip05?.takeIf { it.isNotBlank() }?.let { nip05 ->
                Text(
                    text = nip05,
                    color = SecondaryText,
                    fontSize = 12.sp,
                    fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace,
                    maxLines = 1,
                    overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis,
                )
            }
        }
        if (entry.isNews) {
            Spacer(Modifier.width(8.dp))
            val tagColor = if (entry.isReturning) ZapOrange else colors.primary
            Text(
                text = if (entry.isReturning) "Returning" else "New",
                color = tagColor,
                fontSize = 11.sp,
                fontWeight = FontWeight.Bold,
                modifier = Modifier
                    .background(tagColor.copy(alpha = 0.16f), CircleShape)
                    .padding(horizontal = 8.dp, vertical = 3.dp),
            )
            Spacer(Modifier.width(8.dp))
            Text(
                text = formatTimestamp(entry.followedAt),
                color = SecondaryText,
                fontSize = 12.sp,
            )
        }
    }
}
