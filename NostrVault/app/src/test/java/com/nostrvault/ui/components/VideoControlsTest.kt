package com.nostrvault.ui.components

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** A video page's control rail in the media viewers (iOS FeedMediaViewer). */
class VideoControlsTest {

    @Test fun showsAtFirstAndATapToggles() {
        val controls = VideoControls()
        assertTrue(controls.shown.value)
        controls.tap()
        assertFalse(controls.shown.value)
        controls.tap()
        assertTrue(controls.shown.value)
    }

    @Test fun zoomingInHidesItAndZoomingOutDoesNotBringItBack() {
        val controls = VideoControls()
        controls.zoomed(2f)
        assertFalse(controls.shown.value)
        controls.zoomed(1f)
        assertFalse(controls.shown.value)
        controls.tap()
        assertTrue(controls.shown.value)
    }

    @Test fun aPinchThatStaysAt1xLeavesItAlone() {
        val controls = VideoControls()
        controls.zoomed(1f)
        controls.zoomed(1.04f)
        assertTrue(controls.shown.value)
    }
}
