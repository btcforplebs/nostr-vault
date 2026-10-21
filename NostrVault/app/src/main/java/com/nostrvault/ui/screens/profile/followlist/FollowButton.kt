package com.nostrvault.ui.screens.profile

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText

/** Filled "Follow", outlined "Following". Drawn 30dp tall and at least 84 wide, as on iOS; the tap target is 48dp tall. */
@Composable
internal fun FollowButton(state: FollowButtonState, name: String, onClick: () -> Unit) {
    val colors = LocalNostrVaultColors.current
    val filled = when (state) {
        FollowButtonState.Follow -> true
        FollowButtonState.Following -> false
        is FollowButtonState.Pending -> !state.follow
    }
    val pending = state is FollowButtonState.Pending
    Box(
        contentAlignment = Alignment.Center,
        modifier = Modifier
            .heightIn(min = 48.dp)
            // Same wording as iOS: the label names the person so TalkBack and
            // Voice Access can tell rows apart; the action says what a tap does.
            .clickable(role = Role.Button, onClickLabel = if (filled) null else "Unfollow", onClick = onClick)
            .semantics { contentDescription = if (filled) "Follow $name" else "Following $name" },
    ) {
        Box(
            contentAlignment = Alignment.Center,
            modifier = Modifier
                .alpha(if (pending) 0.6f else 1f)
                .height(30.dp)
                .widthIn(min = 84.dp)
                .clip(RoundedCornerShape(50))
                .background(if (filled) colors.primary else Color.Transparent)
                .then(
                    if (filled) Modifier
                    else Modifier.border(1.dp, SecondaryText.copy(alpha = 0.45f), RoundedCornerShape(50)),
                )
                .padding(horizontal = 8.dp),
        ) {
            Text(
                if (filled) "Follow" else "Following",
                color = if (filled) Color.White else PrimaryText,
                fontSize = 13.sp,
                fontWeight = FontWeight.SemiBold,
                maxLines = 1,
                modifier = Modifier.clearAndSetSemantics {},
            )
        }
    }
}
