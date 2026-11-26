package com.nostrvault.ui.components

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.data.model.GlobeSphereField
import com.nostrvault.data.model.TrustMap
import com.nostrvault.data.model.TrustMapOuter
import kotlinx.coroutines.launch
import kotlin.math.roundToInt

/** Sphere faces are laid out at this size and scaled to each one. */
private const val SPHERE_PICTURE_DP = 48f

/**
 * A picked hop's sphere ([GlobeHopSphere]) over the nested inner globe: its
 * dots on one canvas, and the faces it seats as pictures on top. Only the
 * people facing you or coming round ([GlobeHopSphere.windowIfChanged]) whose
 * picture is in get a picture view, so it never fills with lettered
 * stand-ins and never holds the whole top 300. iOS `TrustGlobeCanvas.drawScene`.
 */
@Composable
internal fun GlobeHopSphereLayer(
    scene: GlobeScene,
    outer: TrustMapOuter,
    layer: TrustMap.Layer,
    phone: Boolean,
    lite: Boolean,
    profiles: Map<String, FeedProfile>,
    focus: String?,
    onNeedProfiles: (List<String>) -> Unit,
) {
    var window by remember { mutableStateOf(emptyList<String>()) }
    val scope = rememberCoroutineScope()
    val currentProfiles by rememberUpdatedState(profiles)
    val ring = layer.hop?.let { hop -> outer.rings.firstOrNull { it.hop == hop } }

    // The picked sphere shows faces only for people whose picture is in: ask for its best people's profiles.
    LaunchedEffect(ring) {
        val keys = ring?.let(GlobeHopSphere::pictureKeys) ?: return@LaunchedEffect
        val missing = keys.filter { currentProfiles[it] == null }
        if (missing.isNotEmpty()) onNeedProfiles(missing)
    }
    val faces = if (layer.hop == null) emptyList() else window.filter { profiles[it]?.pictureURL != null }
    val pictures = remember(faces) { faces.toHashSet() }

    fun Density.prepare(w: Float, h: Float) {
        val level = scene.ringZoom
        val pole = GlobeSphereField.pole(scene.center)
        val zoom = scene.camera.zoom
        val (spheres, hole) = GlobeOuterRings.spheres(outer, w.toDouble(), h.toDouble(), zoom, phone, level)
        if (spheres.isEmpty()) {
            GlobeHopSphere.prepare(listOf(scene.frame, w, h, 0), emptyList(), DoubleArray(9), pole, emptySet(), null, null, density, lite)
            return
        }
        GlobeHopSphere.prepare(
            listOf(scene.frame, w, h, pictures, focus, outer, level, zoom),
            spheres, scene.camera.orientation.matrix(), pole, pictures, focus, hole, density, lite,
        )
    }

    Canvas(Modifier.fillMaxSize()) {
        prepare(size.width, size.height)
        GlobeHopSphere.draw(this)
        GlobeHopSphere.windowIfChanged(nowSeconds())?.let { next ->
            // Not from inside the draw: the pictures recompose on the next turn.
            scope.launch { window = next }
        }
    }
    Layout(
        content = {
            for (key in faces) {
                androidx.compose.runtime.key(key) {
                    val profile = profiles[key]
                    AvatarImage(
                        url = profile?.pictureURL,
                        pubkey = key,
                        size = SPHERE_PICTURE_DP.dp,
                        displayName = profile?.bestName,
                        modifier = Modifier.border(3.dp, RingColor, CircleShape),
                    )
                }
            }
        },
        modifier = Modifier.fillMaxSize(),
    ) { measurables, constraints ->
        val placeables = measurables.map { it.measure(Constraints()) }
        layout(constraints.maxWidth, constraints.maxHeight) {
            prepare(constraints.maxWidth.toFloat(), constraints.maxHeight.toFloat())
            placeables.forEachIndexed { i, placeable ->
                val face = faces.getOrNull(i)?.let(GlobeHopSphere::face)
                val half = placeable.width / 2f
                if (face == null) {
                    placeable.placeWithLayer(0, 0) { alpha = 0f }
                } else {
                    val s = (face.r / half).toFloat()
                    placeable.placeWithLayer((face.x - half).roundToInt(), (face.y - placeable.height / 2f).roundToInt()) {
                        scaleX = s
                        scaleY = s
                        alpha = face.alpha.toFloat()
                    }
                }
            }
        }
    }
}
