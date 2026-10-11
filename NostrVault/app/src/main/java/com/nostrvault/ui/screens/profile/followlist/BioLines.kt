package com.nostrvault.ui.screens.profile

import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.ui.theme.SecondaryText
import com.nostrvault.ui.theme.Surface1

/** Always two lines tall, so rows keep one height as profiles land. */
@Composable
internal fun BioLines(bio: String?, loading: Boolean) {
    Box {
        // Plain text: links in a bio are not tappable here, so the whole row
        // stays one tap target.
        Text(
            if (loading) " " else bio ?: " ",
            color = SecondaryText,
            fontSize = 13.sp,
            lineHeight = 17.sp,
            minLines = 2,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
        )
        if (loading) {
            val pulse by rememberInfiniteTransition(label = "bio").animateFloat(
                initialValue = 1f,
                targetValue = 0.5f,
                animationSpec = infiniteRepeatable(tween(900), RepeatMode.Reverse),
                label = "bioPulse",
            )
            Column(
                verticalArrangement = Arrangement.SpaceEvenly,
                modifier = Modifier.matchParentSize().alpha(pulse),
            ) {
                Box(Modifier.fillMaxWidth(0.95f).height(10.dp).clip(RoundedCornerShape(4.dp)).background(Surface1))
                Box(Modifier.fillMaxWidth(0.7f).height(10.dp).clip(RoundedCornerShape(4.dp)).background(Surface1))
            }
        }
    }
}
