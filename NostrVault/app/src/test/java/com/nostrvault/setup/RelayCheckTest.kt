package com.nostrvault.setup

import com.nostrvault.setup.RelayCheck.Result
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Mirrors iOS RelayCheckTests. */
class RelayCheckTest {
    private val defaults = listOf("wss://relay.primal.net", "wss://nos.lol", "wss://nostr.mom")

    @Test fun theirWriteRelaysComeFirstThenDefaultsWithoutDuplicates() {
        val tags = listOf(
            listOf("r", "wss://relay.damus.io"), listOf("r", "wss://nostr.wine/", "write"),
            listOf("r", "wss://read.only", "read"), listOf("r", "WSS://NOS.LOL"), listOf("p", "x"),
        )
        val rows = RelayCheck.rows(tags, defaults)
        assertEquals(
            listOf("wss://relay.damus.io", "wss://nostr.wine", "wss://nos.lol", "wss://relay.primal.net", "wss://nostr.mom"),
            rows.map { it.url },
        )
        assertEquals(listOf(true, true, true, false, false), rows.map { it.isYours })
    }

    @Test fun noRelayListMeansDefaults() {
        assertEquals(defaults, RelayCheck.rows(emptyList(), defaults).map { it.url })
    }

    @Test fun results() {
        assertEquals(Result.Ready(0.4, true), Result.answeredAfter(0.4, true))
        assertEquals(Result.Slow(3.4, true), Result.answeredAfter(3.4, true))
        assertEquals(Result.NotAnswering, Result.answeredAfter(null, false))
        assertEquals(Result.NotAnswering, Result.answeredAfter(9.0, true))
    }

    /** Dead relays are off so the import can't stall on them; a slow relay is
     *  only worth waiting for if it has their notes. */
    @Test fun defaultPicks() {
        assertTrue(Result.Ready(1.0, false).onByDefault)
        assertTrue(Result.Slow(3.0, true).onByDefault)
        assertFalse(Result.Slow(3.0, false).onByDefault)
        assertFalse(Result.NotAnswering.onByDefault)
        assertFalse(Result.Refused.onByDefault)
    }

    @Test fun summaryAndImportList() {
        val base = RelayCheck.rows(emptyList(), defaults)
        var rows = listOf(
            base[0].copy(isOn = true, result = Result.Ready(1.0, true)),
            base[1].copy(isOn = true, result = Result.Ready(1.0, true)),
            base[2].copy(result = Result.NotAnswering),
        )
        assertEquals("2 relays are ready to import from. 1 didn't answer, so we'll skip it.", RelayCheck.summary(rows))
        assertEquals(listOf("wss://relay.primal.net", "wss://nos.lol"), RelayCheck.importList(rows))
        rows = listOf(rows[0], rows[1].copy(result = Result.Refused, isOn = false), rows[2])
        assertEquals(
            "1 relay is ready to import from. 1 didn't answer, so we'll skip it. 1 won't share notes.",
            RelayCheck.summary(rows),
        )
        rows = rows.map { it.copy(isOn = false) }
        assertTrue(RelayCheck.summary(rows).startsWith("No relays"))
    }

    @Test fun normalize() {
        assertEquals("wss://relay.example.com", RelayCheck.normalize("relay.example.com"))
        assertEquals("wss://relay.example.com", RelayCheck.normalize(" wss://Relay.Example.com/ "))
        assertEquals("wss://r.example.com:7777/inbox", RelayCheck.normalize("wss://r.example.com:7777/inbox"))
        assertNull(RelayCheck.normalize("https://example.com"))
        assertNull(RelayCheck.normalize("not a relay"))
        assertNull(RelayCheck.normalize("localhost"))
    }

    /** relay.nostr.build answers kind-1 REQs with AUTH, then CLOSED
     *  "auth-required: …" (checked on iOS 2026-10-07). */
    @Test fun closedReasons() {
        assertEquals(Result.NeedsSignIn, RelayCheck.closedResult("auth-required: authenticate with AUTH before subscribing"))
        assertEquals(Result.Refused, RelayCheck.closedResult("ERROR: bad req: filter validation failed: kind not allowed: 1"))
        assertEquals(Result.Refused, RelayCheck.closedResult(null))
        assertFalse(Result.NeedsSignIn.canImport)
    }

    @Test fun labels() {
        assertEquals("Ready · 0.4s", Result.Ready(0.4, true).label)
        assertEquals("Slow · none of your notes found · 3.1s", Result.Slow(3.1, false).label)
    }
}
