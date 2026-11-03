package com.nostrvault.shareportal

import com.nostrvault.shareportal.ShareFixtures.str
import com.nostrvault.shareportal.ShareFixtures.strings
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

/** Lane D's recent-recipients snapshot, read from the same fixture as the Swift tests (contacts-cases.json). */
class ShareContactsSnapshotTest {
    @get:Rule val tmp = TemporaryFolder()
    private val fixture = ShareFixtures.load("contacts-cases.json")

    @Test fun decodeMatchesSharedFixtures() {
        fixture["decode"]!!.jsonArray.forEach { c ->
            val o = c.jsonObject
            val raw = o.str("raw") ?: o["json"].toString()
            val got = ShareContactsSnapshot.decode(raw)
            val expect = o["expect"]
            if (expect == null || expect is JsonNull) {
                assertNull(o.str("name"), got)
            } else {
                val want = (expect as JsonObject).mapValues { it.value.strings() }
                assertEquals(o.str("name"), want, got!!.recent.mapValues { e -> e.value.map { it.npub } })
            }
        }
    }

    @Test fun recordMatchesSharedFixtures() {
        val account = fixture.str("account")!!
        fixture["record"]!!.jsonArray.forEach { c ->
            val o = c.jsonObject
            val start = o["start"]!!.strings().map { ShareContactsSnapshot.Contact(it, "") }
            val s = ShareContactsSnapshot(mapOf(account to start))
            val got = s.recording(ShareContactsSnapshot.Contact(o.str("add")!!, "n"), account).contacts(account).map { it.npub }
            assertEquals(o.str("name"), o["expect"]!!.strings(), got)
        }
    }

    @Test fun writeReadAndKeepOnlyListedAccounts() {
        val a = "npub1" + "q".repeat(58)
        val b = "npub1" + "p".repeat(58)
        val c = ShareContactsSnapshot.Contact(b, "Bee")
        val s = ShareContactsSnapshot().recording(c, a).recording(c, b)
        val file = File(tmp.root, "share_portal/contacts.json")
        assertTrue(ShareContactsSnapshot.write(file, s))
        assertEquals(s, ShareContactsSnapshot.read(file))
        assertEquals(setOf(a), s.keeping(setOf(a)).recent.keys)
        assertTrue(ShareContactsSnapshot().contacts(null).isEmpty())
    }
}
