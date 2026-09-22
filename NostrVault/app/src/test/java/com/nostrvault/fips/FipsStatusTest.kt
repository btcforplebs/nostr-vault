package com.nostrvault.fips

import com.nostrvault.ui.screens.settings.formatUptime
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The payload strings here are copied verbatim from the format! calls in
 * fips-bridge/crates/fips-bridge-ffi/src/lib.rs (FipsBridgeStatusJSON). If that
 * function's shape changes, these fail — which is the point: nothing else on
 * this side of the FFI can notice a field that quietly stopped arriving.
 */
class FipsStatusTest {

    private val json = Json { ignoreUnknownKeys = true }

    @Test fun `a stopped bridge sends running and nothing else`() {
        val status = json.decodeFromString<FipsStatus>("""{"running":false}""")

        assertFalse(status.running)
        // Null, not "". A blank string would render as an address the user
        // could select and copy, and they would copy nothing.
        assertNull(status.npub)
        assertNull(status.address)
        assertEquals(0L, status.uptimeSeconds)
    }

    @Test fun `a running bridge carries the address peers dial`() {
        val status = json.decodeFromString<FipsStatus>(
            """{"running":true,"npub":"npub1exampleexampleexample","address":"fd00::1","uptime_s":93}"""
        )

        assertTrue(status.running)
        assertEquals("npub1exampleexampleexample", status.npub)
        assertEquals("fd00::1", status.address)
        // snake_case on the wire, camelCase in Kotlin: without the SerialName
        // this decodes to 0 and the screen reads "Up 0s" forever.
        assertEquals(93L, status.uptimeSeconds)
    }

    @Test fun `an unknown field does not throw away the whole snapshot`() {
        // The Rust side may add counters; a strict parser would turn that into
        // "bridge stopped" on a bridge that is running.
        val status = json.decodeFromString<FipsStatus>(
            """{"running":true,"npub":"npub1x","address":"fd00::2","uptime_s":1,"bytes_relayed":4096}"""
        )

        assertTrue(status.running)
        assertEquals("npub1x", status.npub)
        assertEquals(1L, status.uptimeSeconds)
    }

    @Test fun `a bound endpoint with no transit is not a working one`() {
        // The state that reads as success and is not: bound, advertising, and
        // unreachable from any other network. hasTransit is what the screen
        // warns on, so it must not be satisfied by merely being up.
        val reaching = json.decodeFromString<FipsStatus>(
            """{"running":true,"npub":"npub1x","address":"fd00::3","uptime_s":4,"peers":[]}"""
        )
        assertTrue(reaching.running)
        assertFalse(reaching.hasTransit)

        val seedDown = json.decodeFromString<FipsStatus>(
            """{"running":true,"npub":"npub1x","address":"fd00::3","uptime_s":9,"peers":[{"npub":"npub1seed","alias":"test-us01","connected":false,"addr":null,"rtt_ms":null}]}"""
        )
        assertFalse(seedDown.hasTransit)

        val up = json.decodeFromString<FipsStatus>(
            """{"running":true,"npub":"npub1x","address":"fd00::3","uptime_s":9,"peers":[{"npub":"npub1seed","alias":"test-us02","connected":true,"addr":"23.182.128.74:2121","rtt_ms":47}]}"""
        )
        assertTrue(up.hasTransit)
        assertEquals(47L, up.peers.first().rttMs)
        assertEquals("23.182.128.74:2121", up.peers.first().addr)
    }

    @Test fun `a connected peer that is not a seed is not transit`() {
        // A phone on the same wifi connects without proving anything about
        // reachability from outside it. Only an aliased seed is transit, and
        // the alias is filled in by the Rust side from the seed table.
        val lanOnly = json.decodeFromString<FipsStatus>(
            """{"running":true,"npub":"npub1x","address":"fd00::4","uptime_s":30,"peers":[{"npub":"npub1neighbour","alias":null,"connected":true,"addr":"192.168.4.99:52184","rtt_ms":4}]}"""
        )
        assertFalse(lanOnly.hasTransit)
    }

    @Test fun `uptime reads as a duration, not a number of seconds`() {
        assertEquals("45s", formatUptime(45))
        assertEquals("1m 5s", formatUptime(65))
        assertEquals("2h 1m", formatUptime(7260))
    }

    /**
     * The build ships no mesh library for 32-bit ARM (nvpn-fips-core 0.4.72
     * does not compile for it), and CMake leaves the JNI shim out of any
     * checkout without the Rust artifact. Both cases land here: on the JVM
     * there is no libfips_bridge_ffi.so either, so this exercises the real
     * unavailable path rather than a mock of it.
     */
    @Test fun `every call is safe when the library is absent`() {
        assertFalse(FipsBridge.isAvailable)

        assertEquals(FipsBridge.ERR_UNAVAILABLE, FipsBridge.start("nsec1whatever"))
        assertEquals(FipsBridge.ERR_UNAVAILABLE, FipsBridge.export(8080))
        assertEquals(FipsBridge.ERR_UNAVAILABLE, FipsBridge.ingress("npub1whatever"))
        assertNull(FipsBridge.generateNsec())
        assertEquals(FipsStatus.stopped, FipsBridge.status())
        FipsBridge.stop()
    }
}
