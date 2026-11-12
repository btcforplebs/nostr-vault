package com.nostrvault.service

import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.file.Files

/** The pieces of [AutoMirrorRules]; the whole run is [AutoMirrorRunTest]. */
class AutoMirrorRulesTest {
    private val h = "ab".repeat(32)

    @Test fun `due every 3 hours from the last start, a clock set back does not hold it off`() {
        val t = 1_000_000_000L
        assertTrue(AutoMirrorRules.due(null, t))
        assertFalse(AutoMirrorRules.due(t, t + AutoMirrorRules.EVERY_MS - 1))
        assertTrue(AutoMirrorRules.due(t, t + AutoMirrorRules.EVERY_MS))
        assertTrue(AutoMirrorRules.due(t, t - 1))
    }

    @Test fun `imeta x is read per url, bad hashes ignored`() {
        val tags = listOf(
            listOf("imeta", "url https://a/1.jpg", "m image/jpeg", "x ${h.uppercase()}"),
            listOf("imeta", "url https://a/2.jpg", "x nothex"),
            listOf("t", "x $h"),
        )
        assertEquals(mapOf("https://a/1.jpg" to h), AutoMirrorRules.imetaHashes(tags))
    }

    @Test fun `the start is on disk the moment a run begins, links once saved`() {
        val dir = Files.createTempDirectory("ams").toFile()
        try {
            AutoMirrorState(dir).apply {
                recordStart(42L)
                remember("https://a/x.jpg", h)
                remember("https://a/y.jpg", "short")
            }
            val relaunched = AutoMirrorState(dir)
            assertEquals(42L, relaunched.lastStart)
            assertNull("links wait for saveIfChanged", relaunched.hashFor("https://a/x.jpg"))

            AutoMirrorState(dir).apply { remember("https://a/x.jpg", h); saveIfChanged() }
            AutoMirrorState(dir).apply {
                assertEquals(h, hashFor("https://a/x.jpg"))
                assertNull(hashFor("https://a/y.jpg"))
            }
        } finally {
            dir.deleteRecursively()
        }
    }

    @Test fun `one signature however many ask, a failed one is not asked again`() = runTest {
        var asked = 0
        val sig = RunSignature { asked++; OwnVaultAuth.Signed("hdr") }
        (1..20).map { async { sig.get { 0L } } }.awaitAll().forEach { assertEquals(OwnVaultAuth.Signed("hdr"), it) }
        assertEquals(1, asked)

        var failed = 0
        val none = RunSignature { failed++; null }
        assertNull(none.get()); assertNull(none.get())
        assertEquals(1, failed)
    }

    @Test fun `limits stop at the cap and once the signature is nearly an hour old`() = runTest {
        var now = 0L
        val sig = RunSignature { OwnVaultAuth.Signed("hdr") }
        val limits = RunLimits(sig, cap = 3, clock = { now })
        sig.get { now }
        assertTrue(limits.take()); assertTrue(limits.take())
        now = AutoMirrorRules.SIGNED_FOR_MS
        assertFalse("auth nearly expired", limits.take())
        now = 0L
        assertTrue(limits.take())
        assertFalse("cap", limits.take())
        assertEquals(3, limits.started)
    }
}
