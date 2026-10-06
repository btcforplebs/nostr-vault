package com.nostrvault.relay

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Date

/** Same cases as PlainLogTests.swift: both platforms must say the same thing. */
class PlainLogTest {
    private val hex = "ab".repeat(32)
    private fun entry(line: String) = RelayLogParser.LogEntry.parse(line)

    @Test
    fun `noise is dropped`() {
        listOf(
            "2026/10/05 10:00:00 http: TLS handshake error from 192.168.1.20:51234: EOF",
            "badger 2026/10/05 10:00:00 INFO: Set nextTxnTs to 42",
            "  \"AllowEmptyFilters\": true,",
            "{",
            "🔔NOTIFY|type=reaction|kind=7|author=$hex|id=$hex|recipient=$hex|",
            "WARN negentropy sync failed, plain catch-up this round relay=wss://relay.example.com err=\"x\"",
            "INFO event stored",
        ).forEach { line ->
            val e = entry(line)
            assertNull(line, PlainLog.translate(e.level, e.message))
        }
    }

    @Test
    fun `remote relay failures group per host`() {
        val line = "2026/10/05 10:00:00 ERROR error connecting to relay relay=wss://relay.damus.io error=\"failed to connect\""
        val items = PlainLog.summarize(listOf(entry(line), entry(line), entry(line)))
        assertEquals(1, items.size)
        assertEquals(3, items[0].count)
        assertEquals(PlainLog.Severity.HEADS_UP, items[0].severity)
        assertEquals("Couldn't reach relay.damus.io", items[0].title)
    }

    @Test
    fun `members only relay`() {
        val e = entry("2026/10/05 10:00:00 ERROR error publishing to relay relay=wss://nostr.wine error=\"msg: restricted: sign up at https://nostr.wine\"")
        assertEquals("nostr.wine only accepts posts from its members", PlainLog.translate(e.level, e.message)?.title)
    }

    @Test
    fun `locked database is a problem`() {
        val e = entry("2026/10/05 10:00:00 ERROR Cannot acquire directory lock on \"/data/user/0/x/db\"")
        assertEquals(PlainLog.Severity.PROBLEM, PlainLog.translate(e.level, e.message)?.severity)
    }

    @Test
    fun `unknown error surfaces scrubbed, unknown info hidden`() {
        val msg = PlainLog.translate("ERROR", "boom for npub1sg6plzptd64u62a878hep2kev88swjh3tw00gjsfl8f237lmu63q0uf63m at /data/user/0/x")!!
        assertEquals(PlainLog.Severity.PROBLEM, msg.severity)
        assertFalse(msg.title.contains("npub1"))
        assertFalse(msg.title.contains("/data/user"))
        assertNull(PlainLog.translate("INFO", "something routine happened"))
    }

    @Test
    fun `repeat moves to end`() {
        val a = entry("new note in your inbox")
        val b = entry("new zap in your inbox")
        val items = PlainLog.summarize(listOf(a, b, a))
        assertEquals(listOf("new-zap", "new-mention"), items.map { it.key })
        assertEquals(2, items.last().count)
    }

    @Test
    fun `health ignores problems before last start`() {
        val t0 = Date(0)
        val problem = PlainLog.Item("db-locked", PlainLog.Severity.PROBLEM, "", null, 1, t0, t0)
        val up = PlainLog.Item("running", PlainLog.Severity.GOOD, "", null, 1, t0, Date(10_000))
        assertEquals(PlainLog.Severity.GOOD, PlainLog.health(listOf(problem, up)))
        assertEquals(PlainLog.Severity.PROBLEM, PlainLog.health(listOf(problem)))
    }

    @Test
    fun `scrub removes secrets and keeps relay hosts`() {
        val raw = "nsec1vl029mgpspedva04g90vltkh6fvh240zqtv9k0t9af8935ke9laqsnlfe5 " +
            "npub1sg6plzptd64u62a878hep2kev88swjh3tw00gjsfl8f237lmu63q0uf63m " +
            "id=$hex from 10.0.0.12:4869 and [fe80::1c2b:3cff:fe4d:5e6f]:443 " +
            "me@example.com /data/user/0/com.nostrvault/x.db " +
            "nostr+walletconnect://abc?relay=wss://r.example&secret=$hex " +
            "https://cdn.example.com/u/abc.jpg?token=SECRET wss://relay.damus.io/path " +
            "wss://abcdefghijklmnop.onion ws://haven.local:3355 wss://box.tail1234.ts.net ws://localhost:4869"
        val out = PlainLog.scrub(raw)
        listOf("nsec1", "npub1", hex, "10.0.0.12", "fe80", "me@example.com", "/data/user",
            "walletconnect", "SECRET", "abc.jpg", "/path",
            "abcdefghijklmnop", "haven.local", "tail1234", "localhost").forEach {
            assertFalse("leaked $it in: $out", out.contains(it))
        }
        assertTrue(out.contains("wss://relay.damus.io"))
        assertTrue(out.contains("https://cdn.example.com"))
        assertTrue(out.contains("wss://[private-relay]"))
    }

    @Test
    fun `export has no raw lines`() {
        val items = PlainLog.summarize(listOf(
            entry("2026/10/05 10:00:00 ERROR boom npub1sg6plzptd64u62a878hep2kev88swjh3tw00gjsfl8f237lmu63q0uf63m"),
            entry("listening at https://192.168.1.5:4869"),
        ))
        val text = PlainLog.exportText(items, header = listOf("App: 2.7.2 (19)"))
        assertTrue(text.contains("Relay is running"))
        assertTrue(text.contains("App: 2.7.2 (19)"))
        assertFalse(text.contains("npub1"))
        assertFalse(text.contains("192.168"))
    }
}
