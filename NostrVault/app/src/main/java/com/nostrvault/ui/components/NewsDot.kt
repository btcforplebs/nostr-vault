package com.nostrvault.ui.components

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.nostrvault.ui.theme.ErrorRed
import com.nostrvault.ui.theme.Motion

/**
 * The one "you have news" dot: a red badge with a thin dark ring that cuts it
 * out of the icon it sits on, and a soft red glow, so it reads as a
 * notification and not as part of the glyph. It springs in when the news
 * arrives and fades out when it's seen. Draws nothing while [isShown] is
 * false, so callers can leave it in place. Port of iOS NewsDot.
 */
@Composable
fun NewsDot(
    isShown: Boolean,
    modifier: Modifier = Modifier,
    /** The red part's diameter. The ring is drawn outside it. */
    size: Dp = 10.dp,
    ring: Dp = 1.5.dp,
) {
    AnimatedVisibility(
        visible = isShown,
        enter = scaleIn(Motion.pop(), initialScale = 0.4f) + fadeIn(Motion.fade()),
        exit = scaleOut(Motion.fade(), targetScale = 0.4f) + fadeOut(Motion.fade()),
        modifier = modifier,
    ) {
        Box(
            Modifier
                .shadow(6.dp, CircleShape, ambientColor = ErrorRed, spotColor = ErrorRed)
                .background(Color.Black.copy(alpha = 0.55f), CircleShape)
                .padding(ring)
                .size(size)
                .background(ErrorRed, CircleShape),
        )
    }
}
