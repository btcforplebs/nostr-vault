package com.nostrvault.ui.components

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.nostrvault.ui.notification.PillIcon
import com.nostrvault.ui.notification.PillSize
import com.nostrvault.ui.notification.PillStyle
import com.nostrvault.ui.notification.PillTone
import com.nostrvault.ui.notification.pillCapsule
import com.nostrvault.ui.notification.rememberHidesAmbient
import com.nostrvault.ui.theme.Motion
import com.nostrvault.ui.theme.NostrVaultIcons

/**
 * The WoT tab's accent pill for a rebuild running ([caption]) and how it
 * ended. Nothing when no rebuild is running. Ambient (docs/pills.md): it
 * hides while the lane shows an error, result or feedback pill.
 */
@Composable
internal fun WotLivePill(caption: String?, outcome: WotPillOutcome? = null) {
    AnimatedVisibility(
        visible = caption != null && !rememberHidesAmbient(),
        enter = fadeIn(Motion.chrome()),
        exit = fadeOut(Motion.chrome()),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .pillCapsule(PillTone.ACCENT)
                .semantics(mergeDescendants = true) { liveRegion = LiveRegionMode.Polite },
        ) {
            if (outcome != null) {
                // How the Rebuild button's run ended.
                PillIcon(if (outcome == WotPillOutcome.Failed) NostrVaultIcons.ErrorCircle else NostrVaultIcons.CheckCircle)
            } else {
                CircularProgressIndicator(color = PillStyle.textColor, strokeWidth = 1.5.dp, modifier = Modifier.size(PillSize.REGULAR.icon))
            }
            Spacer(Modifier.width(PillStyle.innerGap))
            Text(
                caption.orEmpty(),
                color = PillStyle.textColor,
                fontSize = PillSize.REGULAR.font,
                fontWeight = PillSize.REGULAR.weight,
                maxLines = 2,
                textAlign = TextAlign.Center,
                modifier = Modifier.widthIn(max = 300.dp),
            )
        }
    }
}

/** How a finished Rebuild ended, as [WotLivePill] marks it. */
internal enum class WotPillOutcome { Saved, Failed }
