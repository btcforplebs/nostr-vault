package com.nostrvault.shareportal

import com.nostrvault.shareportal.ShareFixtures.str
import com.nostrvault.shareportal.ShareFixtures.strings
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ShareIntentTest {
    private val fixtures = ShareFixtures.load("envelope-cases.json")

    @Test fun everyValidFixtureDecodesAndRoundTrips() {
        val valid = fixtures["valid"]!!.jsonArray
        assertTrue(valid.isNotEmpty())
        for (c in valid) {
            val o = c.jsonObject
            val name = o.str("name")
            val intent = ShareIntent.decode(o["json"]!!)
            assertNotNull(name, intent)
            intent!!
            val expect = o["expect"]!!.jsonObject
            assertEquals(name, expect.str("action"), intent.action.raw)
            assertEquals(name, (expect["files"] as JsonPrimitive).content.toInt(), intent.files.size)
            assertEquals(name, expect["form_keys"]!!.strings(), intent.form.keys.sorted())
            val url = expect["url"].takeIf { it != JsonNull }?.let { (it as JsonPrimitive).content }
            assertEquals(name, url, intent.source.url)
            assertEquals(name, intent, ShareIntent.decode(intent.encode()))
        }
    }

    @Test fun everyInvalidFixtureIsRejected() {
        val invalid = fixtures["invalid"]!!.jsonArray
        assertTrue(invalid.size >= 15)
        val accepted = invalid.map { it.jsonObject }.filter { ShareIntent.decode(it["json"]!!) != null }.map { it.str("name") }
        assertEquals(emptyList<String>(), accepted)
    }

    @Test fun longSourceFieldsAreCutNotRejected() {
        val raw = """{"v":1,"id":"a","created_at":1,"action":"highlight","source":{"selection":"${"x".repeat(10_050)}","url":"https://e.com/${"p".repeat(5_000)}"}}"""
        val intent = ShareIntent.decode(raw)!!
        assertEquals(ShareIntent.MAX_SELECTION, intent.source.selection!!.length)
        assertEquals(ShareIntent.MAX_URL, intent.source.url!!.length)
    }

    @Test fun capDoesNotSplitASurrogatePair() {
        val s = "a".repeat(9) + "😀"   // the emoji is 2 UTF-16 units at 9..10
        assertEquals("a".repeat(9), ShareIntent.cap(s, 10))
    }

    @Test fun tooManyFilesOrFormKeysIsRejected() {
        val files = (0..20).joinToString(",") { """{"name":"f$it","mime":"x","path":"files/a/f$it","bytes":1}""" }
        assertNull(ShareIntent.decode("""{"v":1,"id":"a","created_at":1,"action":"dm","files":[$files]}"""))
        val form = (0..32).joinToString(",") { "\"k$it\":\"v\"" }
        assertNull(ShareIntent.decode("""{"v":1,"id":"a","created_at":1,"action":"dm","form":{$form}}"""))
    }

    @Test fun ldTypesAreCapped() {
        val types = (0..30).joinToString(",") { "\"T$it\"" }
        val intent = ShareIntent.decode("""{"v":1,"id":"a","created_at":1,"action":"recipe","source":{"ld_types":[$types]}}""")!!
        assertEquals(ShareIntent.MAX_LD_TYPES, intent.source.ldTypes.size)
    }

    @Test fun staleAfterAWeek() {
        val i = ShareIntent("a", createdAt = 0, action = ShareAction.HIGHLIGHT)
        assertTrue(i.isStale(ShareIntent.STALE_AFTER_SECONDS + 1))
        assertTrue(!i.isStale(ShareIntent.STALE_AFTER_SECONDS))
    }
}
