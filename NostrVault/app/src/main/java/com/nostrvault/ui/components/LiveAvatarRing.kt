package com.nostrvault.ui.components

import androidx.compose.foundation.clickable
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.nostrvault.service.LiveStatusService
import dagger.hilt.EntryPoint
import dagger.hilt.InstallIn
import dagger.hilt.android.EntryPointAccessors
import dagger.hilt.components.SingletonComponent

@EntryPoint
@InstallIn(SingletonComponent::class)
interface LiveAvatarRingEntryPoint {
    fun liveStatusService(): LiveStatusService
}

/**
 * A red ring on the profile picture of someone who is live right now, and a
 * tap on it that opens their stream instead of whatever the avatar's row does.
 * Off the air, the avatar is left exactly as it was: no ring, no tap.
 * iOS: LiveAvatarRing.
 *
 * Applied inside [AvatarImage] after the caller's modifier, so its click is
 * the inner one and wins over a row's or [AvatarWithMenu]'s.
 */
@Composable
fun Modifier.liveAvatarRing(pubkey: String, size: Dp): Modifier {
    val context = LocalContext.current
    val live = remember(context) {
        EntryPointAccessors.fromApplication(context.applicationContext, LiveAvatarRingEntryPoint::class.java)
            .liveStatusService()
    }
    LaunchedEffect(pubkey) { live.watch(pubkey) }
    val hosts by live.liveHosts.collectAsState()
    if (pubkey !in hosts) return this

    // While a player is up, the host's avatar there still shows the ring, but
    // a tap must not swap or stack another stream over the one playing.
    val playing by LiveStreamRouter.playing.collectAsState()
    val width = maxOf(1.5.dp, size * 0.06f)
    return this
        .drawWithContent {
            drawContent()
            val stroke = width.toPx()
            drawCircle(
                color = Color.Red,
                radius = (this.size.minDimension - stroke) / 2,
                center = Offset(this.size.width / 2, this.size.height / 2),
                style = Stroke(stroke),
            )
        }
        .then(
            if (playing == null) {
                Modifier.clickable(role = Role.Button, onClickLabel = "Live now. Open their stream") {
                    live.stream(hostedBy = pubkey)?.let { LiveStreamRouter.open(it) }
                }
            } else {
                Modifier
            },
        )
}
