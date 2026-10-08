package com.nostrvault.fips

import com.nostrvault.ui.screens.settings.formatUptime
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The status strings here are copied verbatim from what status_json() in
 * fips-v2-android/src/lib.rs produces (its own test pins the stopped one). If
 * that shape changes, these fail — which is the point: nothing else on this
 * side of the FFI can notice a field that quietly stopped arriving.
 */
class FipsStatusTest {

    @Test fun `a stopped node reports running false and no address`() {
        val status = FipsBridge.parseStatus(
            """{"running":false,"uptime_s":0,"exported":[],"peers":[],"reading":[],"counters":""" +
                """{"served_open":0,"served_total":0,"served_rx":0,"served_tx":0,""" +
                """"read_open":0,"read_total":0,"read_rx":0,"read_tx":0}}"""
        )

        assertFalse(status.running)
        // Null, not "". A blank string would render as an address the user
        // could select and copy, and they would copy nothing.
        assertNull(status.npub)
        assertNull(status.address)
        assertEquals(0L, status.uptimeSeconds)
    }

    @Test fun `a running node carries the address peers dial`() {
        val status = FipsBridge.parseStatus(
            """{"running":true,"npub":"npub15ltk3g7wjmt0sjqk78cjv4mtttmy8ffyy9g7hg7spxwdz28wr2wszsrurl",""" +
                """"address":"fdaa:ef18:885f:1d49:9c7b:c23f:38ab:2baa","uptime_s":93,"exported":[3355],""" +
                """"peers":["npub12fuf7setehcxg6dvdl2muj5dmk9c7kjmhcvexd0ndtskanfzjpns76048p"]}"""
        )

        assertTrue(status.running)
        assertEquals("fdaa:ef18:885f:1d49:9c7b:c23f:38ab:2baa", status.address)
        // snake_case on the wire, camelCase in Kotlin: without the SerialName
        // this decodes to 0 and the screen reads "Up 0s" forever.
        assertEquals(93L, status.uptimeSeconds)
        assertEquals(listOf(3355), status.exported)
        assertEquals(1, status.peers.size)
    }

    @Test fun `reading and counters decode from their snake_case names`() {
        val status = FipsBridge.parseStatus(
            """{"running":true,"uptime_s":5,"exported":[],"peers":[],""" +
                """"reading":[{"npub":"npub1friend","port":40123}],""" +
                """"counters":{"served_open":1,"served_total":3,"served_rx":10,"served_tx":20,""" +
                """"read_open":2,"read_total":4,"read_rx":30,"read_tx":40}}"""
        )

        assertEquals(listOf(FipsReading("npub1friend", 40123)), status.reading)
        assertEquals(FipsCounters(1, 3, 10, 20, 2, 4, 30, 40), status.counters)
    }

    @Test fun `an unknown field does not throw away the whole snapshot`() {
        // The Rust side will add counters; a strict parser would turn that into
        // "stopped" on a node that is running.
        val status = FipsBridge.parseStatus(
            """{"running":true,"npub":"npub1x","address":"fd00::2","uptime_s":1,"bytes_in":4096}"""
        )

        assertTrue(status.running)
        assertEquals("npub1x", status.npub)
    }

    @Test fun `garbage reads as stopped, not as a crash`() {
        assertEquals(FipsStatus.stopped, FipsBridge.parseStatus("not json"))
    }

    @Test fun `start options use the field names the library reads`() {
        // StartOptions in lib.rs is serde(default) with snake_case names; a
        // misspelt key is silently ignored there, so pin every one here.
        val encoded = FipsBridge.encodeOptions(
            FipsStartOptions(peers = listOf("npub1a"), relays = listOf("wss://r"), udpPort = 2121, lan = true)
        )
        val obj = Json.parseToJsonElement(encoded).jsonObject

        assertEquals(setOf("peers", "relays", "udp_port", "lan"), obj.keys)
        assertEquals("npub1a", obj["peers"]!!.jsonArray[0].jsonPrimitive.content)
        assertEquals("2121", obj["udp_port"]!!.jsonPrimitive.content)
        assertEquals("true", obj["lan"]!!.jsonPrimitive.content)
    }

    @Test fun `uptime reads as a duration, not a number of seconds`() {
        assertEquals("45s", formatUptime(45))
        assertEquals("1m 5s", formatUptime(65))
        assertEquals("2h 1m", formatUptime(7260))
    }

    /**
     * On the JVM there is no libnvfips.so, so this exercises the real
     * unavailable path — the same one a device without the arm64 library takes.
     */
    @Test fun `every call is safe when the library is absent`() {
        assertFalse(FipsBridge.isAvailable)

        assertEquals(FipsBridge.ERR_UNAVAILABLE, FipsBridge.start("nsec1whatever"))
        assertEquals(FipsBridge.ERR_UNAVAILABLE, FipsBridge.export(8080))
        assertEquals(FipsBridge.ERR_UNAVAILABLE, FipsBridge.unexport())
        assertEquals(FipsIngress(error = FipsBridge.ERR_UNAVAILABLE), FipsBridge.ingress("npub1whatever"))
        assertNull(FipsBridge.generateNsec())
        assertEquals(FipsStatus.stopped, FipsBridge.status())
        FipsBridge.stop()
    }
}
