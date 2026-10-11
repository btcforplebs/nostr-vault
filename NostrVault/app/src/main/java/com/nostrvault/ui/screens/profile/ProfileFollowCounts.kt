package com.nostrvault.ui.screens.profile

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.ui.semantics.semantics
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.ui.theme.*

/**
 * `1.0k Following  639 Followers`, each opening its list. The Notes and Media
 * counts already sit on their tabs, so only these two are here.
 */
@Composable
internal fun ProfileFollowCounts(
    following: Int?,
    followers: Int?,
    onOpenFollowList: (FollowListTab) -> Unit,
) {
    Row(
        horizontalArrangement = Arrangement.spacedBy(18.dp),
        modifier = Modifier
            .fillMaxWidth()
            .padding(start = 16.dp, end = 16.dp, top = 12.dp),
    ) {
        FollowCount(following?.let(ProfileCountText::short) ?: "—", "Following") {
            onOpenFollowList(FollowListTab.FOLLOWING)
        }
        // Your own comes from the relay's follower ledger, so it is exact.
        FollowCount(followers?.let(ProfileCountText::short) ?: "—", "Followers") {
            onOpenFollowList(FollowListTab.FOLLOWERS)
        }
    }
}

@Composable
private fun FollowCount(value: String, label: String, onClick: () -> Unit) {
    Row(
        verticalAlignment = Alignment.Bottom,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
        modifier = Modifier
            .clip(RoundedCornerShape(4.dp))
            .clickable(role = androidx.compose.ui.semantics.Role.Button, onClick = onClick)
            .semantics(mergeDescendants = true) {},
    ) {
        Text(value, color = PrimaryText, fontSize = 14.sp, fontWeight = FontWeight.Bold, maxLines = 1,
            modifier = Modifier.alignByBaseline())
        Text(label, color = SecondaryText, fontSize = 13.sp, maxLines = 1, modifier = Modifier.alignByBaseline())
    }
}
