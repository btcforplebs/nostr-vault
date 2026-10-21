package com.nostrvault.ui.screens.profile

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.ui.components.AvatarImage
import com.nostrvault.ui.theme.NostrVaultIcons
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText
import kotlinx.coroutines.delay

@Composable
internal fun FollowListRow(
    pubkey: String,
    name: String,
    profile: FeedProfile?,
    followsYou: Boolean,
    /** null hides the button (your own row). */
    followState: FollowButtonState?,
    onOpen: () -> Unit,
    onToggleFollow: () -> Unit,
) {
    // A profile that never arrives stops shimmering after a while.
    var gaveUp by remember(pubkey) { mutableStateOf(false) }
    LaunchedEffect(pubkey, profile == null) {
        if (profile == null) { delay(8_000); gaveUp = true }
    }
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth().padding(start = 16.dp, end = 12.dp, top = 8.dp, bottom = 8.dp),
    ) {
        // The row's tap target. The Follow button is a sibling, not inside it,
        // so it keeps its own tap.
        Row(
            verticalAlignment = Alignment.Top,
            modifier = Modifier.weight(1f).clickable(role = Role.Button, onClick = onOpen),
        ) {
            val url = profile?.pictureURL?.takeIf { it.isNotBlank() }
            if (url != null) {
                AvatarImage(url = url, pubkey = pubkey, size = 44.dp, displayName = profile.bestName)
            } else {
                EmptyAvatar()
            }
            Spacer(Modifier.width(12.dp))
            Column(modifier = Modifier.weight(1f)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        name,
                        color = PrimaryText,
                        fontSize = 15.sp,
                        fontWeight = FontWeight.SemiBold,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f, fill = false),
                    )
                    if (!profile?.nip05.isNullOrBlank()) {
                        Spacer(Modifier.width(5.dp))
                        Icon(NostrVaultIcons.Verified, "Verified", tint = Color(0xFF33CC99), modifier = Modifier.size(11.dp))
                    }
                    if (followsYou) {
                        Spacer(Modifier.width(5.dp))
                        Text(
                            "Follows you",
                            color = SecondaryText,
                            fontSize = 10.sp,
                            fontWeight = FontWeight.SemiBold,
                            maxLines = 1,
                            modifier = Modifier
                                .clip(RoundedCornerShape(50))
                                .background(SecondaryText.copy(alpha = 0.16f))
                                .padding(horizontal = 6.dp, vertical = 2.dp),
                        )
                    }
                }
                Spacer(Modifier.height(3.dp))
                BioLines(
                    bio = FollowListLogic.bioLine(profile?.about),
                    loading = profile == null && !gaveUp,
                )
            }
        }
        if (followState != null) {
            Spacer(Modifier.width(12.dp))
            FollowButton(followState, name, onToggleFollow)
        }
    }
}
