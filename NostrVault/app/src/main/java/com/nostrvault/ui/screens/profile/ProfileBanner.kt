package com.nostrvault.ui.screens.profile

import android.graphics.Bitmap
import android.graphics.drawable.BitmapDrawable
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.layout
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import coil.compose.AsyncImage
import coil.imageLoader
import coil.request.CachePolicy
import coil.request.ImageRequest
import coil.request.SuccessResult
import com.nostrvault.ui.theme.WindowBackground
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext

/**
 * Sizes and colors of the profile banner (iOS #321), kept apart from the view
 * so they can be tested.
 */
object ProfileBannerStyle {
    /** A profile without a banner gets a short wash instead. */
    const val WASH_HEIGHT_DP = 64f

    /** How far the avatar reaches up over the banner's lower edge. */
    val avatarOverlap: Dp = 36.dp

    /** A banner is about a third as tall as it is wide, within 110–210 dp. */
    fun heightDp(hasBanner: Boolean, widthDp: Float): Float =
        if (!hasBanner) WASH_HEIGHT_DP else (widthDp / 3f).coerceIn(110f, 210f)

    /**
     * A picture's average color is usually a muddy dark gray. Keep its hue but
     * give it enough color and light to read as a tint. Returns HSV (hue in
     * degrees, saturation and value 0–1), or null when the picture has no real
     * color, which takes the app accent instead. Channels are 0–1.
     */
    fun washHsv(r: Float, g: Float, b: Float): FloatArray? {
        val maxC = maxOf(r, g, b)
        val minC = minOf(r, g, b)
        val delta = maxC - minC
        val saturation = if (maxC > 0f) delta / maxC else 0f
        if (saturation <= 0.15f || delta <= 0f) return null
        var hue = when (maxC) {
            r -> ((g - b) / delta) % 6f
            g -> (b - r) / delta + 2f
            else -> (r - g) / delta + 4f
        }
        hue = ((hue / 6f + 1f) % 1f) * 360f
        return floatArrayOf(hue, saturation.coerceIn(0.45f, 0.8f), maxC.coerceIn(0.5f, 0.75f))
    }

    /** The hue for a profile with no picture to take a tint from, stable per pubkey. */
    fun fallbackHue(pubkey: String): Float = ((pubkey.firstOrNull()?.code ?: 200) % 360).toFloat()
}

/**
 * The strip across the top of a profile: edge to edge, reaching up under the
 * toolbar by [topInset] without taking that space in the list, fading into
 * the page at the bottom. Until the banner arrives, or when there is none, a
 * wash tinted from the profile picture stands in, so the header never sits
 * empty. Tapping a loaded banner calls [onTap].
 */
@Composable
internal fun ProfileBanner(
    bannerUrl: String?,
    avatarUrl: String?,
    pubkey: String,
    topInset: Dp,
    accent: Color,
    onTap: (String) -> Unit,
) {
    BoxWithConstraints(Modifier.fillMaxWidth()) {
        val target = ProfileBannerStyle.heightDp(bannerUrl != null, maxWidth.value).dp
        val height by animateDpAsState(target, label = "bannerHeight")
        var loaded by remember(bannerUrl) { mutableStateOf(false) }
        val imageAlpha by animateFloatAsState(if (loaded) 1f else 0f, tween(300), label = "bannerFade")
        val tint = rememberAvatarTint(avatarUrl, accent)
        val base = tint ?: Color.hsv(ProfileBannerStyle.fallbackHue(pubkey), 0.55f, 0.6f)

        Box(
            Modifier
                .fillMaxWidth()
                // Taller than the space it takes: the extra reaches up under
                // the toolbar, where the list's top padding is.
                .layout { measurable, constraints ->
                    val reach = topInset.roundToPx()
                    val own = height.roundToPx()
                    val placeable = measurable.measure(
                        constraints.copy(minHeight = own + reach, maxHeight = own + reach),
                    )
                    layout(placeable.width, own) { placeable.place(0, -reach) }
                }
                .clipToBounds()
                .background(Brush.linearGradient(listOf(base.copy(alpha = 0.9f), base.copy(alpha = 0.35f))))
                .then(
                    if (loaded && bannerUrl != null) {
                        Modifier
                            .semantics { contentDescription = "Profile banner" }
                            .clickable(
                                interactionSource = remember { MutableInteractionSource() },
                                indication = null,
                                role = Role.Image,
                            ) { onTap(bannerUrl) }
                    } else Modifier,
                ),
        ) {
            if (bannerUrl != null) {
                AsyncImage(
                    model = bannerUrl,
                    contentDescription = null,
                    contentScale = ContentScale.Crop,
                    onSuccess = { loaded = true },
                    modifier = Modifier.fillMaxSize().alpha(imageAlpha),
                )
            }
            // Keeps the toolbar buttons legible on a bright banner.
            Box(
                Modifier
                    .fillMaxWidth()
                    .height(topInset + 56.dp)
                    .align(Alignment.TopCenter)
                    .background(Brush.verticalGradient(listOf(Color.Black.copy(alpha = 0.45f), Color.Transparent))),
            )
            Box(
                Modifier
                    .fillMaxWidth()
                    .height(height * 0.45f)
                    .align(Alignment.BottomCenter)
                    .background(Brush.verticalGradient(listOf(Color.Transparent, WindowBackground))),
            )
        }
    }
}

/**
 * The average color of an avatar the app already has on disk, made into a
 * tint; [accent] when the picture has no real color, null until known (or
 * when the avatar isn't cached). Never fetches: the avatar view does that.
 */
@Composable
private fun rememberAvatarTint(avatarUrl: String?, accent: Color): Color? {
    val context = LocalContext.current
    var tint by remember(avatarUrl) { mutableStateOf<Color?>(null) }
    LaunchedEffect(avatarUrl) {
        if (avatarUrl == null) return@LaunchedEffect
        // The avatar may still be downloading on a first visit; look once
        // more after it has had a moment.
        repeat(2) { attempt ->
            if (attempt > 0) delay(1_500)
            val request = ImageRequest.Builder(context)
                .data(avatarUrl)
                .size(16)
                .allowHardware(false)
                .networkCachePolicy(CachePolicy.DISABLED)
                .memoryCachePolicy(CachePolicy.DISABLED)
                .build()
            val bitmap = (context.imageLoader.execute(request) as? SuccessResult)
                ?.let { (it.drawable as? BitmapDrawable)?.bitmap }
            if (bitmap != null) {
                val hsv = withContext(Dispatchers.Default) { averageWashHsv(bitmap) }
                tint = hsv?.let { Color.hsv(it[0], it[1], it[2]) } ?: accent
                return@LaunchedEffect
            }
        }
    }
    return tint
}

private fun averageWashHsv(bitmap: Bitmap): FloatArray? {
    val one = Bitmap.createScaledBitmap(bitmap, 1, 1, true)
    val pixel = one.getPixel(0, 0)
    if (one !== bitmap) one.recycle()
    return ProfileBannerStyle.washHsv(
        ((pixel shr 16) and 0xFF) / 255f,
        ((pixel shr 8) and 0xFF) / 255f,
        (pixel and 0xFF) / 255f,
    )
}
