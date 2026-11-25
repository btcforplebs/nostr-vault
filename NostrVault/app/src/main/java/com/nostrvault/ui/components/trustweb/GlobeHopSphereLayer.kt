package com.nostrvault.ui.components

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.dp
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.data.model.GlobeChain
import com.nostrvault.data.model.TrustMapOuter
import com.nostrvault.data.model.TrustRankCopy
import dagger.hilt.android.EntryPointAccessors
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import kotlin.math.min
import kotlin.math.roundToInt

/** Pictures are laid out at this size and scaled to each face, as the inner globe's. */
private const val SPHERE_PICTURE_DP = 64f

/** A hop sphere person's path in to you ([GlobeChain]), and when it started drawing in. */
internal class SphereChain(val links: List<GlobeChain.Link>, val born: Double)

/**
 * The picked hop's sphere over the nested inner globe ([GlobeHopSphere]):
 * its dots, the card person's path in to you ([GlobeChainPainter]), then its
 * faces as pictures. Reads the inner globe's frame ([GlobeScene.prepare]) so
 * it redraws with every camera turn. iOS `TrustGlobeCanvas.drawScene`.
 */
@Composable
internal fun GlobeHopSphereLayer(
    sphere: GlobeHopSphere,
    scene: GlobeScene,
    outer: TrustMapOuter,
    center: String,
    phone: Boolean,
    lite: Boolean,
    focus: String?,
    chain: SphereChain?,
    profiles: Map<String, FeedProfile>,
) {
    val hasPicture = { key: String -> profiles[key]?.pictureURL != null }
    // Leaving (no outer rings any more) drops the sphere's frame, so its targets stop catching taps.
    DisposableEffect(sphere) { onDispose { sphere.leave() } }
    fun prep(w: Float, h: Float, density: Float) {
        // Read first: it subscribes this layer to the globe's frame clock.
        scene.prepare(w, h, density)
        sphere.prepare(outer, scene.camera, scene.ringZoom, center, w, h, density, phone, lite, focus, profiles, hasPicture)
    }
    Canvas(Modifier.fillMaxSize()) {
        prep(size.width, size.height, density)
        sphere.draw(this)
        chain?.let { if (it.links.firstOrNull()?.key == focus) drawChain(it, sphere, scene) }
    }
    val keys = sphere.pictures
    Layout(
        content = {
            for (key in keys) {
                androidx.compose.runtime.key(key) {
                    val profile = profiles[key]
                    AvatarImage(
                        url = profile?.pictureURL,
                        pubkey = key,
                        size = SPHERE_PICTURE_DP.dp,
                        displayName = profile?.bestName,
                        modifier = Modifier.border(4.dp, RingColor, CircleShape),
                    )
                }
            }
        },
        modifier = Modifier.fillMaxSize(),
    ) { measurables, constraints ->
        val placeables = measurables.map { it.measure(Constraints()) }
        layout(constraints.maxWidth, constraints.maxHeight) {
            prep(constraints.maxWidth.toFloat(), constraints.maxHeight.toFloat(), density)
            placeables.forEachIndexed { i, placeable ->
                val face = keys.getOrNull(i)?.let(sphere::face)
                val half = placeable.width / 2f
                if (face == null) {
                    placeable.placeWithLayer(0, 0) { alpha = 0f }
                } else {
                    val s = (face.r / half).toFloat()
                    placeable.placeWithLayer(
                        (face.x - half).roundToInt(), (face.y - placeable.height / 2f).roundToInt(),
                        zIndex = face.front.toFloat(),
                    ) {
                        scaleX = s
                        scaleY = s
                        alpha = face.alpha.toFloat()
                    }
                }
            }
        }
    }
}

/** The card's hop-sphere person's path to you, through each link's spot as drawn this frame, ending at the core. */
private fun DrawScope.drawChain(chain: SphereChain, sphere: GlobeHopSphere, scene: GlobeScene) {
    val w = size.width
    val h = size.height
    val points = chain.links.mapNotNullTo(ArrayList()) { link ->
        val hop = link.hop
        if (hop != null && hop >= TrustMapOuter.FIRST_HOP) sphere.screenPoint(link.key, hop)
        else scene.screenPoint(link.key, w, h) ?: sphere.screenPoint(link.key, null)
    }
    points += scene.screenPoint(null, w, h) ?: return
    GlobeChainPainter.draw(this, points, min(1.0, (nowSeconds() - chain.born) / GlobeChainPainter.DRAW_IN))
}

/**
 * Draws a hop sphere person's path in to you ([GlobeChain], Logen 2026-11-25):
 * from their face through each link's spot on its layer (the nested spheres,
 * then the inner globe) to you at the centre. Points are found again every
 * frame, so the line follows the layers as they spin; a link not on screen is
 * skipped and the line runs straight on. It draws in from them toward you,
 * like the inner globe's threads. iOS `Views/TrustWeb/GlobeChainPainter.swift`.
 */
internal object GlobeChainPainter {
    /** How long the line takes to draw in, seconds. */
    const val DRAW_IN = 0.6

    /** [points] run from the tapped person to you, each (x, y, front): a stretch round the back is drawn fainter. */
    fun draw(scope: DrawScope, points: List<Triple<Double, Double, Double>>, progress: Double) = with(scope) {
        if (points.size < 2 || progress <= 0) return@with
        val legs = (points.size - 1).toDouble()
        val glow = Path()
        for (i in 0 until points.size - 1) {
            val share = (progress * legs - i).coerceIn(0.0, 1.0)
            if (share <= 0) break
            val a = points[i]; val b = points[i + 1]
            val start = Offset(a.first.toFloat(), a.second.toFloat())
            val end = Offset((a.first + (b.first - a.first) * share).toFloat(), (a.second + (b.second - a.second) * share).toFloat())
            glow.moveTo(start.x, start.y)
            glow.lineTo(end.x, end.y)
            val front = (a.third + b.third) / 2
            drawLine(ThreadColor.copy(alpha = (0.45 + 0.5 * front).toFloat()), start, end, strokeWidth = 1.4f * density, cap = StrokeCap.Round)
        }
        // A soft wide stroke stands in for iOS's blurred glow.
        drawPath(glow, GlobeAccent.copy(alpha = 0.22f), style = Stroke(width = 6f * density, cap = StrokeCap.Round))
        // A ring round the tapped person, so the line's start is clear even before their face comes round.
        val s = points[0]
        drawCircle(GlobeAccent.copy(alpha = 0.9f), radius = 13f * density, center = Offset(s.first.toFloat(), s.second.toFloat()), style = Stroke(width = 2f * density))
        // A bead on each link reached, so the layers it passes are clear.
        for (i in 1 until points.size - 1) {
            if (i > progress * legs) break
            val p = points[i]
            drawCircle(GlobeAccent.copy(alpha = (0.6 + 0.4 * p.third).toFloat()), radius = 2.6f * density, center = Offset(p.first.toFloat(), p.second.toFloat()))
        }
    }
}

/** The active account's rank copy ([com.nostrvault.service.DiscoveryReachStore]), for a hop sphere person's path. */
@Composable
internal fun rememberRankCopy(): TrustRankCopy? {
    val context = LocalContext.current
    val store = remember(context) {
        EntryPointAccessors.fromApplication(context.applicationContext, GlobeOuterRingsEntryPoint::class.java).discoveryReachStore()
    }
    val copy by store.copy.collectAsState()
    return copy
}
