package com.nostrvault.relay

import android.content.Context
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.fips.CopySettings
import io.mockk.every
import io.mockk.mockk
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files

/** Each account has its own Follow Distance and Minimum Followers. Twin of Apple AccountReachTests. */
class AccountReachTest {
    private val owner = "npub1sg6plzptd64u62a878hep2kev88swjh3tw00gjsfl8f237lmu63q0uf63m"
    private val alt = "npub1gcxzte5zlkncx26j68ez60fzkvtkm9e0vrwdcvsjakxf9mu9qewqlfnj5z"
    private val third = "npub15ltk3g7wjmt0sjqk78cjv4mtttmy8ffyy9g7hg7spxwdz28wr2wszsrurl"
    private val dir = File("/tmp/x")

    private fun config() = HavenConfig(
        ownerNpub = owner, accountNpubs = listOf(alt, third), chatRelayWotDepth = 3, chatRelayMinFollowers = 3,
    )

    /** Nothing to convert: before anyone changes anything, every account runs on the value the device already had. */
    @Test fun `every account starts on the old single value`() {
        val c = config()
        for (npub in listOf(owner, alt, third, "")) assertEquals(npub, AccountReach(3, 3), c.reachFor(npub))
        assertTrue("no entry is written until an account gets its own", c.relayAccountReach.isEmpty())
    }

    @Test fun `changing one account leaves the others alone`() {
        val c = config().withReach(AccountReach(1, 0), alt)
        assertEquals(AccountReach(1, 0), c.reachFor(alt))
        assertEquals(AccountReach(3, 3), c.reachFor(owner))
        assertEquals(AccountReach(3, 3), c.reachFor(third))
        assertEquals("the first account's stored value did not move", 3, c.chatRelayWotDepth)
        assertEquals(mapOf(alt to AccountReach(1, 0)), c.relayAccountReach)
    }

    /** The first account's value is the old stored pair, which other accounts with no entry also read. */
    @Test fun `changing the first account leaves the others alone`() {
        val c = config().withReach(AccountReach(2, 3), alt).withReach(AccountReach(1, 7), owner)
        assertEquals(AccountReach(1, 7), c.reachFor(owner))
        assertEquals(1, c.chatRelayWotDepth)
        assertEquals(7, c.chatRelayMinFollowers)
        assertEquals("alt keeps the value it chose", AccountReach(2, 3), c.reachFor(alt))
        assertEquals("third had no entry and keeps the value it ran on", AccountReach(3, 3), c.reachFor(third))
    }

    @Test fun `setting the first account to the value it has changes nothing`() {
        val c = config()
        assertSame(c, c.withReach(AccountReach(3, 3), owner))
    }

    @Test fun `the screen shows the account you are on`() {
        var c = config().withReach(AccountReach(1, 0), alt)
        assertEquals("no account picked means the first", owner, c.reachAccountNpub)
        assertEquals(3, c.reachFor(c.reachAccountNpub).depth)
        c = c.copy(activeAccountNpub = alt)
        assertEquals(1, c.reachFor(c.reachAccountNpub).depth)
    }

    @Test fun `values are held to what the screen offers`() {
        var c = config().withReach(AccountReach(9, 500), alt)
        assertEquals(AccountReach(3, 100), c.reachFor(alt))
        c = c.withReach(AccountReach(0, -4), alt)
        assertEquals("level 0 is a public relay and is never an account's level", AccountReach(1, 0), c.reachFor(alt))
    }

    @Test fun `an entry for an account no longer here is not sent`() {
        val c = config().copy(reachPerAccount = mapOf("npub1gone" to AccountReach(1, 0), owner to AccountReach(1, 0)))
        assertTrue(c.relayAccountReach.isEmpty())
    }

    @Test fun `removing an account drops its value`() = runBlocking {
        val filesDir = Files.createTempDirectory("account-reach").toFile()
        try {
            val context = mockk<Context> { every { this@mockk.filesDir } returns filesDir }
            val store = ConfigStore(context).apply { reload(); update { config().withReach(AccountReach(1, 0), alt) } }
            store.removeAccount(alt)
            assertNull(store.config.value.reachPerAccount[alt])
            assertTrue(store.config.value.relayAccountReach.isEmpty())
        } finally {
            filesDir.deleteRecursively()
        }
    }

    @Test fun `saved config keeps each account's value and an older file still opens`() {
        val json = Json { ignoreUnknownKeys = true }
        val c = config().withReach(AccountReach(2, 5), alt)
        val text = json.encodeToString(HavenConfig.serializer(), c)
        assertEquals(AccountReach(2, 5), json.decodeFromString(HavenConfig.serializer(), text).reachFor(alt))

        val older = JsonObject(json.parseToJsonElement(text).jsonObject - "reachPerAccount")
        val back = json.decodeFromString(HavenConfig.serializer(), older.toString())
        assertTrue(back.reachPerAccount.isEmpty())
        assertEquals(AccountReach(3, 3), back.reachFor(alt))
    }

    /** What the relay is handed: the file named in its environment, in the shape haven-go/account_reach.go parses. */
    @Test fun `the relay is handed each account's value`() {
        val c = config().withReach(AccountReach(2, 5), alt).withReach(AccountReach(1, 3), owner)
        val inputs = RelayConfiguration.launchInputs(c, dir)
        assertEquals(AccountReach.FILE_NAME, inputs.env["ACCOUNT_REACH_FILE"])
        assertEquals("1", inputs.env["WOT_DEPTH"])
        assertEquals("3", inputs.env["WOT_MINIMUM_FOLLOWERS"])

        val file = Json.parseToJsonElement(AccountReach.fileJson(inputs.accountReach)).jsonObject
        assertEquals(1, file["v"]!!.jsonPrimitive.int)
        val accounts = file["accounts"]!!.jsonObject.mapValues { (_, v) -> v.jsonObject.mapValues { it.value.jsonPrimitive.int } }
        assertEquals(
            mapOf(alt to mapOf("depth" to 2, "min_followers" to 5), third to mapOf("depth" to 3, "min_followers" to 3)),
            accounts,
        )

        // A change to one account's value changes what the relay starts with, so the app restarts it.
        val changed = c.withReach(AccountReach(3, 5), alt)
        assertNotEquals(inputs, RelayConfiguration.launchInputs(changed, dir))
    }

    @Test fun `an empty file still names the version`() {
        assertEquals("""{"v":1,"accounts":{}}""", AccountReach.fileJson(emptyMap()))
    }

    /** The names the relay reads, from its own source. */
    @Test fun `the file matches what the relay reads`() {
        val root = generateSequence(File("").absoluteFile) { it.parentFile }.first { File(it, "haven-go/account_reach.go").exists() }
        val go = File(root, "haven-go/account_reach.go").readText()
        val conf = File(root, "haven-go/config.go").readText()
        for (name in listOf("`json:\"v\"`", "`json:\"accounts\"`", "`json:\"depth\"`", "`json:\"min_followers\"`")) {
            assertTrue("haven-go no longer reads $name", go.contains(name))
        }
        assertTrue(conf.contains("getEnvString(\"ACCOUNT_REACH_FILE\""))
    }

    /** Settings copied from another of your devices carry the first account's level; the other accounts keep theirs. */
    @Test fun `copied settings move only the first account`() {
        val c = config().withReach(AccountReach(2, 3), alt)
        val applied = CopySettings.apply(c, JsonObject(mapOf("wot_depth" to JsonPrimitive(1))))
        assertEquals(1, applied.reachFor(owner).depth)
        assertEquals(2, applied.reachFor(alt).depth)
        assertEquals(3, applied.reachFor(third).depth)
    }
}
