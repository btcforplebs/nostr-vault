package com.nostrvault.fips

import com.nostrvault.fips.CopyAccounts.Account
import com.nostrvault.fips.MeshCopyFixtures.obj
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The accounts a copy brings over (contract §3.4): Tal's fixtures from docs/fixtures/mesh-copy, as the engine and
 * iOS CopyAccountsTests read them, and this app's side of the ask (offered, never added unasked).
 */
class CopyAccountsTest {
    private val owner = "npub1fsgzj6t7udv8zhf6zj32mkqhcjcpv52yph5qsdcl0qt94jgdckqs4yjc3w"
    private val other = "npub13evkv42fprxqfpqdp966kn2cwpjrk9jflp08yelkkue20g977wpsv6pcap"
    private val third = "npub1ks0t9yldwmqlr2k8jnm25gs92za45mp5rhwtkk0r0wlz9wg688zs99ny60"
    private val nsec = "nsec19uqxr6xazkeed24thcl9gwl8e5alzdtma8enxekqkv3ux3m9ty3qqp49sa"

    private fun hex(npub: String) = MeshPairing.npubHex(npub)!!

    private fun accounts(el: JsonElement?): List<Account> = (el as? JsonArray).orEmpty().map {
        val o = it.obj()
        Account(o["npub"]!!.jsonPrimitive.content, o["name"]?.jsonPrimitive?.contentOrNull.orEmpty())
    }

    private fun code(c: CopyAccounts.Checked) = (c as? CopyAccounts.Checked.Refused)?.refusal?.code ?: ""

    @Test
    fun `every refuse case matches the engine`() {
        val cases = MeshCopyFixtures.json("accounts-refuse-cases.json")["cases"]!!.jsonArray.map { it.obj() }
        assertTrue(cases.size > 15)
        for (c in cases) {
            val name = c["name"]!!.jsonPrimitive.content
            assertEquals(name, c["expect"]!!.jsonPrimitive.content, code(CopyAccounts.check(c["file"]!!.toString())))
        }
    }

    @Test
    fun `merge and shares match the engine`() {
        val f = MeshCopyFixtures.json("accounts-merge-cases.json")
        for (c in f["merge"]!!.jsonArray.map { it.obj() }) {
            assertEquals(c["name"]!!.jsonPrimitive.content, accounts(c["expect"]), CopyAccounts.merge(accounts(c["mine"]), accounts(c["theirs"])))
        }
        for (c in f["shares"]!!.jsonArray.map { it.obj() }) {
            val mine = c["mine"]!!.jsonArray.map { it.jsonPrimitive.content }.toSet()
            val theirs = c["theirs"]!!.jsonArray.map { it.jsonPrimitive.content }
            assertEquals(c["name"]!!.jsonPrimitive.content, c["expect"]!!.jsonPrimitive.boolean, CopyAccounts.shares(mine, theirs))
        }
    }

    @Test
    fun `fields of the wrong type are refused, not read`() {
        assertEquals("unknown_key", code(CopyAccounts.check("""{"v":"1","accounts":[{"npub":"$owner"}]}""")))
        assertEquals("unknown_key", code(CopyAccounts.check("""{"v":true,"accounts":[{"npub":"$owner"}]}""")))
        assertEquals("unknown_key", code(CopyAccounts.check("""{"v":1,"accounts":[{"npub":"$owner","name":5}]}""")))
        assertEquals("unknown_key", code(CopyAccounts.check("""[{"npub":"$owner"}]""")))
        assertEquals("bad_version", code(CopyAccounts.check("not json")))
        assertEquals("", code(CopyAccounts.check("""{"v":1,"accounts":[{"npub":"$owner","name":null}]}""")))
    }

    // ---- The file this app writes ----

    @Test
    fun `own file keeps what a copy brought, own names win, and it passes the check`() {
        val existing = listOf(Account(owner, "Old"), Account(other, "Other"))
        val next = CopyAccounts.ownFile(listOf(Account(owner, "Owner")), existing)
        assertEquals(listOf(Account(owner, "Owner"), Account(other, "Other")), next)
        // An own account with no name yet keeps the one in the file.
        assertEquals("Old", CopyAccounts.ownFile(listOf(Account(owner)), existing).first().name)
        val json = CopyAccounts.fileJson(next, 1767000000)!!
        assertEquals(CopyAccounts.Checked.Ok(next), CopyAccounts.check(json))
    }

    @Test
    fun `the file never carries a key`() {
        assertNull(CopyAccounts.fileJson(listOf(Account(owner, nsec)), 1))
        assertNull(CopyAccounts.fileJson(listOf(Account(hex(owner))), 1))
        assertNull(CopyAccounts.fileJson(listOf(Account(owner, "bunker://relay.example?secret=x")), 1))
        assertNull(CopyAccounts.addJson(listOf(Account(nsec)), 1))
        assertNull(CopyAccounts.addJson(emptyList(), 1))
        // A name that reads as a key is left out rather than refusing the whole file.
        assertEquals("", CopyAccounts.cleanName(nsec))
        assertEquals("", CopyAccounts.cleanName("x" + "a".repeat(64)))
        assertEquals("Logen", CopyAccounts.cleanName("  Logen "))
        assertEquals(CopyAccounts.NAME_MAX, CopyAccounts.cleanName("n".repeat(200)).length)
    }

    // ---- The ask ----

    @Test
    fun `offered is what this device lacks and was never asked about`() {
        val file = listOf(Account(owner), Account(other, "Other"), Account(third), Account(other))
        assertEquals(listOf(Account(other, "Other")), CopyAccounts.offered(file, setOf(hex(owner)), setOf(hex(third))))
        assertEquals(listOf(other, third), CopyAccounts.offered(file, setOf(hex(owner)), emptySet()).map { it.npub })
        assertTrue(CopyAccounts.offered(file, setOf(hex(owner), hex(other), hex(third)), emptySet()).isEmpty())
    }

    @Test
    fun `an answer settles every offered account and adds only the ticked`() {
        val offered = listOf(Account(other, "Other"), Account(third))
        val a = CopyAccounts.answer(offered, listOf(third))
        assertEquals(setOf(hex(other), hex(third)), a.settle)
        assertEquals(listOf(Account(third)), a.add)
        // Just this one: all settled, none added.
        assertEquals(CopyAccounts.Answer(setOf(hex(other), hex(third)), emptyList()), CopyAccounts.answer(offered, emptyList()))
        // A tick for something never offered adds nothing.
        assertTrue(CopyAccounts.answer(offered, listOf(owner)).add.isEmpty())
    }

    @Test
    fun `the AddAccountsC JSON is the file shape with only the ticked`() {
        val json = CopyAccounts.addJson(listOf(Account(other, "Other")), 1767000000)!!
        val o = Json.parseToJsonElement(json) as JsonObject
        assertEquals(1, o["v"]!!.jsonPrimitive.content.toInt())
        assertEquals(listOf(Account(other, "Other")), accounts(o["accounts"]))
        assertEquals(setOf("v", "updated_at", "accounts"), o.keys)
        assertFalse("nsec" in json || "bunker" in json)
    }
}
