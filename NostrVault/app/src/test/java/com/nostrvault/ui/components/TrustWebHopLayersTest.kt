package com.nostrvault.ui.components

import androidx.compose.ui.geometry.Offset
import com.nostrvault.data.model.GlobeSphereField
import com.nostrvault.data.model.TrustMap
import com.nostrvault.data.model.TrustMapOuter
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The Hop chips' counts and a hop sphere's spots for a path. iOS `TrustWebView+HopLayers.swift`, `GlobeHopSphere.screenPoint`. */
class TrustWebHopLayersTest {
    private fun pk(i: Int) = "%064x".format(i)

    @Test fun `a hop chip counts top plus haze, and drops its number without a haze`() {
        val outer = TrustMapOuter(TrustMapOuter.Source.RANKED, listOf(
            TrustMapOuter.Ring(3, listOf(pk(1), pk(2)), haze = listOf(pk(3), pk(4), pk(5))),
            TrustMapOuter.Ring(4, listOf(pk(6))),
        ))
        val hop3 = TrustMap.Layer.entries.first { it.hop == 3 }
        val hop4 = TrustMap.Layer.entries.first { it.hop == 4 }
        val counts = TrustWebHopLayers.withHops(mapOf(hop4 to 99), outer)
        assertEquals(5, counts[hop3])
        assertFalse(hop4 in counts)
    }

    @Test fun `a sphere person's spot is where the sphere draws them, on their own hop only`() {
        val ring = TrustMapOuter.Ring(3, listOf(pk(1), pk(2)), haze = listOf(pk(3)))
        val identity = doubleArrayOf(1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0)
        val pole = GlobeSphereField.pole(pk(9))
        val placed = GlobeHopSphere.Placed(ring, Offset(500f, 800f), 300.0, 1.0, 1.0)
        GlobeHopSphere.prepare(Any(), listOf(placed), identity, pole, emptySet(), null, null, 2f, lite = false)
        val points = GlobeSphereField.points(ring.top + ring.haze, ring.top.size, pole)
        val q = GlobeSphereField.project(points[3], points[4], points[5])
        val spot = GlobeHopSphere.screenPoint(pk(2), 3)!!
        assertEquals(500 + q.x * 300, spot.x, 1e-6)
        assertEquals(800 + q.y * 300, spot.y, 1e-6)
        assertNotNull(GlobeHopSphere.screenPoint(pk(3), null))
        assertNull(GlobeHopSphere.screenPoint(pk(2), 4))
        assertNull(GlobeHopSphere.screenPoint(pk(8), null))
        GlobeHopSphere.clear()
        assertTrue(GlobeHopSphere.screenPoint(pk(2), 3) == null)
    }
}
