package com.nostrvault.shareportal

import com.nostrvault.ui.navigation.DeepLinkRouter
import com.nostrvault.ui.navigation.NostrEntityDecoder
import com.nostrvault.ui.navigation.Screen
import com.nostrvault.ui.screens.shareportal.SharePortalActivity
import org.junit.Assert.assertEquals
import org.junit.Test

class SharePortalDeepLinkTest {
    private val noDecoder = object : NostrEntityDecoder {
        override fun noteToHex(note1: String): String? = null
        override fun neventToHex(nevent1: String): String? = null
        override fun npubToHex(npub: String): String? = null
        override fun nprofileToHex(nprofile: String): String? = null
        override fun naddrToCoordinate(naddr1: String) = null
    }

    @Test fun openNowLandsOnTheReviewCard() {
        assertEquals(
            Screen.SharePortalReview.route,
            DeepLinkRouter.fromUri(SharePortalActivity.SHARE_PORTAL_LINK, noDecoder)?.route,
        )
    }
}
