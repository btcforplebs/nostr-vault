package com.nostrvault.data.remote

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Same rules as iOS LocalTLSPolicyTests. */
class LocalTlsTest {
    @After
    fun tearDown() = LocalTls.forgetAll()

    @Test
    fun `loopback is trusted as is`() {
        listOf("localhost", "127.0.0.1", "127.0.0.2", "::1", "[::1]", "0.0.0.0", "LOCALHOST").forEach {
            assertEquals(it, LocalTls.Kind.LOOPBACK, LocalTls.kind(it))
        }
    }

    @Test
    fun `private addresses and mDNS names are pinned`() {
        listOf("10.0.0.5", "172.16.0.1", "172.31.255.255", "192.168.1.20", "macbook.local").forEach {
            assertEquals(it, LocalTls.Kind.LAN, LocalTls.kind(it))
        }
    }

    /** The old hostname verifier matched on a name's first characters. */
    @Test
    fun `lookalikes are public`() {
        listOf("10.example.com", "192.168.example.com", "172.32.0.1", "172.15.0.1", "10.0.0",
            "10.0.0.256", "relay.damus.io", "local", "").forEach {
            assertEquals(it, LocalTls.Kind.PUBLIC, LocalTls.kind(it))
        }
        assertEquals(LocalTls.Kind.PUBLIC, LocalTls.kind(null))
    }

    @Test
    fun `pin on first use, then require the same certificate`() {
        assertEquals(LocalTls.Decision.ACCEPT_AND_PIN, LocalTls.decide(null, "aa"))
        assertEquals(LocalTls.Decision.ACCEPT, LocalTls.decide("aa", "aa"))
        assertEquals(LocalTls.Decision.REJECT, LocalTls.decide("aa", "bb"))
    }

    @Test
    fun `a changed certificate is refused and listed until forgotten`() {
        assertTrue(LocalTls.check("192.168.1.20:4869", "aa"))
        assertFalse(LocalTls.check("192.168.1.20:4869", "bb"))
        assertEquals(listOf("192.168.1.20:4869"), LocalTls.refused.value)
        LocalTls.forget("192.168.1.20:4869")
        assertTrue(LocalTls.refused.value.isEmpty())
        assertTrue(LocalTls.check("192.168.1.20:4869", "bb"))
    }

    /** Pins checked before ConfigStore set the file must not be written over the saved ones. */
    @Test
    fun `setting the pin file reads its pins instead of keeping the cache`() {
        val dir = java.nio.file.Files.createTempDirectory("pins").toFile()
        try {
            LocalTls.pinFile = null
            assertTrue(LocalTls.check("10.0.0.5:4869", "early"))
            val file = java.io.File(dir, "pins.json").apply { writeText("""{"10.0.0.5:4869":"saved"}""") }
            LocalTls.pinFile = file
            assertFalse(LocalTls.check("10.0.0.5:4869", "early"))
            assertTrue(LocalTls.check("10.0.0.5:4869", "saved"))
        } finally {
            LocalTls.pinFile = null
            dir.deleteRecursively()
        }
    }
}

