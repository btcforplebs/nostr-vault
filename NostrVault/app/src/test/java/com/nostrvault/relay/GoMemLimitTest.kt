package com.nostrvault.relay

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * The Go relay's memory limit on a phone scales with its RAM: an eighth, 384 MiB to 1 GiB. A flat 192/256 MiB is a
 * limit a populated vault reaches, and the collector then runs back to back (iOS #1007); a quarter let the 3.6 GB
 * Moto's Go keep ~900 MiB (sweep 11-01).
 */
class GoMemLimitTest {
    private val gib = 1L shl 30

    @Test fun `an eighth of the RAM`() {
        assertEquals(512, RelayConfiguration.phoneGoMemLimitMB(4 * gib))
        assertEquals(768, RelayConfiguration.phoneGoMemLimitMB(6 * gib))
        assertEquals(1024, RelayConfiguration.phoneGoMemLimitMB(8 * gib))
    }

    /** Never down at the 256 MiB that ran GC back to back, never above 1 GiB on a 12 GiB+ phone. */
    @Test fun `clamped both ways`() {
        assertEquals(384, RelayConfiguration.phoneGoMemLimitMB(512L shl 20))
        assertEquals(384, RelayConfiguration.phoneGoMemLimitMB(0))
        assertEquals(384, RelayConfiguration.phoneGoMemLimitMB(-1))
        assertEquals(1024, RelayConfiguration.phoneGoMemLimitMB(12 * gib))
        assertEquals(1024, RelayConfiguration.phoneGoMemLimitMB(64 * gib))
    }

    @Test fun `RAM comes from MemTotal in meminfo`() {
        val meminfo = File.createTempFile("meminfo", null).apply {
            writeText("MemTotal:        3843584 kB\nMemFree:          123456 kB\n")
            deleteOnExit()
        }
        assertEquals(3843584L * 1024, RelayConfiguration.totalMemoryBytes(meminfo))
        // A moto g play's 3.7 GiB of usable RAM gets 469 MiB: not 192, not 938.
        assertEquals(469, RelayConfiguration.phoneGoMemLimitMB(RelayConfiguration.totalMemoryBytes(meminfo)))
    }

    @Test fun `an unreadable meminfo falls back to the floor`() {
        assertEquals(0L, RelayConfiguration.totalMemoryBytes(File("/nonexistent/meminfo")))
        assertEquals(384, RelayConfiguration.phoneGoMemLimitMB(RelayConfiguration.totalMemoryBytes(File("/nonexistent/meminfo"))))
    }

    @Test fun `the relay env carries the limit`() {
        val env = RelayConfiguration.generateEnvDictionary(
            HavenConfig(),
            File(System.getProperty("java.io.tmpdir"), "go-mem-limit-test"),
        )
        val mb = env.getValue("GO_MEM_LIMIT_MB").toInt()
        assertTrue("limit $mb within 384..1024", mb in 384..1024)
    }
}
