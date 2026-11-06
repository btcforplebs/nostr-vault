package com.nostrvault.fips

import com.nostrvault.fips.CopyAccounts.Account
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.emptyFlow
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

/** The sync end to end against a stand-in device: the file it writes, the offer, and what an answer adds. */
class CopyAccountsSyncTest {
    @get:Rule val tmp = TemporaryFolder()

    private val owner = "npub1fsgzj6t7udv8zhf6zj32mkqhcjcpv52yph5qsdcl0qt94jgdckqs4yjc3w"
    private val other = "npub13evkv42fprxqfpqdp966kn2cwpjrk9jflp08yelkkue20g977wpsv6pcap"
    private val third = "npub1ks0t9yldwmqlr2k8jnm25gs92za45mp5rhwtkk0r0wlz9wg688zs99ny60"

    /** [signing]: the accounts it can sign for; the rest of [npubs] are look-only. */
    private class FakeDevice(var npubs: List<String>, var live: Int = 1, var signing: List<String>? = null) : CopyAccountsSync.Device {
        val liveCalls = mutableListOf<String>()
        val lookOnly = mutableListOf<String>()
        override fun changes(): Flow<Any?> = emptyFlow()
        override fun accounts() = npubs
        override fun signingAccounts() = signing ?: npubs
        override fun name(hex: String) = if (MeshPairing.npub(hex) == npubs.firstOrNull()) "Owner" else ""
        override fun addLive(json: String): Int { liveCalls += json; return live }
        override fun addLookOnly(npubs: List<String>) { lookOnly += npubs }
    }

    private class MemSettled : CopyAccountsSync.Settled { override var hexes: Set<String> = emptySet() }

    private val device = FakeDevice(listOf(owner))
    private val settled = MemSettled()
    private val sync by lazy { CopyAccountsSync({ tmp.root }, device, settled, CoroutineScope(Dispatchers.Unconfined), { 1767000000 }) }
    private val file get() = File(tmp.root, CopyAccounts.FILE)

    /** What the engine does after a copy: merges the other device's list into the file (offerCopyAccounts). */
    private fun engineMerges(vararg theirs: Account) {
        val merged = CopyAccounts.merge(CopyAccounts.accountsIn(file.takeIf { it.exists() }?.readText()), theirs.toList())
        file.writeText(CopyAccounts.fileJson(merged, 1767000100)!!)
    }

    @Test
    fun `this device's file lists its own accounts with names and passes the engine's check`() {
        sync.writeOwn()
        assertEquals(CopyAccounts.Checked.Ok(listOf(Account(owner, "Owner"))), CopyAccounts.check(file.readText()))
        assertFalse(file.readText().contains("nsec"))
        // Nothing of its own is offered back to it.
        assertTrue(sync.refreshOffer().isEmpty())
    }

    @Test
    fun `a copy's accounts are offered, and only the ticked reach AddAccountsC and this device`() {
        sync.writeOwn()
        engineMerges(Account(owner), Account(other, "Other"), Account(third))
        assertEquals(listOf(Account(other, "Other"), Account(third)), sync.refreshOffer())
        sync.answer(listOf(third))
        assertEquals(1, device.liveCalls.size)
        assertEquals(CopyAccounts.Checked.Ok(listOf(Account(third))), CopyAccounts.check(device.liveCalls.single()))
        assertEquals(listOf(third), device.lookOnly)
        assertTrue(sync.offered.value.isEmpty())
        // Both were asked: neither is asked again, even after the next catch-up merges them in again.
        engineMerges(Account(other, "Other"), Account(third))
        assertTrue(sync.refreshOffer().isEmpty())
    }

    @Test
    fun `just this one settles every offered account and adds none`() {
        engineMerges(Account(owner), Account(other))
        assertEquals(listOf(other), sync.refreshOffer().map { it.npub })
        sync.answer(emptyList())
        assertTrue(device.liveCalls.isEmpty())
        assertTrue(device.lookOnly.isEmpty())
        assertTrue(sync.refreshOffer().isEmpty())
    }

    @Test
    fun `a list the engine refuses is not added here either`() {
        device.live = -1
        engineMerges(Account(owner), Account(other))
        sync.refreshOffer()
        sync.answer(listOf(other))
        assertTrue(device.lookOnly.isEmpty())
    }

    @Test
    fun `an account that was own here once is never offered back after it is removed`() {
        device.npubs = listOf(owner, other)
        sync.writeOwn()
        device.npubs = listOf(owner)
        assertTrue(sync.refreshOffer().isEmpty())
    }

    @Test
    fun `a file holding a key is never offered from`() {
        file.writeText("""{"v":1,"updated_at":1,"accounts":[{"npub":"$other","name":"nsec19uqxr6xazkeed24thcl9gwl8e5alzdtma8enxekqkv3ux3m9ty3qqp49sa"}]}""")
        assertTrue(sync.refreshOffer().isEmpty())
    }

    @Test
    fun `a look-only account never goes in the file, so no other vault is offered it (Tron, #1810)`() {
        // A: the owner can sign; `other` is look-only (someone's public npub).
        device.npubs = listOf(owner, other)
        device.signing = listOf(owner)
        sync.writeOwn()
        assertEquals(listOf(Account(owner, "Owner")), CopyAccounts.accountsIn(file.readText()))
        assertFalse(file.readText().contains(other))
    }

    @Test
    fun `a look-only account an older build wrote is dropped from the file`() {
        // An older build wrote every account, look-only ones too.
        file.writeText(CopyAccounts.fileJson(listOf(Account(owner), Account(other, "Watched")), 1767000000)!!)
        device.npubs = listOf(owner, other)
        device.signing = listOf(owner)
        sync.writeOwn()
        assertEquals(listOf(Account(owner, "Owner")), CopyAccounts.accountsIn(file.readText()))
        // And this device's own look-only account is never offered back to it either.
        assertTrue(sync.refreshOffer().isEmpty())
    }
}
