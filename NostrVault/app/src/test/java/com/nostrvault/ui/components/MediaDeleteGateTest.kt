package com.nostrvault.ui.components

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Feed media long-press offered Delete on someone else's photo (2026-11-23). */
class MediaDeleteGateTest {
    private val me = "a".repeat(64)
    private val them = "b".repeat(64)

    @Test fun `someone else's media has no Delete`() {
        assertFalse(MediaDeleteGate.showsDelete(poster = them, activePubkey = me))
    }

    @Test fun `your own media has Delete`() {
        assertTrue(MediaDeleteGate.showsDelete(poster = me, activePubkey = me))
        assertTrue(MediaDeleteGate.showsDelete(poster = me.uppercase(), activePubkey = me))
    }

    @Test fun `unknown poster or account has no Delete`() {
        assertFalse(MediaDeleteGate.showsDelete(poster = null, activePubkey = me))
        assertFalse(MediaDeleteGate.showsDelete(poster = "", activePubkey = me))
        assertFalse(MediaDeleteGate.showsDelete(poster = me, activePubkey = ""))
    }
}
