package com.nostrvault.ui.components

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.Motion
import com.nostrvault.ui.theme.NostrVaultIcons
import com.nostrvault.ui.theme.PrimaryText

/**
 * The feed's purple "New Posts" pill, for a rebuild running ([caption]) and
 * how it ended. Nothing when no rebuild is running.
 */
@Composable
internal fun WotLivePill(caption: String?, outcome: WotPillOutcome? = null) {
    val accent = LocalNostrVaultColors.current.primary
    val shape = RoundedCornerShape(50)
    AnimatedVisibility(
        visible = caption != null,
        enter = fadeIn(Motion.chrome()),
        exit = fadeOut(Motion.chrome()),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .shadow(8.dp, shape, ambientColor = Color.Black.copy(alpha = 0.4f), spotColor = Color.Black.copy(alpha = 0.4f))
                .clip(shape)
                .background(accent)
                .padding(vertical = 10.dp, horizontal = 20.dp)
                .semantics(mergeDescendants = true) { liveRegion = LiveRegionMode.Polite },
        ) {
            if (outcome != null) {
                // How the Rebuild button's run ended.
                Icon(
                    if (outcome == WotPillOutcome.Failed) NostrVaultIcons.ErrorCircle else NostrVaultIcons.CheckCircle,
                    contentDescription = null, tint = PrimaryText, modifier = Modifier.size(13.dp),
                )
                Spacer(Modifier.width(8.dp))
                Text(caption.orEmpty(), color = PrimaryText, fontSize = 13.sp, fontWeight = FontWeight.Bold,
                    maxLines = 2, textAlign = TextAlign.Center, modifier = Modifier.widthIn(max = 300.dp))
            } else {
                CircularProgressIndicator(color = PrimaryText, strokeWidth = 1.5.dp, modifier = Modifier.size(12.dp))
                Spacer(Modifier.width(8.dp))
                Text(caption.orEmpty(), color = PrimaryText, fontSize = 13.sp, fontWeight = FontWeight.Bold,
                    maxLines = 2, textAlign = TextAlign.Center, modifier = Modifier.widthIn(max = 300.dp))
            }
        }
    }
}

/** How a finished Rebuild ended, as [WotLivePill] marks it. */
internal enum class WotPillOutcome { Saved, Failed }
