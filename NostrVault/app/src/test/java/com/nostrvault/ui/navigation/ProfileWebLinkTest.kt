package com.nostrvault.ui.navigation

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** Share profile links: what the app hands out, and what it accepts back. */
class ProfileWebLinkTest {

    private val hex = "b".repeat(64)

    private val decoder = object : NostrEntityDecoder {
        override fun noteToHex(note1: String) = null
        override fun neventToHex(nevent1: String) = null
        override fun npubToHex(npub: String) = if (npub == "npub1good") hex else null
        override fun nprofileToHex(nprofile: String) = if (nprofile == "nprofile1good") hex else null
        override fun naddrToCoordinate(naddr1: String) = null
    }

    @Test fun `the link is the web profile page`() {
        assertEquals("https://nostrvault.app/p/npub1good", ProfileWebLink.forNpub("npub1good"))
    }

    @Test fun `a p link opens the profile`() {
        val profile = Screen.Profile.createRoute(hex)
        for (link in listOf(
            "https://nostrvault.app/p/npub1good",
            "https://www.nostrvault.app/p/npub1good/",
            "http://nostrvault.app/p/npub1good?ref=qr",
            "HTTPS://NostrVault.app/p/nprofile1good#x",
            "https://nostrvault.app/p/$hex",
            "nostrvault://p/npub1good",
            "nostrvault://p/npub1good/",
        )) assertEquals(link, profile, DeepLinkRouter.fromUri(link, decoder)?.route)
    }

    @Test fun `other web links are not ours`() {
        for (link in listOf(
            "https://nostrvault.app/thread/nevent1x",
            "https://nostrvault.app/p/",
            "https://nostrvault.app/p/npub1good/extra",
            "https://evil.example/p/npub1good",
            "https://nostrvault.app.evil.example/p/npub1good",
            "https://nostrvault.app/p/npub1bad",
        )) assertNull(link, DeepLinkRouter.fromUri(link, decoder))
    }

    @Test fun `the site's Open in Nostr Vault link pre-fills setup`() {
        assertEquals("npub1good", ProfileWebLink.idFrom("nostrvault://p/npub1good"))
        assertEquals("npub1good", ProfileWebLink.idFrom("NOSTRVAULT://p/npub1good?x=1"))
        assertNull(ProfileWebLink.idFrom("nostrvault://p/"))
        assertNull(ProfileWebLink.idFrom("nostrvault://profile/npub1good"))
        assertEquals(hex, ProfileWebLink.pubkeyFrom("nostrvault://p/npub1good", decoder))
    }

    @Test fun `typed scanned or pasted input names a pubkey`() {
        for (input in listOf(
            "https://nostrvault.app/p/npub1good", " npub1good\n", "nostr:npub1good",
            "NPUB1GOOD", "nprofile1good", hex.uppercase(),
        )) assertEquals(input, hex, ProfileWebLink.pubkeyFrom(input, decoder))
        for (input in listOf("", "hello", "npub1bad", "https://example.com/p/npub1good", "b".repeat(63)))
            assertNull(input, ProfileWebLink.pubkeyFrom(input, decoder))
    }
}
