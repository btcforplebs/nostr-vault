package com.nostrvault.service

import com.nostrvault.data.model.TrustMap
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** Nuclear unfollow + Private block (RESEARCH/NV_NUCLEAR_UNFOLLOW_SPEC.md, Logen 2026-11-19). Throwaway keys only. */
class NuclearUnfollowTest {
    private val me = "a".repeat(64)
    private val x = "b".repeat(64)
    private val f1 = "c".repeat(64)
    private val f2 = "d".repeat(64)
    private val keep = "e".repeat(64)

    private val tags = listOf(
        listOf("p", f1, "wss://relay.one", "Fi"),
        listOf("t", "nostr"),
        listOf("p", x),
        listOf("p", keep, "", "pal"),
        listOf("p", f2),
        listOf("client", "x"),
    )
    private val current = NostrEvent("cur", me, 100, 3, tags, "{\"wss://r\":{\"read\":true}}", "sig")

    @Test
    fun `always one warning, two from 25 people`() {
        assertEquals(1, NuclearUnfollow.warnings(1))
        assertEquals(1, NuclearUnfollow.warnings(24))
        assertEquals(2, NuclearUnfollow.warnings(25))
        assertEquals(2, NuclearUnfollow.warnings(400))
        assertEquals("Unfollow 1 person", NuclearUnfollow.firstWarning(1))
        assertEquals("Unfollow 25 people", NuclearUnfollow.firstWarning(25))
    }

    @Test
    fun `the list is them if followed, then your follows who follow them, never you`() {
        val follows = setOf(x, f1, f2, keep, me)
        assertEquals(listOf(x, f1, f2), NuclearUnfollow.people(x, listOf(f1, f2, me, f1), follows, me))
        // Not followed: only the bridges; a bridge you no longer follow is left out.
        assertEquals(listOf(f1), NuclearUnfollow.people(x, listOf(f1, "9".repeat(64)), setOf(f1), me))
    }

    @Test
    fun `only the picked follows go, every other tag stays in order`() {
        val out = NuclearUnfollow.tagsWithout(tags, setOf(x, f1, f2))
        assertEquals(listOf(listOf("t", "nostr"), listOf("p", keep, "", "pal"), listOf("client", "x")), out)
    }

    @Test
    fun `refuses with no one picked, no list, or no one still followed`() {
        assertTrue(NuclearUnfollow.refusal(current, emptySet())!!.contains("Nothing was changed"))
        assertTrue(NuclearUnfollow.refusal(null, setOf(x))!!.contains("wasn't found"))
        assertTrue(NuclearUnfollow.refusal(current, setOf("9".repeat(64)))!!.contains("don't follow"))
        assertNull(NuclearUnfollow.refusal(current, setOf(x)))
    }

    private class Steps(var newest: NostrEvent?, val keeps: Boolean) : ListVersionSave.Steps {
        val log = mutableListOf<String>()
        var signedTags: List<List<String>>? = null
        var signedContent: String? = null
        override fun activeAccount() = "a".repeat(64)
        override suspend fun newest() = Result.success(newest)
        override suspend fun keepUndoCopy(current: NostrEvent): Boolean { log += "backup"; return keeps }
        override suspend fun sign(kind: Int, content: String, tags: List<List<String>>, notBefore: Long): NostrEvent {
            log += "sign"; signedTags = tags; signedContent = content
            return NostrEvent("new", activeAccount(), notBefore, kind, tags, content, "sig")
        }
        override suspend fun store(signed: NostrEvent): Boolean { log += "store"; return true }
        override suspend fun send(signed: NostrEvent) { log += "send" }
    }

    @Test
    fun `backup first, then one list without them, content kept`() = runTest {
        val steps = Steps(current, keeps = true)
        var backedUp: ListVersion? = null
        val out = NuclearUnfollow.save(ListVersionSave(steps), me, "cur", setOf(x, f1, f2)) {
            steps.log += "backed up"; backedUp = it
        }
        assertTrue(out is ListVersionSave.Outcome.Saved)
        assertEquals(listOf("backup", "backed up", "sign", "store", "send"), steps.log)
        assertEquals("cur", backedUp!!.id)
        assertEquals(listOf(listOf("t", "nostr"), listOf("p", keep, "", "pal"), listOf("client", "x")), steps.signedTags)
        assertEquals(current.content, steps.signedContent)
    }

    @Test
    fun `no backup, no publish`() = runTest {
        val steps = Steps(current, keeps = false)
        var backedUp = false
        val out = NuclearUnfollow.save(ListVersionSave(steps), me, "cur", setOf(x)) { backedUp = true }
        assertTrue(out is ListVersionSave.Outcome.Refused)
        assertFalse(backedUp)
        assertFalse("sign" in steps.log || "send" in steps.log)
    }

    @Test
    fun `starts from the newest list, never an older one shown`() = runTest {
        val steps = Steps(current.copy(id = "newer", createdAt = 200), keeps = true)
        val out = NuclearUnfollow.save(ListVersionSave(steps), me, "cur", setOf(x)) { }
        assertTrue((out as ListVersionSave.Outcome.Refused).changed)
        assertFalse("sign" in steps.log)
    }

    @Test
    fun `a block keeps someone out of your web, whoever vouches for them`() {
        val web = setOf(x, f1, keep)
        assertEquals(setOf(f1, keep), TrustMap.withoutBlocked(web, setOf(x)))
        assertEquals(web, TrustMap.withoutBlocked(web, emptySet()))
    }

    /** The menu entries and the private path: Private block never goes in a public tag. */
    @Test
    fun `profile menu has both entries and Private block publishes privately`() {
        val root = File("src/main/java/com/nostrvault")
        val row = File(root, "ui/screens/profile/ProfileActionRow.kt").readText()
        assertTrue(row.contains("\"Nuclear unfollow\"") && row.contains("\"Private block\""))
        val helper = File(root, "service/PrivateBlock.kt").readText()
        assertTrue(helper.contains("privately = true"))
        val vm = File(root, "ui/screens/profile/ProfileViewModel.kt").readText()
        assertTrue(vm.contains("nostrService.blockPrivately(configStore, npub)"))
    }
}
