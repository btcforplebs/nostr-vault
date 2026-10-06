package com.nostrvault.ui.screens

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class MediaModerationTargetTest {

    @Test
    fun `someone else's media can be reported and blocked`() {
        assertEquals("alice", mediaModerationTarget("alice", ownerHex = "me", activeHex = "me"))
    }

    @Test
    fun `no known author hides the items`() {
        assertNull(mediaModerationTarget(null, ownerHex = "me", activeHex = "me"))
        assertNull(mediaModerationTarget("", ownerHex = "me", activeHex = "me"))
    }

    @Test
    fun `your own media offers neither, on either account`() {
        assertNull(mediaModerationTarget("me", ownerHex = "me", activeHex = "me"))
        // Posting as a second account: the owner's media and the account's own.
        assertNull(mediaModerationTarget("me", ownerHex = "me", activeHex = "alt"))
        assertNull(mediaModerationTarget("alt", ownerHex = "me", activeHex = "alt"))
    }
}
