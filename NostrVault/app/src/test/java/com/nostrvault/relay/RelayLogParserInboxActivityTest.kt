package com.nostrvault.relay

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The Vault tab's red dot needs the kind of what came in, to say where to
 * look. Mirrors iOS RelayLogParserInboxActivityTests (#476).
 */
class RelayLogParserInboxActivityTest {
    private fun kinds(vararg lines: String): Set<Int> {
        val batch = RelayLogParser.BatchedStateUpdate()
        for (line in lines) RelayLogParser.collectStateChanges(line, batch)
        return batch.inboxActivityKinds
    }

    /** Each phrase `logInboxImport` (haven-go/import.go) prints. */
    @Test fun `each import line reports its kind`() {
        assertEquals(setOf(1), kinds("2026/10/09 14:51:39 📰 new note in your inbox"))
        assertEquals(setOf(7), kinds("2026/10/09 14:51:39 🤙 new reaction in your inbox"))
        assertEquals(setOf(9735), kinds("2026/10/09 14:51:39 ⚡️ new zap in your inbox"))
        assertEquals(setOf(4), kinds("2026/10/09 14:51:39 🔒✉️ new encrypted message in your inbox"))
        assertEquals(setOf(1059), kinds("2026/10/09 14:51:39 🎁🔒️✉️ new gift-wrapped message in your chat relay"))
        assertEquals(setOf(6), kinds("2026/10/09 14:51:39 🔁 new repost in your inbox"))
        assertEquals(setOf(9802), kinds("2026/10/09 14:51:39 📦 new event kind 9802 event in your inbox"))
    }

    /** A reaction's content leads its line; a "new note" in it is not a note. */
    @Test fun `reaction content does not read as a note`() {
        assertEquals(setOf(7), kinds("2026/10/09 14:51:39 new note in your inbox new reaction in your inbox"))
    }

    @Test fun `own writes and other lines report nothing`() {
        assertEquals(
            emptySet<Int>(),
            kinds(
                "2026/10/09 14:51:39 event stored",
                "2026/10/09 14:51:39 blasted event to 12 relays",
                "2026/10/09 14:51:39 new note saved to outbox",
            ),
        )
    }

    @Test fun `a batch collects every kind`() {
        assertEquals(
            setOf(1, 9735),
            kinds("📰 new note in your inbox", "⚡️ new zap in your inbox", "📰 new note in your inbox"),
        )
    }
}
