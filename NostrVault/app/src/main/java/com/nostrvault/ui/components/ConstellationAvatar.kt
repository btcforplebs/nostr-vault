package com.nostrvault.ui.components

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RadialGradient
import android.graphics.Shader
import android.util.LruCache
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Dp

/**
 * [Constellation] drawn into a bitmap [px] square, made once per pubkey and size. Draw order (spec "Drawing"): sky,
 * clouds, dust, links, glow, stars, all clipped to the circle. Nothing is fetched.
 */
object ConstellationBitmaps {
    private val cache = LruCache<String, ImageBitmap>(300)

    fun get(hex: String, px: Int): ImageBitmap {
        val key = "$hex:$px"
        cache.get(key)?.let { return it }
        return render(Constellation.of(hex), px).asImageBitmap().also { cache.put(key, it) }
    }

    private fun argb(rgb: Int, alpha: Double): Int = ((alpha * 255 + 0.5).toInt().coerceIn(0, 255) shl 24) or rgb

    fun render(c: Constellation.Sky, px: Int): Bitmap {
        val bmp = Bitmap.createBitmap(px, px, Bitmap.Config.ARGB_8888)
        val cv = Canvas(bmp)
        cv.scale(px / 100f, px / 100f)
        cv.clipPath(Path().apply { addCircle(50f, 50f, 50f, Path.Direction.CW) })
        val fill = Paint(Paint.ANTI_ALIAS_FLAG)
        // 1. Sky
        fill.shader = RadialGradient(38f, 32f, 78f, argb(c.skyInner, 1.0), argb(c.skyOuter, 1.0), Shader.TileMode.CLAMP)
        cv.drawRect(0f, 0f, 100f, 100f, fill)
        // 2. Clouds: one colour from its opacity to 0
        for (k in c.clouds) {
            fill.shader = RadialGradient(k.x.toFloat(), k.y.toFloat(), k.radius.toFloat(), argb(k.color, k.alpha), argb(k.color, 0.0), Shader.TileMode.CLAMP)
            cv.drawRect(0f, 0f, 100f, 100f, fill)
        }
        fill.shader = null
        // 3. Dust
        fill.color = argb(0xffffff, 0.45)
        for (d in c.dust) cv.drawCircle(d.x.toFloat(), d.y.toFloat(), d.r.toFloat(), fill)
        // 4. Links
        val line = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeWidth = 2.2f
            strokeCap = Paint.Cap.ROUND
            color = argb(c.line, 0.55)
        }
        for ((i, j) in c.links) {
            val a = c.stars[i]; val b = c.stars[j]
            cv.drawLine(a.x.toFloat(), a.y.toFloat(), b.x.toFloat(), b.y.toFloat(), line)
        }
        if (c.stars.isEmpty()) return bmp
        // 5. Glow around the bright star
        val you = c.stars[c.you]
        fill.shader = RadialGradient(you.x.toFloat(), you.y.toFloat(), 14f, argb(c.glow, 0.9), argb(c.glow, 0.0), Shader.TileMode.CLAMP)
        cv.drawCircle(you.x.toFloat(), you.y.toFloat(), 14f, fill)
        fill.shader = null
        // 6. Stars
        fill.color = argb(c.star, 1.0)
        c.stars.forEachIndexed { i, s -> cv.drawCircle(s.x.toFloat(), s.y.toFloat(), if (i == c.you) 5.2f else s.r.toFloat(), fill) }
        return bmp
    }
}

/** The constellation face for [pubkey] (64 lowercase hex), [size] square. Callers clip it to a circle. */
@Composable
fun ConstellationAvatar(pubkey: String, size: Dp, modifier: Modifier = Modifier) {
    val px = with(LocalDensity.current) { size.roundToPx() }.coerceAtLeast(1)
    val bitmap = remember(pubkey, px) { ConstellationBitmaps.get(pubkey, px) }
    Image(bitmap = bitmap, contentDescription = null, modifier = modifier.size(size))
}
