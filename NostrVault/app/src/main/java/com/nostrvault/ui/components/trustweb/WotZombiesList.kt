package com.nostrvault.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.BottomSheetDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.data.model.WotZombies
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText
import com.nostrvault.ui.theme.Surface1

/**
 * The quiet follows, longest first (the vault sorts them). Read-only:
 * cleaning up happens on Plebs vs. Zombies, never in this app (Logen
 * 2026-11-01). iOS `WotZombiesList`.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun WotZombiesList(
    zombies: List<WotZombies.Zombie>,
    profiles: Map<String, FeedProfile>,
    name: (String) -> String,
    onSeen: (List<String>) -> Unit,
    onDismiss: () -> Unit,
) {
    LaunchedEffect(zombies) { onSeen(zombies.take(300).map { it.pubkey }) }
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = Surface1,
        dragHandle = { BottomSheetDefaults.DragHandle(color = SecondaryText) },
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(start = 20.dp, end = 8.dp)) {
            Text("Zombies", color = PrimaryText, fontSize = 17.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
            TextButton(onClick = onDismiss) { Text("Done", color = LocalNostrVaultColors.current.primary) }
        }
        LazyColumn(Modifier.fillMaxWidth().weight(1f, fill = false)) {
            item { ListHeader(WotZombies.listHeader(zombies.size)) }
            items(zombies, key = { it.pubkey }) { ZombieRow(it, profiles[it.pubkey], name) }
        }
        PlebsVsZombiesButton(Modifier.padding(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 24.dp))
    }
}

@Composable
private fun ZombieRow(zombie: WotZombies.Zombie, profile: FeedProfile?, name: (String) -> String) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        modifier = Modifier
            .fillMaxWidth()
            .semantics(mergeDescendants = true) {}
            .padding(horizontal = 20.dp, vertical = 8.dp),
    ) {
        AvatarImage(url = profile?.pictureURL, pubkey = zombie.pubkey, size = 40.dp, displayName = profile?.bestName)
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(name(zombie.pubkey), color = PrimaryText, fontSize = 15.sp, fontWeight = FontWeight.SemiBold,
                maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(WotZombies.lastSeenText(zombie.lastSeen), color = SecondaryText, fontSize = 13.sp)
        }
        val color = zombie.bucket.color
        Text(
            zombie.bucket.title,
            color = color,
            fontSize = 12.sp,
            fontWeight = FontWeight.Bold,
            modifier = Modifier
                .background(color.copy(alpha = 0.16f), CircleShape)
                .padding(horizontal = 8.dp, vertical = 3.dp),
        )
    }
}
