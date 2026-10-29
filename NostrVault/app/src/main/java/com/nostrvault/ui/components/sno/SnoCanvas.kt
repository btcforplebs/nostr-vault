package com.nostrvault.ui.components.sno

import android.graphics.Canvas
import android.graphics.Paint
import android.os.Build
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.nativeCanvas
import com.nostrvault.data.model.SnoObject
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * An SNO object made ready to draw: centred on its bounds, with the edges for
 * `lines` worked out once. Drawing is DECK-0003 §4: both sides of every face
 * (never culled), flat per-face light from each face's own winding with the
 * back a little darker, every edge once, points in every mode, and no vertex
 * moved or invented. Parts (§1.10) are not fetched; each is a one-unit
 * wireframe cube where it would stand, as the spec's placeholder.
 */
internal class SnoScene(val obj: SnoObject) {
    private val cx: Float
    private val cy: Float
    private val cz: Float
    val radius: Float

    /** Each edge once, as vertex index pairs. With no faces, a polyline in vertex order (§1.5). */
    val edges: IntArray

    /** Placeholder cube corners, 8 per part, centred-space x, y, z. */
    val partCorners: FloatArray

    init {
        val p = obj.positions
        val parts = obj.partOrigins
        var minX = Float.MAX_VALUE; var minY = Float.MAX_VALUE; var minZ = Float.MAX_VALUE
        var maxX = -Float.MAX_VALUE; var maxY = -Float.MAX_VALUE; var maxZ = -Float.MAX_VALUE
        fun take(x: Float, y: Float, z: Float) {
            minX = min(minX, x); minY = min(minY, y); minZ = min(minZ, z)
            maxX = max(maxX, x); maxY = max(maxY, y); maxZ = max(maxZ, z)
        }
        for (i in 0 until obj.vertexCount) take(p[i * 3], p[i * 3 + 1], p[i * 3 + 2])
        for (i in 0 until parts.size / 3) {
            take(parts[i * 3], parts[i * 3 + 1], parts[i * 3 + 2])
            take(parts[i * 3] + 1, parts[i * 3 + 1] + 1, parts[i * 3 + 2] + 1)
        }
        if (minX > maxX) { minX = 0f; maxX = 0f; minY = 0f; maxY = 0f; minZ = 0f; maxZ = 0f }
        cx = (minX + maxX) / 2; cy = (minY + maxY) / 2; cz = (minZ + maxZ) / 2
        var r = 0f
        for (i in 0 until obj.vertexCount) {
            val dx = p[i * 3] - cx; val dy = p[i * 3 + 1] - cy; val dz = p[i * 3 + 2] - cz
            r = max(r, sqrt(dx * dx + dy * dy + dz * dz))
        }
        val corners = FloatArray(parts.size / 3 * 24)
        for (i in 0 until parts.size / 3) for (c in 0 until 8) {
            val x = parts[i * 3] + (c and 1) - cx
            val y = parts[i * 3 + 1] + ((c shr 1) and 1) - cy
            val z = parts[i * 3 + 2] + ((c shr 2) and 1) - cz
            corners[i * 24 + c * 3] = x; corners[i * 24 + c * 3 + 1] = y; corners[i * 24 + c * 3 + 2] = z
            r = max(r, sqrt(x * x + y * y + z * z))
        }
        partCorners = corners
        radius = if (r > 0f) r else 1f

        edges = if (obj.faceCount > 0) {
            val seen = HashSet<Long>()
            val out = ArrayList<Int>()
            val f = obj.faces
            for (i in 0 until obj.faceCount) for (k in 0..2) {
                val a = f[i * 3 + k]; val b = f[i * 3 + (k + 1) % 3]
                val key = min(a, b).toLong() shl 32 or max(a, b).toLong()
                if (seen.add(key)) { out.add(a); out.add(b) }
            }
            out.toIntArray()
        } else {
            IntArray(max(0, obj.vertexCount - 1) * 2) { i -> i / 2 + i % 2 }
        }
    }

    fun centred(i: Int, out: FloatArray) {
        val p = obj.positions
        out[0] = p[i * 3] - cx; out[1] = p[i * 3 + 1] - cy; out[2] = p[i * 3 + 2] - cz
    }
}

/**
 * Draws [scene] turned [yaw] about Y and [pitch] about X (radians), in a slight
 * perspective, filling the smaller side of the draw area. [accent] colours the
 * placeholders for parts.
 */
internal fun DrawScope.drawSno(scene: SnoScene, yaw: Float, pitch: Float, accent: Color, pointRadius: Float) {
    val obj = scene.obj
    val n = obj.vertexCount
    val cy = cos(yaw); val sy = sin(yaw); val cp = cos(pitch); val sp = sin(pitch)
    val f = scene.radius * 3.5f
    val fit = min(size.width, size.height) / 2f * 0.86f / scene.radius * (f - scene.radius) / f
    val mx = size.width / 2f; val my = size.height / 2f

    // View space (x right, y up, z toward the viewer) and screen positions, once per vertex.
    val view = FloatArray(n * 3)
    val screen = FloatArray(n * 2)
    val tmp = FloatArray(3)
    fun project(x0: Float, y0: Float, z0: Float, vi: Int, si: Int, v: FloatArray, s: FloatArray) {
        val x1 = x0 * cy + z0 * sy
        val z1 = -x0 * sy + z0 * cy
        val y2 = y0 * cp - z1 * sp
        val z2 = y0 * sp + z1 * cp
        v[vi] = x1; v[vi + 1] = y2; v[vi + 2] = z2
        val k = fit * f / (f - z2)
        s[si] = mx + x1 * k; s[si + 1] = my - y2 * k
    }
    for (i in 0 until n) {
        scene.centred(i, tmp)
        project(tmp[0], tmp[1], tmp[2], i * 3, i * 2, view, screen)
    }

    if (obj.mode == SnoObject.Mode.SOLID && obj.faceCount > 0) drawFaces(scene, view, screen)
    if (obj.mode == SnoObject.Mode.LINES) drawEdges(scene, view, screen)
    // Points in every mode (§1.5), so an object smaller than a triangle still shows. Over
    // a solid they would show the back's vertices through the front, so a solid gets
    // them only when it is drawn that small.
    if (obj.mode != SnoObject.Mode.SOLID || scene.radius * fit * 2f < pointRadius * 16f) {
        drawPoints(obj, view, screen, if (obj.mode == SnoObject.Mode.POINTS) pointRadius * 1.8f else pointRadius)
    }

    // Placeholder cubes for parts, in the accent colour.
    val corners = scene.partCorners
    if (corners.isNotEmpty()) {
        val cv = FloatArray(corners.size)
        val cs = FloatArray(corners.size / 3 * 2)
        for (c in 0 until corners.size / 3) project(corners[c * 3], corners[c * 3 + 1], corners[c * 3 + 2], c * 3, c * 2, cv, cs)
        for (part in 0 until corners.size / 24) for (a in 0 until 8) for (bit in intArrayOf(1, 2, 4)) {
            val b = a or bit
            if (b == a) continue
            val ia = (part * 8 + a) * 2; val ib = (part * 8 + b) * 2
            drawLine(accent, Offset(cs[ia], cs[ia + 1]), Offset(cs[ib], cs[ib + 1]), strokeWidth = pointRadius * 0.6f)
        }
    }
}

/** Light from the upper left, in front of the object, in view space. */
private val LIGHT = floatArrayOf(-0.45f, 0.6f, 0.66f).let { l ->
    val m = sqrt(l[0] * l[0] + l[1] * l[1] + l[2] * l[2]); floatArrayOf(l[0] / m, l[1] / m, l[2] / m)
}

private fun shadeOf(rgb: Int, k: Float): Int {
    val r = ((rgb shr 16 and 0xFF) * k).toInt().coerceIn(0, 255)
    val g = ((rgb shr 8 and 0xFF) * k).toInt().coerceIn(0, 255)
    val b = ((rgb and 0xFF) * k).toInt().coerceIn(0, 255)
    return (0xFF shl 24) or (r shl 16) or (g shl 8) or b
}

private fun DrawScope.drawFaces(scene: SnoScene, view: FloatArray, screen: FloatArray) {
    val obj = scene.obj
    val fc = obj.faceCount
    val faces = obj.faces
    // Painter's order: farthest face first.
    val order = (0 until fc).sortedBy { i ->
        view[faces[i * 3] * 3 + 2] + view[faces[i * 3 + 1] * 3 + 2] + view[faces[i * 3 + 2] * 3 + 2]
    }
    val verts = FloatArray(fc * 6)
    val colors = IntArray(fc * 3)
    for ((slot, i) in order.withIndex()) {
        val a = faces[i * 3]; val b = faces[i * 3 + 1]; val c = faces[i * 3 + 2]
        // Flat normal from the face's own winding (§1.4): (b - a) × (c - a).
        val ux = view[b * 3] - view[a * 3]; val uy = view[b * 3 + 1] - view[a * 3 + 1]; val uz = view[b * 3 + 2] - view[a * 3 + 2]
        val wx = view[c * 3] - view[a * 3]; val wy = view[c * 3 + 1] - view[a * 3 + 1]; val wz = view[c * 3 + 2] - view[a * 3 + 2]
        var nx = uy * wz - uz * wy; var ny = uz * wx - ux * wz; var nz = ux * wy - uy * wx
        val len = sqrt(nx * nx + ny * ny + nz * nz).takeIf { it > 0f } ?: 1f
        nx /= len; ny /= len; nz /= len
        // The side facing the viewer is lit; a back is the other side of the same face, a little darker.
        val front = nz >= 0f
        val s = if (front) 1f else -1f
        val lambert = max(0f, s * (nx * LIGHT[0] + ny * LIGHT[1] + nz * LIGHT[2]))
        val k = (0.38f + 0.62f * lambert) * (if (front) 1f else 0.72f)
        for ((j, vi) in intArrayOf(a, b, c).withIndex()) {
            verts[slot * 6 + j * 2] = screen[vi * 2]
            verts[slot * 6 + j * 2 + 1] = screen[vi * 2 + 1]
            val rgb = obj.faceColors?.get(i) ?: obj.vertexColors[vi]
            colors[slot * 3 + j] = shadeOf(rgb, k)
        }
    }
    drawIntoCanvas { canvas ->
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            canvas.nativeCanvas.drawVertices(
                Canvas.VertexMode.TRIANGLES, verts.size, verts, 0,
                null, 0, colors, 0, null, 0, 0, FACE_PAINT,
            )
        } else {
            // Before Android 10 hardware drawing has no drawVertices: one flat colour per face.
            for (slot in 0 until fc) {
                val path = Path().apply {
                    moveTo(verts[slot * 6], verts[slot * 6 + 1])
                    lineTo(verts[slot * 6 + 2], verts[slot * 6 + 3])
                    lineTo(verts[slot * 6 + 4], verts[slot * 6 + 5])
                    close()
                }
                drawPath(path, Color(averageOf(colors, slot * 3)))
            }
        }
    }
}

private val FACE_PAINT = Paint(Paint.ANTI_ALIAS_FLAG)

private fun averageOf(colors: IntArray, at: Int): Int {
    var r = 0; var g = 0; var b = 0
    for (j in 0..2) { val c = colors[at + j]; r += c shr 16 and 0xFF; g += c shr 8 and 0xFF; b += c and 0xFF }
    return (0xFF shl 24) or (r / 3 shl 16) or (g / 3 shl 8) or (b / 3)
}

private fun DrawScope.drawEdges(scene: SnoScene, view: FloatArray, screen: FloatArray) {
    val obj = scene.obj
    val e = scene.edges
    val count = e.size / 2
    val order = (0 until count).sortedBy { i -> view[e[i * 2] * 3 + 2] + view[e[i * 2 + 1] * 3 + 2] }
    val r = scene.radius
    val width = max(1.5f, min(size.width, size.height) / 160f)
    for (i in order) {
        val a = e[i * 2]; val b = e[i * 2 + 1]
        // Far edges a little dimmer, so a wireframe reads front from back. Colours interpolate along the edge (§1.5).
        val depth = ((view[a * 3 + 2] + view[b * 3 + 2]) / 2f / r).coerceIn(-1f, 1f)
        val k = 0.7f + 0.3f * (depth + 1f) / 2f
        val pa = Offset(screen[a * 2], screen[a * 2 + 1]); val pb = Offset(screen[b * 2], screen[b * 2 + 1])
        val ca = Color(shadeOf(obj.vertexColors[a], k)); val cb = Color(shadeOf(obj.vertexColors[b], k))
        if (abs(pa.x - pb.x) + abs(pa.y - pb.y) < 0.5f) continue
        drawLine(Brush.linearGradient(listOf(ca, cb), pa, pb), pa, pb, strokeWidth = width)
    }
}

private fun DrawScope.drawPoints(obj: SnoObject, view: FloatArray, screen: FloatArray, radius: Float) {
    val order = (0 until obj.vertexCount).sortedBy { view[it * 3 + 2] }
    for (i in order) {
        drawCircle(Color(0xFF000000.toInt() or obj.vertexColors[i]), radius, Offset(screen[i * 2], screen[i * 2 + 1]))
    }
}
