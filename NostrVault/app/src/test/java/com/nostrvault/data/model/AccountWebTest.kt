package com.nostrvault.data.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * The open account's web, not the device's accounts pooled (Logen 2026-11-13,
 * "hop 3 spam"): the relay's saved web narrowed with its wot_links.json.
 */
class AccountWebTest {
    private fun pk(c: Char) = c.toString().repeat(64)
    private val me = pk('a')
    private val other = pk('b') // another account on this device
    private val f1 = pk('1'); private val f2 = pk('2'); private val f3 = pk('3')
    private val g1 = pk('4'); private val g2 = pk('5'); private val g3 = pk('6') // other's follows
    private val spammer = pk('9')
    private val friend = pk('8')

    /** The relay's links: follows sorted, each person's vouchers as indexes. */
    private fun links(follows: List<String>, people: Map<String, List<String>>): String {
        val sorted = follows.sorted()
        val entries = people.entries.joinToString(",") { (p, by) ->
            "\"$p\":[" + by.map { sorted.indexOf(it) }.sorted().joinToString(",") + "]"
        }
        return "{\"timestamp\":1794566000,\"follows\":[" + sorted.joinToString(",") { "\"$it\"" } + "],\"links\":{" + entries + "}}"
    }

    private val pooledFollows = listOf(f1, f2, f3, g1, g2, g3)
    private val saved = setOf(me, other, f1, f2, f3, g1, g2, g3, spammer, friend)
    private val file = links(
        pooledFollows,
        mapOf(
            // Only the other account's follows vouch for the spammer.
            spammer to listOf(g1, g2, g3),
            // Three of mine do for the friend.
            friend to listOf(f1, f2, f3, g1),
            g1 to listOf(f1),
        ),
    )

    private fun narrow(follows: Set<String>, text: String? = file, min: Int = 3, depth: Int? = 3) =
        AccountWeb.narrow(saved, text?.reader(), depth, follows, setOf(me, other), min)

    @Test fun `someone only another account's follows vouch for is out`() {
        val web = narrow(setOf(f1, f2, f3))
        assertEquals(false, spammer in web)
        assertEquals(true, friend in web)
    }

    @Test fun `the other account's follows aren't this account's web`() {
        val web = narrow(setOf(f1, f2, f3))
        assertEquals(setOf(me, other, f1, f2, f3, friend), web)
    }

    @Test fun `the other account still sees its own web`() {
        val web = narrow(setOf(g1, g2, g3))
        assertEquals(true, spammer in web)
        assertEquals(false, friend in web) // only g1 of its follows vouches
    }

    @Test fun `an unfollow drops who it vouched for at once`() {
        val follows = setOf(f1, f2, f3, pk('7'))
        assertEquals(true, friend in narrow(follows))
        // f3 unfollowed: two of the four follows left vouch, under the bar of 3.
        assertEquals(false, friend in narrow(follows - f3))
    }

    @Test fun `min followers counts only this account's follows`() {
        val follows = setOf(f1, f2, f3, g1, pk('7'))
        assertEquals(true, friend in narrow(follows, min = 4))
        assertEquals(false, friend in narrow(follows, min = 5))
        // g1 is the spammer's only voucher among these follows.
        assertEquals(false, spammer in narrow(follows, min = 2))
        assertEquals(true, spammer in narrow(follows, min = 1))
    }

    @Test fun `bar is min followers, 0 and 1 both one`() {
        assertEquals(3, AccountWeb.bar(3))
        assertEquals(1, AccountWeb.bar(0))
        assertEquals(1, AccountWeb.bar(1))
    }

    @Test fun `an account following fewer people than the bar keeps the saved web`() {
        assertEquals(saved, narrow(setOf(f1, f2)))
    }

    @Test fun `depth 2 is follows and own accounts only`() {
        assertEquals(setOf(me, other, f1, f2, f3), narrow(setOf(f1, f2, f3), text = null, depth = 2))
        // A stale links file from an earlier depth 3 is ignored.
        assertEquals(setOf(me, other, f1, f2, f3), narrow(setOf(f1, f2, f3), depth = 2))
    }

    @Test fun `depth 3 with no links file keeps the saved web, as an older relay`() {
        assertEquals(saved, narrow(setOf(f1, f2, f3), text = null))
    }

    @Test fun `other or unknown depths keep the saved web`() {
        assertEquals(saved, narrow(setOf(f1, f2, f3), depth = 4))
        assertEquals(saved, narrow(setOf(f1, f2, f3), depth = null))
    }

    @Test fun `a repeated voucher counts once`() {
        val text = links(pooledFollows, mapOf(spammer to listOf(f1, f1, f1)))
        assertEquals(false, spammer in narrow(setOf(f1, f2, f3), text = text))
    }

    @Test fun `follows not loaded yet keep the saved web`() {
        assertEquals(saved, narrow(emptySet()))
    }

    @Test fun `an unreadable links file keeps the saved web`() {
        assertEquals(saved, narrow(setOf(f1), text = "{\"links\":{}}", min = 1))
        assertEquals(saved, narrow(setOf(f1), text = "not json", min = 1))
        assertEquals(saved, narrow(setOf(f1), text = "{\"follows\":[\"$f1\"],\"links\":{\"$friend\":[0", min = 1))
    }

    @Test fun `vouched reads empty lists, unknown keys and whitespace`() {
        val text = """
            { "timestamp": 12, "extra": {"a":[1,2,{"b":null}],"c":true},
              "follows": [ "$f1", "$f2" ],
              "links": { "$friend": [ 0 , 1 ], "$spammer": [] } }
        """.trimIndent()
        assertEquals(setOf(friend), AccountWeb.vouched(text.reader(), setOf(f1, f2), 2))
        assertNull(AccountWeb.vouched("{\"links\":{},\"follows\":[]}".reader(), setOf(f1), 1))
        assertEquals(emptySet<String>(), AccountWeb.vouched("{\"follows\":[],\"links\":{}}".reader(), setOf(f1), 1))
    }
}
