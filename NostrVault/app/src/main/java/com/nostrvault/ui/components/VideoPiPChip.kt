package com.nostrvault.ui.components

import android.content.pm.PackageManager
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.nostrvault.ui.theme.NostrVaultIcons

/**
 * A feed video's PiP button, on the playing inline video and on a video's
 * poster alike: it opens the viewer, which goes straight into picture-in-
 * picture ([VideoPiPBridge.requestPiPOnOpen]). Nothing where the device has
 * no PiP. PiP plan lane C.
 */
@Composable
fun VideoPiPChip(onOpenViewer: () -> Unit, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val supportsPiP = remember { context.packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE) }
    if (!supportsPiP) return
    Box(
        contentAlignment = Alignment.Center,
        modifier = modifier
            .size(30.dp)
            .clip(CircleShape)
            .background(Color.Black.copy(alpha = 0.6f))
            .clickable(onClickLabel = "Picture in picture") {
                VideoPiPBridge.requestPiPOnOpen()
                onOpenViewer()
            },
    ) {
        Icon(
            imageVector = NostrVaultIcons.PictureInPicture,
            contentDescription = "Picture in picture",
            tint = Color.White,
            modifier = Modifier.size(15.dp),
        )
    }
}
