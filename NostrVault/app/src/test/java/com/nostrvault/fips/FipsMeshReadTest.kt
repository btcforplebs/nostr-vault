package com.nostrvault.fips

import okio.Buffer
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.security.MessageDigest

class FipsMeshReadTest {
    private val npub = "npub1xlrwmhu" + "q".repeat(51)

    private fun sha(bytes: ByteArray) =
        MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

    @Test
    fun matchingBytesAreReturned() {
        val blob = ByteArray(200_000) { (it % 251).toByte() }
        val got = FipsMeshInterceptor.readVerified(Buffer().write(blob), sha(blob))
        assertArrayEquals(blob, got)
    }

    @Test
    fun wrongBytesAreDropped() {
        val blob = "real".toByteArray()
        val got = FipsMeshInterceptor.readVerified(Buffer().write("fake".toByteArray()), sha(blob))
        assertNull(got)
    }

    @Test
    fun overTheCapIsDropped() {
        val blob = ByteArray(1_000)
        assertNull(FipsMeshInterceptor.readVerified(Buffer().write(blob), sha(blob), maxBytes = 999))
        assertArrayEquals(blob, FipsMeshInterceptor.readVerified(Buffer().write(blob), sha(blob), maxBytes = 1_000))
    }

    @Test
    fun onlyAnExactMeshEntryCounts() {
        assertEquals(npub, FipsMediaRouter.meshNpubIn("fipsmesh://$npub/"))
        for (bad in listOf(
            "fipsmesh://$npub",
            "fipsmesh://$npub/evil",
            "fipsmesh://$npub:80/",
            "fipsmesh://user@$npub/",
            "fipsmesh://$npub/?x=1",
            "fipsmesh://${npub}b/",
            "FIPSMESH://$npub/",
            "https://$npub/",
        )) assertNull(bad, FipsMediaRouter.meshNpubIn(bad))
    }

    @Test
    fun aMeshOnlyUrlNamesItsVault() {
        assertEquals(npub, FipsMediaRouter.meshNpubInHost("$npub.fips"))
        assertEquals(npub, FipsMediaRouter.meshNpubInHost("$npub.FIPS"))
        for (bad in listOf("$npub.fips.evil.com", "x$npub.fips", "$npub", "logen.btcforplebs.com")) {
            assertNull(bad, FipsMediaRouter.meshNpubInHost(bad))
        }
    }

    @Test
    fun onlyFollowedAuthorsAreDialled() {
        val friend = "a".repeat(64)
        val stranger = "b".repeat(64)
        FipsMediaRouter.follows = setOf(friend)
        try {
            assertEquals(true, FipsMediaRouter.mayDial(friend))
            assertEquals(false, FipsMediaRouter.mayDial(stranger))
        } finally {
            FipsMediaRouter.follows = emptySet()
        }
    }
}
