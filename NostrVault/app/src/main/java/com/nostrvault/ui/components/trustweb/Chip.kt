package com.nostrvault.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText

@Composable
internal fun CrumbArrow() {
    Text("›", color = SecondaryText, fontSize = 13.sp, modifier = Modifier.clearAndSetSemantics { })
}

@Composable
internal fun Chip(
    pubkey: String,
    name: String,
    profile: FeedProfile?,
    on: Boolean,
    destination: Boolean,
    accent: Color,
    onClick: (() -> Unit)?,
    /** Their follows are still on their way: a spinner after the name (iOS). */
    loading: Boolean = false,
) {
    val shape = RoundedCornerShape(50)
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        modifier = Modifier
            .clip(shape)
            .background(if (on) accent.copy(alpha = 0.22f) else Color.White.copy(alpha = 0.08f))
            .then(if (destination) Modifier.border(1.dp, accent.copy(alpha = 0.5f), shape) else Modifier)
            .then(if (onClick != null) Modifier.clickable(role = Role.Button, onClickLabel = "Go back to this step", onClick = onClick) else Modifier)
            .padding(start = 3.dp, end = 10.dp, top = 3.dp, bottom = 3.dp)
            .then(if (destination) Modifier.clearAndSetSemantics { contentDescription = "Looking for $name" } else Modifier),
    ) {
        AvatarImage(url = profile?.pictureURL, pubkey = pubkey, size = 22.dp, displayName = profile?.bestName)
        Text(name, color = if (destination) accent else PrimaryText, fontSize = 13.sp, maxLines = 1)
        if (loading && !destination) {
            CircularProgressIndicator(
                color = Color.White,
                strokeWidth = 1.5.dp,
                modifier = Modifier.size(12.dp).semantics { contentDescription = "Loading $name's follows" },
            )
        }
    }
}

@Composable
internal fun LegendDot(color: Color) {
    Box(Modifier.size(7.dp).clip(CircleShape).background(color).clearAndSetSemantics { })
}
