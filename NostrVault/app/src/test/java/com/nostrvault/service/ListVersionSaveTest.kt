package com.nostrvault.service

import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The one safe save a restore and a merge go through: refuses a list that changed since it was shown or can't be
 * checked, signs nothing when the undo copy can't be kept, refuses a signer that signs as another account or an
 * account switch, sends nothing the vault refused, and dates the new version after the one it replaces.
 * Web twin: web-vault/test/list-merge-save.test.mjs.
 */
class ListVersionSaveTest {
    private val me = "a".repeat(64)
    private val base = NostrEvent("base", me, 100, 10003, listOf(listOf("e", "1")), "", "sig")

    private class Fake(
        var newest: Result<NostrEvent?>,
        var active: String,
        var keeps: Boolean = true,
        var stores: Boolean = true,
        var signAs: String? = null,
        val switchOnSign: String? = null,
    ) : ListVersionSave.Steps {
        val kept = mutableListOf<String>()
        val signed = mutableListOf<Long>()
        val stored = mutableListOf<NostrEvent>()
        val sent = mutableListOf<NostrEvent>()
        override fun activeAccount() = active
        override suspend fun newest() = newest
        override suspend fun keepUndoCopy(current: NostrEvent): Boolean { kept += current.id; return keeps }
        override suspend fun sign(kind: Int, content: String, tags: List<List<String>>, notBefore: Long): NostrEvent {
            signed += notBefore
            switchOnSign?.let { active = it }
            return NostrEvent("new", signAs ?: active, maxOf(notBefore, 50), kind, tags, content, "sig")
        }
        override suspend fun store(signed: NostrEvent): Boolean { if (stores) stored += signed; return stores }
        override suspend fun send(signed: NostrEvent) { sent += signed }
    }

    private val tags = listOf(listOf("e", "1"), listOf("e", "2"))

    private suspend fun save(fake: Fake, shown: String? = base.id) =
        ListVersionSave(fake).save(me, 10003, shown, "merge") { ListVersionSave.Build.Ready(tags, "") }

    @Test
    fun `saves after the one it replaces, the undo copy first`() = runTest {
        val fake = Fake(Result.success(base), me)
        val out = save(fake)
        assertTrue(out is ListVersionSave.Outcome.Saved)
        assertEquals(listOf("base"), fake.kept)
        assertEquals(listOf(101L), fake.signed)
        assertEquals(1, fake.stored.size)
        assertEquals(1, fake.sent.size)
    }

    @Test
    fun `a list that changed since it was shown is refused and says so`() = runTest {
        val fake = Fake(Result.success(base.copy(id = "newer", createdAt = 200)), me)
        val out = save(fake) as ListVersionSave.Outcome.Refused
        assertTrue(out.changed)
        assertTrue(fake.signed.isEmpty())
        // None shown, one there now: the same.
        assertTrue((save(Fake(Result.success(base), me), shown = null) as ListVersionSave.Outcome.Refused).changed)
    }

    @Test
    fun `a newest list that can't be checked is refused with its reason`() = runTest {
        val fake = Fake(Result.failure(IllegalStateException(ListMerge.NOT_ANSWERED)), me)
        val out = save(fake) as ListVersionSave.Outcome.Refused
        assertEquals(ListMerge.NOT_ANSWERED, out.message)
        assertTrue(!out.changed && fake.signed.isEmpty())
    }

    @Test
    fun `nothing is signed when the undo copy can't be kept`() = runTest {
        val fake = Fake(Result.success(base), me, keeps = false)
        val out = save(fake) as ListVersionSave.Outcome.Refused
        assertTrue(out.message, out.message.contains("couldn't be undone"))
        assertTrue(fake.signed.isEmpty())
    }

    @Test
    fun `no list yet needs no undo copy`() = runTest {
        val fake = Fake(Result.success(null), me)
        assertTrue(save(fake, shown = null) is ListVersionSave.Outcome.Saved)
        assertTrue(fake.kept.isEmpty())
        assertEquals(listOf(0L), fake.signed)
    }

    @Test
    fun `a signer that signs as another account is refused`() = runTest {
        val fake = Fake(Result.success(base), me, signAs = "b".repeat(64))
        assertTrue((save(fake) as ListVersionSave.Outcome.Refused).message.contains("couldn't be signed"))
        assertTrue(fake.stored.isEmpty() && fake.sent.isEmpty())
    }

    @Test
    fun `an account switch during signing is refused`() = runTest {
        val fake = Fake(Result.success(base), me, signAs = me, switchOnSign = "b".repeat(64))
        assertTrue((save(fake) as ListVersionSave.Outcome.Refused).message.contains("switched accounts"))
        assertTrue(fake.stored.isEmpty() && fake.sent.isEmpty())
    }

    @Test
    fun `a vault refusal sends nothing`() = runTest {
        val fake = Fake(Result.success(base), me, stores = false)
        assertTrue((save(fake) as ListVersionSave.Outcome.Refused).message.contains("refused the merged"))
        assertTrue(fake.sent.isEmpty())
    }

    @Test
    fun `refuse and build can stop it, build only after the undo copy`() = runTest {
        val fake = Fake(Result.success(base), me)
        val r1 = ListVersionSave(fake).save(me, 10003, base.id, "restore", refuse = { "already" }) { error("not built") }
        assertEquals("already", (r1 as ListVersionSave.Outcome.Refused).message)
        assertTrue(fake.kept.isEmpty())
        val r2 = ListVersionSave(fake).save(me, 10003, base.id, "merge") { ListVersionSave.Build.Refuse("can't encrypt") }
        assertEquals("can't encrypt", (r2 as ListVersionSave.Outcome.Refused).message)
        assertEquals(listOf("base"), fake.kept)
        assertTrue(fake.signed.isEmpty())
    }
}
