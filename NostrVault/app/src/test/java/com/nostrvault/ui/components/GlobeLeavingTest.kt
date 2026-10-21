package com.nostrvault.ui.components

import com.nostrvault.data.model.TrustMap
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Where the globe's leaving stars go (iOS `TrustMapTests` leavingRadius cases). */
class GlobeLeavingTest {
    @Test fun `a layer change fades leavers in place`() {
        // Picking a layer or filter keeps the middle: nobody flies outward.
        for (r in listOf(TrustMap.RING_RADIUS, TrustMap.CLOSE_RADIUS, TrustMap.OUTER_RADIUS)) {
            assertEquals(r, GlobeScene.leavingRadius(r, newCenter = false), 0.0)
        }
    }

    @Test fun `a new center sends leavers out past the shells`() {
        val r = GlobeScene.leavingRadius(TrustMap.CLOSE_RADIUS, newCenter = true)
        assertTrue(r > TrustMap.OUTER_RADIUS)
        assertEquals(GlobeScene.DRIFT_OUT_RADIUS, r, 0.0)
    }
}
