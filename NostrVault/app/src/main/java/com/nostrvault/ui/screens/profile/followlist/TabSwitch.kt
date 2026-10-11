package com.nostrvault.ui.screens.profile

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.Surface1
import com.nostrvault.ui.theme.Surface2

/** Two-segment switch, iOS segmented-control style. */
@Composable
internal fun TabSwitch(
    tab: FollowListTab,
    followingLabel: String,
    followersLabel: String,
    onSelect: (FollowListTab) -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .height(40.dp)
            .clip(RoundedCornerShape(10.dp))
            .background(Surface1)
            .padding(3.dp),
    ) {
        for ((option, label) in listOf(FollowListTab.FOLLOWING to followingLabel, FollowListTab.FOLLOWERS to followersLabel)) {
            val selected = option == tab
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier
                    .weight(1f)
                    .fillMaxSize()
                    .clip(RoundedCornerShape(8.dp))
                    .background(if (selected) Surface2 else Color.Transparent)
                    .clickable(role = Role.Tab) { onSelect(option) },
            ) {
                Text(
                    label,
                    color = PrimaryText,
                    fontSize = 13.sp,
                    fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
                    maxLines = 1,
                )
            }
        }
    }
}
