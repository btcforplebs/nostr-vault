package com.nostrvault.ui.components

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Only a vault link (.fips) blames the owner's vault; any https photo is a plain broken image. */
class MediaVaultLinkTest {
    private val npub = "npub1qqxjlq4nw7zz0xdq8tgy0d6pxz8kjlv7xz0wyz5fz9l6ynmx8hls4ygwkp"

    @Test
    fun fipsLinksAreTheVault() {
        listOf(
            "http://$npub.fips/487dc1578912f424773b0befc4eff491f026f0f24652f1d4ff66a85639455217",
            "http://${npub.uppercase()}.FIPS/abc.jpg",
            "http://$npub.fips./abc",
        ).forEach { assertTrue(it, MediaVaultLink.isVault(it)) }
    }

    @Test
    fun httpsServersAreNot() {
        listOf(
            "https://blossom.primal.net/487dc157.jpg",
            "https://image.nostr.build/a.png",
            "https://fips.example.com/a.png",
            "https://example.com/photo.fips",
            "https://logen.btcforplebs.com/abc.jpg",
            "not a url at all",
            "",
        ).forEach { assertFalse(it, MediaVaultLink.isVault(it)) }
    }
}
