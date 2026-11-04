package com.nostrvault.service

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The wipe alarm (docs/LIST_WIPE_ALARM.md) against the cases the iOS and web
 * tests read too: `Fixtures/ListAlarm/alarm-cases.json`.
 */
class ListWipeAlarmRuleTest {
    private val fixture: JsonObject by lazy {
        val text = javaClass.classLoader!!.getResource("alarm-cases.json")!!.readText()
        Json.parseToJsonElement(text).jsonObject
    }

    private fun version(o: JsonObject) = ListVersion(
        id = o["id"]!!.jsonPrimitive.content,
        pubkey = "owner",
        kind = o["kind"]!!.jsonPrimitive.int,
        createdAt = o["created_at"]!!.jsonPrimitive.long,
        tags = o["tags"]!!.jsonArray.map { t -> t.jsonArray.map { it.jsonPrimitive.content } },
        content = o["content"]!!.jsonPrimitive.content,
    )

    @Test
    fun theRuleMatchesEverySharedCase() {
        val rule = fixture["rule"]!!.jsonObject
        assertEquals(ListWipeAlarmRule.MIN_ITEMS, rule["min_items"]!!.jsonPrimitive.int)
        assertEquals(ListWipeAlarmRule.MIN_CONTENT, rule["min_content"]!!.jsonPrimitive.int)
        assertEquals(ListWipeAlarmRule.LOOKBACK, rule["lookback"]!!.jsonPrimitive.int)
        assertEquals(ListWipeAlarmRule.ALARM_MIN_ITEMS, rule["alarm_min_items"]!!.jsonPrimitive.int)
        val cases = fixture["cases"]!!.jsonArray
        assertTrue("the fixture has its cases", cases.size >= 20)
        var alarms = 0
        for (c in cases) {
            val o = c.jsonObject
            val name = o["name"]!!.jsonPrimitive.content
            val versions = o["versions"]!!.jsonArray.map { version(it.jsonObject) }
            val own = o["own"]!!.jsonArray.map { it.jsonPrimitive.content }.toSet()
            val dismissed = o["dismissed"]!!.jsonArray.map { it.jsonPrimitive.content }.toSet()
            val got = ListWipeAlarmRule.alarm(versions, own, dismissed)
            val want = o["expect"]!!
            if (want is JsonNull) {
                assertNull(name, got)
                continue
            }
            alarms++
            val w = want.jsonObject
            assertTrue("$name: expected an alarm", got != null)
            got!!
            assertEquals(name, w["before"]!!.jsonPrimitive.content, got.before.id)
            assertEquals(name, w["after"]!!.jsonPrimitive.content, got.after.id)
            assertEquals(name, w["how"]!!.jsonPrimitive.content, got.how.wire)
            assertEquals(name, w["from"]!!.jsonPrimitive.int, got.from)
            assertEquals(name, w["to"]!!.jsonPrimitive.int, got.to)
            assertEquals(name, w["lost"]!!.jsonPrimitive.int, got.lost)
            val client = w["client"]!!.let { if (it is JsonNull) null else it.jsonPrimitive.content }
            assertEquals(name, client, got.client)
        }
        assertTrue("the fixture alarms too, not only stays quiet", alarms >= 8)
    }

    @Test
    fun ownEditsLedgerKeepsTheNewestOnceAndCaps() {
        assertEquals("an id appended again moves to the end, once", listOf("a", "b"), OwnListEdits.appended(listOf("b", "a"), "b"))
        val full = (1..OwnListEdits.KEEP).map { "id$it" }
        val next = OwnListEdits.appended(full, "new")
        assertEquals(OwnListEdits.KEEP, next.size)
        assertEquals("new", next.last())
        assertFalse("the oldest goes", "id1" in next)
    }

    @Test
    fun watcherReadsOnlyTheListVersionMarker() {
        val author = "a".repeat(64)
        val line = "🔔NOTIFY|type=listversion|kind=3|author=$author|id=x|recipient=$author|preview="
        assertTrue(ListWipeWatcher.isMarker(line))
        assertEquals(author, ListWipeWatcher.authorOf(line))
        assertFalse("an inbox marker is not ours", ListWipeWatcher.isMarker("🔔NOTIFY|type=mention|kind=1|author=$author|id=x|preview=hi"))
        assertNull("a bad author is refused", ListWipeWatcher.authorOf("🔔NOTIFY|type=listversion|kind=3|author=xyz|id=x|preview="))
        assertNull("type=listversion in a preview is not the marker",
            ListWipeWatcher.authorOf("🔔NOTIFY|type=mention|kind=1|author=$author|id=x|preview=type=listversion|"))
    }

    @Test
    fun wordingFollowsHowAndNamesTheApp() {
        fun v(id: String, n: Int, content: String = "", kind: Int = 3) =
            ListVersion(id, "o", kind, 1, (0 until n).map { listOf("p", "p$it") }, content)
        val emptied = ListWipeAlarmRule.Alarm(v("b", 40), v("a", 0), ListWipeAlarmRule.How.EMPTIED, 40, 0, 40, "Amethyst")
        assertEquals("Your follows was emptied", ListWipeAlarmText.notificationTitle(emptied, "follows"))
        assertEquals("Changed by Amethyst. Tap to recover.", ListWipeAlarmText.notificationBody(emptied))
        assertEquals("Your follows went from 40 to 0 on 4 Nov.", ListWipeAlarmText.headline(emptied, "follows", "4 Nov"))
        val swapped = emptied.copy(how = ListWipeAlarmRule.How.SWAPPED, to = 40, lost = 40, client = null)
        assertEquals("Your follows: 40 of 40 entries were swapped for others on 4 Nov.", ListWipeAlarmText.headline(swapped, "follows", "4 Nov"))
        assertEquals("Changed by an app that didn't name itself. Tap to recover.", ListWipeAlarmText.notificationBody(swapped))
        assertEquals("Your follows lost 40 entries", ListWipeAlarmText.notificationTitle(swapped, "follows"))
        val drained = emptied.copy(how = ListWipeAlarmRule.How.DRAINED, to = 5, lost = 35)
        assertEquals("Your follows went from 40 to 5 in a few steps, the last on 4 Nov.", ListWipeAlarmText.headline(drained, "follows", "4 Nov"))
        val privatePart = ListWipeAlarmRule.Alarm(v("b", 0, "x".repeat(3000), 10000), v("a", 0, "", 10000),
            ListWipeAlarmRule.How.EMPTIED, 0, 0, 0, null)
        assertEquals("The private part of your mutes was emptied on 4 Nov.", ListWipeAlarmText.headline(privatePart, "mutes", "4 Nov"))
    }
}
