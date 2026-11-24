package com.nostrvault.relay

import com.nostrvault.fips.DeviceRole
import com.nostrvault.fips.FipsDevice
import com.nostrvault.fips.FipsMeshSettings
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Desktop Vaults P7, the Android screens' rules (PLANS/NV_DESKTOP_VAULTS_PLAN.md §2.4, §2.5 rules 4, 5, 8): add, change
 * an address, drag, delete (and that a deleted Vault stays deleted, Tron N3 on #2499), the bare-IP refusal, and the
 * listed rows. iOS twin: DesktopVaultsEditingTests.swift (#2511); each test is named after its iOS one.
 */
class DesktopVaultsEditingTest {
    // Random strings in the npub charset, not real accounts.
    private val macA = "npub1z2g42utgkc5tv49xgwy7lplfd8048vuwv9krcc23m828kdjm3cl68tgcyy"
    private val macB = "npub1h8ts9gragczufl8v44chxgut0a870ranmjws865ejtvphmn0czt7cp5dae"

    private fun mac(npub: String, name: String = "", domain: String = "") =
        FipsDevice(npub = npub, role = DeviceRole.MAC, name = name, domain = domain)

    private fun migrated(slot: String, devices: List<FipsDevice> = emptyList()) =
        HavenConfig(macRelayURL = slot, fipsMesh = FipsMeshSettings(devices = devices)).takingInDesktopVaultSlot(ownNpub = null)

    private fun HavenConfig.settingAddress(id: String, typed: String): Pair<HavenConfig, String?> =
        when (val r = DesktopVaultsEditing.changingAddress(id, typed, desktopVaultsInEffect(null), desktopVaultsRemoved)) {
            is DesktopVaultsEditing.AddressChange.Ok -> copy(desktopVaults = r.edited.vaults, desktopVaultsRemoved = r.edited.removed) to null
            is DesktopVaultsEditing.AddressChange.Refused -> this to r.why.message
        }

    private fun add(config: HavenConfig, name: String, typed: String, npub: String? = null): DesktopVault =
        (DesktopVaultsEditing.adding(name, typed, npub, DesktopVaultKind.LINUX, config.desktopVaultsInEffect(null), null) as DesktopVaultsEditing.Added.Ok).vault

    // ── Delete stays deleted (N3) ──

    @Test fun aDeletedMacVaultStaysOffWhileTheMacIsStillPaired() {
        var config = migrated(macA, listOf(mac(macA, "Studio"), mac(macB, "Attic")))
        assertEquals(listOf(macA, macB), config.desktopVaultMeshNpubs(ownNpub = null))
        val id = config.desktopVaultsInEffect(null).first { it.meshNpub == macA }.id
        config = config.deletingDesktopVault(id).takingInDesktopVaultSlot(ownNpub = null)
        // Neither the slot naming it nor My Devices brings it back.
        assertEquals("the old slot is never written", macA, config.macRelayURL)
        assertEquals(listOf(macB), config.desktopVaultMeshNpubs(ownNpub = null))
        assertEquals("", config.macRelayURLInEffect)
        assertEquals(DesktopVaultsRules.MeshDial.AFTER_START, DesktopVaultsRules.meshDial(true, config.macRelayURLInEffect, listOf(macB)))
    }

    @Test fun deletingTheWebSlotsVaultTurnsOffEverythingDerivedFromTheSlot() {
        var config = migrated("https://vault.example.com")
        assertEquals("wss://vault.example.com", config.macRelayWssURL)
        config = config.deletingDesktopVault(config.desktopVaultsInEffect(null)[0].id).takingInDesktopVaultSlot(ownNpub = null)
        assertEquals("https://vault.example.com", config.macRelayURL)
        assertTrue(config.desktopVaultsInEffect(null).isEmpty())
        assertEquals("", config.macRelayWssURL)
        assertEquals("", config.macRelayHttpsURL)
        assertEquals("", MacSync.macRelayURL(config, null))
        assertEquals(emptyList<String>(), config.desktopVaultDMInboxURLs)
        assertEquals(emptyList<String>(), config.desktopVaultWssURLs)
    }

    @Test fun addingTheAddressAgainOrPairingAgainUndoesTheDelete() {
        var config = migrated("https://vault.example.com", listOf(mac(macA, "Studio")))
        for (vault in config.desktopVaultsInEffect(null)) config = config.deletingDesktopVault(vault.id)
        assertTrue(config.desktopVaultsInEffect(null).isEmpty())

        config = config.addingDesktopVault(add(config, "Home", "vault.example.com"))
        assertEquals(listOf("https://vault.example.com"), config.desktopVaultsInEffect(null).map { it.httpsURL })
        assertEquals("https://vault.example.com", config.macRelayURLInEffect)

        config = config.forgettingRemovedDesktopVault(macA)
        assertEquals(listOf(macA), config.desktopVaultMeshNpubs(ownNpub = null))
    }

    /** Tron must-fix 1 on #2511: a Vault keeps its id when its address changes, so one added later at the old address gets its own. */
    @Test fun aVaultAddedAtAMovedVaultsOldAddressGetsItsOwnIdAndDeletesAlone() {
        var config = migrated("https://old.example.com")
        val first = config.desktopVaultsInEffect(null)[0].id
        val (moved, why) = config.settingAddress(first, "new.example.com")
        assertNull(why)
        config = moved
        val second = add(config, "Second", "old.example.com")
        config = config.addingDesktopVault(second)
        val vaults = config.desktopVaultsInEffect(null)
        assertEquals(2, vaults.size)
        assertEquals("every Vault has its own id", 2, vaults.map { it.id }.toSet().size)

        config = config.deletingDesktopVault(second.id)
        assertEquals(listOf("https://new.example.com"), config.desktopVaultsInEffect(null).map { it.httpsURL })
        assertFalse(DesktopVaultsEditing.removedKeyForHost("new.example.com") in config.desktopVaultsRemoved)
        assertEquals("the old slot stays off", "", config.macRelayURLInEffect)
    }

    @Test fun freshIDCountsUpPastTakenIds() {
        val taken = listOf("https:a.example.com", "https:a.example.com#2").mapIndexed { i, id ->
            DesktopVault(id = id, httpsURL = "https://x$i.example.com", order = i)
        }
        assertEquals("https:b.example.com", DesktopVaultsEditing.freshID("https:b.example.com", taken))
        assertEquals("https:a.example.com#3", DesktopVaultsEditing.freshID("https:a.example.com", taken))
    }

    // ── Add (rule 4) ──

    @Test fun addRefusesATakenHostOrDeviceAndNeedsAnAddress() {
        val vaults = listOf(DesktopVault(id = "a", name = "Studio", meshNpub = macA, httpsURL = "https://vault.example.com", order = 0))
        fun add(typed: String, npub: String? = null, own: String? = null) =
            (DesktopVaultsEditing.adding("", typed, npub, DesktopVaultKind.MAC, vaults, own) as? DesktopVaultsEditing.Added.Refused)?.why
        assertEquals(DesktopVaultsEditing.AddRefusal.HostTaken(vaults[0]), add("WSS://Vault.Example.com/"))
        assertEquals(DesktopVaultsEditing.AddRefusal.MeshTaken(vaults[0]), add("", macA))
        assertEquals(DesktopVaultsEditing.AddRefusal.OwnAddress, add("", macB, own = macB))
        assertEquals(DesktopVaultsEditing.AddRefusal.NoAddress, add(""))
        assertEquals(DesktopVaultsEditing.AddRefusal.NotMeshAddress, add("", "not-an-npub"))
        assertNull(add("https://other.example.com", macB))
        assertEquals("That address is already your Vault Studio.", DesktopVaultsEditing.AddRefusal.HostTaken(vaults[0]).message)
    }

    // ── Change an address ──

    @Test fun aChangedAddressNeverBringsTheOldSlotBackAsASecondVault() {
        var config = migrated("https://old.example.com")
        val id = config.desktopVaultsInEffect(null)[0].id
        val (moved, why) = config.settingAddress(id, "https://new.example.com")
        assertNull(why)
        config = moved.takingInDesktopVaultSlot(ownNpub = null)
        assertEquals(listOf("https://new.example.com"), config.desktopVaultsInEffect(null).map { it.httpsURL })
        assertEquals("the relay leaves the old address", "", config.macRelayURLInEffect)
        assertEquals("", MacSync.macRelayURL(config, null))
        assertEquals("wss://new.example.com", DesktopVaultsRules.envList(config.desktopVaultsInEffect(null), "", typed = config.macRelayURLInEffect))
    }

    @Test fun clearingTheOnlyAddressIsRefused() {
        val config = migrated("https://old.example.com")
        val id = config.desktopVaultsInEffect(null)[0].id
        assertEquals(DesktopVaultsEditing.AddRefusal.NoAddress.message, config.settingAddress(id, "").second)
        assertEquals(1, config.desktopVaultsInEffect(null).size)
    }

    // ── Drag ──

    @Test fun movingRenumbers() {
        val vaults = (0 until 3).map { DesktopVault(id = "v$it", httpsURL = "https://v$it.example", order = it) }
        val moved = DesktopVaultsEditing.moving(vaults, from = 2, to = 0)
        assertEquals(listOf("v2", "v0", "v1"), moved.map { it.id })
        assertEquals(listOf(0, 1, 2), moved.map { it.order })
        assertEquals(listOf("v1", "v2", "v0"), DesktopVaultsEditing.moving(vaults, from = 0, to = 2).map { it.id })
    }

    // ── Rule 8 ──

    @Test fun aBareIPAddressIsNeverListed() {
        for (ip in listOf("https://203.0.113.7", "203.0.113.7:4869", "https://[2001:db8::1]:443", "2001:db8::1", "wss://10.0.0.2/relay")) {
            assertTrue(ip, DesktopVaultsEditing.isIPHost(ip))
        }
        for (host in listOf("https://vault.example.com", "vault.example.com:8443", "https://1.example.com", "https://999.1.1.1")) {
            assertFalse(host, DesktopVaultsEditing.isIPHost(host))
        }
    }

    // ── Rows (§2.4) ──

    @Test fun listedEntriesNameTheirVault() {
        val vault = DesktopVault(id = "a", name = "Studio", meshNpub = macA, httpsURL = "https://vault.example.com", order = 0)
        val tags = listOf(listOf("server", "https://blossom.example"), listOf("server", "https://vault.example.com/"), listOf("server", "fipsmesh://$macA/"))
        val rows = DesktopVaultsEditing.listedEntries(tags, DesktopVaultList.MEDIA, listOf(vault))
        assertEquals(listOf("https://vault.example.com/", "fipsmesh://$macA/"), rows.map { it.url })
        assertEquals(listOf(false, true), rows.map { it.mesh })
        assertEquals(listOf(listOf("server", "https://blossom.example")), DesktopVaultsEditing.splitting(tags, DesktopVaultList.MEDIA, listOf(vault)).second)
    }
}
