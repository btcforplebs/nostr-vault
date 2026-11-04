package com.nostrvault.ui.components

import androidx.media3.common.Player
import io.mockk.mockk
import io.mockk.verify
import org.junit.After
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** PiP on the live stream and feed videos (PiP plan lane C, RESEARCH/NV_PIP_PLAN.md). */
class VideoPiPBridgeTest {
    private val own = mockk<Player>(relaxed = true)
    private val miniPlayers = mockk<Player>(relaxed = true)

    @After fun tearDown() {
        VideoPiPBridge.clearActive(own)
        VideoPiPBridge.clearActive(miniPlayers)
        VideoPiPBridge.takePiPOnOpen()
    }

    @Test fun `closing PiP pauses our own video`() {
        VideoPiPBridge.setActive(own)
        VideoPiPBridge.pauseActive()
        verify(exactly = 1) { own.pause() }
    }

    @Test fun `closing PiP leaves the mini player's live stream playing`() {
        VideoPiPBridge.setActive(miniPlayers, shared = true)
        assertTrue(VideoPiPBridge.hasActiveVideo)
        VideoPiPBridge.pauseActive()
        verify(exactly = 0) { miniPlayers.pause() }
    }

    @Test fun `a feed video's PiP button asks once`() {
        assertFalse(VideoPiPBridge.takePiPOnOpen())
        VideoPiPBridge.requestPiPOnOpen()
        assertTrue(VideoPiPBridge.takePiPOnOpen())
        assertFalse("taken once", VideoPiPBridge.takePiPOnOpen())
    }

    @Test fun `only the registered player clears itself`() {
        VideoPiPBridge.setActive(own)
        VideoPiPBridge.clearActive(miniPlayers)
        assertTrue(VideoPiPBridge.hasActiveVideo)
        VideoPiPBridge.clearActive(own)
        assertFalse(VideoPiPBridge.hasActiveVideo)
    }
}
