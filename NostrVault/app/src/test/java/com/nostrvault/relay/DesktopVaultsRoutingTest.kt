package com.nostrvault.relay

import com.nostrvault.fips.DeviceRole
import com.nostrvault.fips.FipsDevice
import com.nostrvault.fips.FipsIngress
import com.nostrvault.fips.FipsMeshSettings
import com.nostrvault.service.VaultPublishHandoff
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Desktop Vaults P6, Android routing (PLANS/NV_DESKTOP_VAULTS_PLAN.md §2.2, §2.4): the DM inbox and self-copy cover
 * every HTTPS Vault, publish-for-me and the mesh dial take the list in order, the env passes the rest, and a Vault
 * switch changes only its own entry. Plus Tron's N1-N3 on #2499. iOS twin: DesktopVaultsRoutingTests.swift (#2506,
 * #2507); each test is named after its iOS one.
 */
class DesktopVaultsRoutingTest {
    // Random strings in the npub charset, not real accounts.
    private val macA = "npub1z2g42utgkc5tv49xgwy7lplfd8048vuwv9krcc23m828kdjm3cl68tgcyy"
    private val macB = "npub1h8ts9gragczufl8v44chxgut0a870ranmjws865ejtvphmn0czt7cp5dae"
    private val meshURL = "ws://127.0.0.1:41234/abcdef0123456789"
    private val ingressBase = "http://127.0.0.1:41234/abcdef0123456789"
    private val dir = File("/tmp/x")

    private fun mac(npub: String, name: String = "", domain: String = "") =
        FipsDevice(npub = npub, role = DeviceRole.MAC, name = name, domain = domain)

    private fun vault(id: String, https: String? = null, mesh: String? = null, order: Int) =
        DesktopVault(id = id, meshNpub = mesh, httpsURL = https, order = order)

    private fun config(slot: String = "", devices: List<FipsDevice> = emptyList(), fips: Boolean = false, blastr: List<String> = emptyList()) =
        HavenConfig(macRelayURL = slot, fipsMesh = FipsMeshSettings(devices = devices), fipsMeshEnabled = fips, blastrRelays = blastr)

    @After fun reset() {
        RelayConfiguration.macMeshRelay = null
        RelayConfiguration.pendingMeshRelay = null
        OwnMeshNpub.value = null
        MeshVaultDial.failed = null
    }

    // ── N1, N2: the list follows My Devices ──

    @Test fun macPairedAfterMigrationJoinsTheList() {
        val taken = config(slot = "https://web.example.com").takingInDesktopVaultSlot(ownNpub = null)
        val vaults = taken.copy(fipsMesh = FipsMeshSettings(devices = listOf(mac(macA, "Studio")))).desktopVaultsInEffect(ownNpub = null)
        assertEquals(listOf("https://web.example.com", null), vaults.map { it.httpsURL })
        assertEquals(listOf(null, macA), vaults.map { it.meshNpub })
        assertEquals("Studio", vaults.last().name)
        assertEquals(listOf(0, 1), vaults.map { it.order })
    }

    @Test fun removedMacLeavesTheList() {
        val taken = config(devices = listOf(mac(macA), mac(macB))).takingInDesktopVaultSlot(ownNpub = null)
        assertEquals(listOf(macA, macB), taken.desktopVaultMeshNpubs(ownNpub = null))
        assertEquals(listOf(macB), taken.copy(fipsMesh = FipsMeshSettings(devices = listOf(mac(macB)))).desktopVaultMeshNpubs(ownNpub = null))
        // A Vault with a web address keeps it and loses only the mesh path.
        val both = DesktopVaultsRules.followingDevices(listOf(vault("a", https = "https://a.example.com", mesh = macA, order = 0)),
            emptyList(), "", ownNpub = null)
        assertEquals(listOf("https://a.example.com"), both.map { it.httpsURL })
        assertEquals(listOf<String?>(null), both.map { it.meshNpub })
    }

    /** The slot's own npub stays a Vault even when it is no `.mac` device, as it was before P6. */
    @Test fun slotNpubStaysWithoutADevice() {
        assertEquals(listOf(macA), config(slot = macA).takingInDesktopVaultSlot(ownNpub = null).desktopVaultMeshNpubs(ownNpub = null))
    }

    @Test fun ownNpubIsNeverAVault() {
        val taken = config(slot = macA, devices = listOf(mac(macA), mac(macB))).takingInDesktopVaultSlot(ownNpub = macA)
        assertEquals(listOf<String?>(macB), taken.desktopVaults.map { it.meshNpub })
        // A list stored before this device knew its own npub sheds it.
        val stored = config(devices = listOf(mac(macA), mac(macB))).takingInDesktopVaultSlot(ownNpub = null)
        assertEquals(listOf(macA), stored.desktopVaultMeshNpubs(ownNpub = macB))
        // Even when the slot names it (a Mac whose old field held its own npub).
        val slotted = config(slot = macA).takingInDesktopVaultSlot(ownNpub = null)
        assertEquals(listOf(macA), slotted.desktopVaultMeshNpubs(ownNpub = null))
        assertEquals(emptyList<String>(), slotted.desktopVaultMeshNpubs(ownNpub = macA))
    }

    @Test fun pairedMacWithTheVaultsDomainMergesIntoIt() {
        val out = DesktopVaultsRules.followingDevices(listOf(vault("w", https = "https://Mac.Example.com/haven", order = 0)),
            listOf(mac(macA, "Studio", domain = "mac.example.com")), "", ownNpub = null)
        assertEquals(1, out.size)
        assertEquals(macA, out.first().meshNpub)
        assertEquals("https://Mac.Example.com/haven", out.first().httpsURL)
        assertEquals("Studio", out.first().name)
    }

    /** N3: clearing the old field takes only the slot's address off. A Mac still in My Devices stays a Vault. */
    @Test fun clearingTheOldTabKeepsAPairedMacAndDropsAnUnpairedOne() {
        val taken = config(slot = "https://mac.example.com", devices = listOf(mac(macA, domain = "mac.example.com")))
            .takingInDesktopVaultSlot(ownNpub = null)
        assertEquals(listOf<String?>(macA), taken.desktopVaults.map { it.meshNpub })
        val cleared = taken.copy(macRelayURL = "")
        assertEquals(listOf<String?>(null), cleared.desktopVaultsInEffect(ownNpub = null).map { it.httpsURL })
        assertEquals(listOf(macA), cleared.desktopVaultMeshNpubs(ownNpub = null))
        assertEquals(emptyList<DesktopVault>(), cleared.copy(fipsMesh = FipsMeshSettings()).desktopVaultsInEffect(ownNpub = null))

        val meshSlot = config(slot = macB).takingInDesktopVaultSlot(ownNpub = null).copy(macRelayURL = "")
        assertEquals(emptyList<DesktopVault>(), meshSlot.desktopVaultsInEffect(ownNpub = null))
    }

    // ── Publish-for-me and the mesh dial ──

    @Test fun meshNpubsFollowListOrderOncePerNpub() {
        val vaults = listOf(vault("b", mesh = macB, order = 1), vault("w", https = "https://w.example.com", order = 0),
            vault("a", mesh = "fipsmesh://$macA/", order = 2), vault("a2", mesh = macA, order = 3))
        assertEquals(listOf(macB, macA), DesktopVaultsRules.meshNpubs(vaults))
    }

    /** A dial for a mesh Vault on the list counts, wherever the slot points; a dial left from before the list changed does not. */
    @Test fun dialedListVaultIsPublishForMeAndMacRelay() {
        val c = config(slot = "https://web.example.com", devices = listOf(mac(macA)), fips = true, blastr = listOf("wss://nos.lol"))
            .takingInDesktopVaultSlot(ownNpub = null)
        val dialed = RelayConfiguration.MacMeshRelay(macA, meshURL)
        assertEquals(dialed, RelayConfiguration.dialedVault(c, dialed))
        assertEquals(meshURL, MacSync.macRelayURL(c, dialed))
        assertEquals("$meshURL?pulled=1", RelayConfiguration.blastrRelays(c, dialed).first())
        assertEquals(dialed, VaultPublishHandoff.target(c, dialed))
        // The web slot is not lost: it goes to DESKTOP_VAULT_URLS.
        assertEquals("wss://web.example.com", DesktopVaultsRules.envList(c.desktopVaultsInEffect, meshURL, typed = c.macRelayURL))

        val stale = RelayConfiguration.MacMeshRelay(macB, meshURL)
        assertNull(RelayConfiguration.dialedVault(c, stale))
        assertNull(VaultPublishHandoff.target(c, stale))
        assertEquals("wss://web.example.com", MacSync.macRelayURL(c, stale))
        assertFalse(RelayConfiguration.blastrRelays(c, stale).any { it.startsWith("ws://127.0.0.1") })
        // Mesh off: never the publish-for-me target.
        assertNull(VaultPublishHandoff.target(c.copy(fipsMeshEnabled = false), dialed))
    }

    // ── When the mesh is dialed (Tron M1 on #2506) ──

    /** Before the start only for a mesh-npub slot; any other mesh Vault is dialed after a wss start; nothing with FIPS off or no mesh Vault. */
    @Test fun meshDialHoldsTheStartOnlyForAMeshSlot() {
        assertEquals(DesktopVaultsRules.MeshDial.BEFORE_START, DesktopVaultsRules.meshDial(true, macA, listOf(macA)))
        assertEquals(DesktopVaultsRules.MeshDial.AFTER_START, DesktopVaultsRules.meshDial(true, "https://web.example.com", listOf(macA, macB)))
        assertEquals(DesktopVaultsRules.MeshDial.AFTER_START, DesktopVaultsRules.meshDial(true, "", listOf(macA)))
        assertEquals(DesktopVaultsRules.MeshDial.NONE, DesktopVaultsRules.meshDial(false, macA, listOf(macA)))
        assertEquals(DesktopVaultsRules.MeshDial.NONE, DesktopVaultsRules.meshDial(false, "https://web.example.com", listOf(macA)))
        assertEquals(DesktopVaultsRules.MeshDial.NONE, DesktopVaultsRules.meshDial(true, "https://web.example.com", emptyList()))
    }

    /** Dials go in list order and the first answer wins. */
    @Test fun firstAnsweringTakesTheFirstThatAnswersInOrder() {
        val found = DesktopVaultsRules.firstAnswering(listOf(macA, macB), 5_000) { if (it == macB) "ws://127.0.0.1:1/b" else null }
        assertEquals(macB to "ws://127.0.0.1:1/b", found)
    }

    /** Unreachable Vaults share one budget: dials that never answer end with the budget, and a later one is not tried. */
    @Test fun firstAnsweringSharesOneBudget() {
        val tried = java.util.Collections.synchronizedList(mutableListOf<String>())
        val start = System.nanoTime()
        val found = DesktopVaultsRules.firstAnswering(listOf(macA, macB, "npub1third"), 600) { npub ->
            tried += npub
            Thread.sleep(5_000)
            "ws://127.0.0.1:1/late"
        }
        assertNull(found)
        assertTrue((System.nanoTime() - start) / 1_000_000 < 2_000)
        assertEquals(listOf(macA), tried.toList())
    }

    /** A start with a web slot never dials before it: it takes only the background dial's hand-over, for a Vault on the list. */
    @Test fun aStartWithAWebSlotTakesTheHandOverAndDialsNothing() {
        val c = config(slot = "https://web.example.com", devices = listOf(mac(macA)), fips = true).takingInDesktopVaultSlot(ownNpub = null)
        val dialed = mutableListOf<String>()
        val reach: (String) -> FipsIngress = { dialed += it; FipsIngress(url = ingressBase) }
        assertEquals("wss://web.example.com", RelayConfiguration.launchInputs(c, dir, reach).env["MAC_RELAY_URL"])
        assertEquals(emptyList<String>(), dialed)

        RelayConfiguration.pendingMeshRelay = RelayConfiguration.MacMeshRelay(macA, meshURL)
        // The settings check sees the hand-over and leaves it for the start.
        assertEquals(meshURL, RelayConfiguration.comparedInputs(c, dir).env["MAC_RELAY_URL"])
        assertEquals(RelayConfiguration.MacMeshRelay(macA, meshURL), RelayConfiguration.pendingMeshRelay)
        val env = RelayConfiguration.launchInputs(c, dir, reach).env
        assertEquals(meshURL, env["MAC_RELAY_URL"])
        assertEquals("wss://web.example.com", env["DESKTOP_VAULT_URLS"])
        assertNull(RelayConfiguration.pendingMeshRelay)
        assertEquals(emptyList<String>(), dialed)

        // A hand-over for a Mac no longer on the list is not taken.
        RelayConfiguration.macMeshRelay = null
        RelayConfiguration.pendingMeshRelay = RelayConfiguration.MacMeshRelay(macB, meshURL)
        assertEquals("wss://web.example.com", RelayConfiguration.launchInputs(c, dir, reach).env["MAC_RELAY_URL"])
    }

    /** A mesh-npub slot dials before the start, in list order inside one budget, and the first that answers wins. */
    @Test fun aMeshSlotDialsTheListBeforeTheStart() {
        val c = config(slot = macA, devices = listOf(mac(macB)), fips = true).takingInDesktopVaultSlot(ownNpub = null)
        assertEquals(listOf(macA, macB), c.desktopVaultMeshNpubs)
        val dialed = mutableListOf<String>()
        val env = RelayConfiguration.launchInputs(c, dir, { npub ->
            dialed += npub
            if (npub == macB) FipsIngress(url = ingressBase) else FipsIngress(error = com.nostrvault.fips.FipsBridge.ERR_START)
        }).env
        assertEquals(listOf(macA, macB), dialed)
        assertEquals(meshURL, env["MAC_RELAY_URL"])
        assertEquals(RelayConfiguration.MacMeshRelay(macB, meshURL), RelayConfiguration.macMeshRelay)
    }

    /**
     * After a wss start the background dial hands the first answering Vault to a restart, which takes it; a dial
     * that found nobody is not repeated by every save; a relay that stopped meanwhile gets no restart.
     */
    @Test fun theBackgroundDialHandsOverToOneRestart() {
        val c = config(slot = "https://web.example.com", devices = listOf(mac(macA), mac(macB)), fips = true)
            .takingInDesktopVaultSlot(ownNpub = null)
        var restarts = 0
        var takenAtRestart: RelayConfiguration.MacMeshRelay? = null
        val job = MeshVaultDial.afterStart(c, latest = { c }, relayRunning = { true },
            restart = { restarts++; takenAtRestart = RelayConfiguration.pendingMeshRelay; true },
            ingress = { if (it == macB) FipsIngress(url = ingressBase) else FipsIngress(error = com.nostrvault.fips.FipsBridge.ERR_START) })
        kotlinx.coroutines.runBlocking { job!!.join() }
        assertEquals(1, restarts)
        assertEquals(RelayConfiguration.MacMeshRelay(macB, meshURL), takenAtRestart)
        // The restart here took nothing: the hand-over is dropped (F1).
        assertNull(RelayConfiguration.pendingMeshRelay)

        // Nobody answers: no restart, and a save right after doesn't dial again; a start does.
        var dials = 0
        val none: (String) -> FipsIngress = { dials++; FipsIngress(error = com.nostrvault.fips.FipsBridge.ERR_START) }
        kotlinx.coroutines.runBlocking {
            MeshVaultDial.afterStart(c, latest = { c }, relayRunning = { true }, restart = { restarts++; true }, ingress = none)!!.join()
        }
        assertEquals(1, restarts)
        assertNull(MeshVaultDial.afterStart(c, latest = { c }, fromSave = true, relayRunning = { true }, restart = { restarts++; true }, ingress = none))
        val again = dials
        kotlinx.coroutines.runBlocking {
            MeshVaultDial.afterStart(c, latest = { c }, relayRunning = { true }, restart = { restarts++; true }, ingress = none)!!.join()
        }
        assertTrue(dials > again)

        // The relay stopped while dialing: nothing is handed over.
        var checks = 0
        kotlinx.coroutines.runBlocking {
            // Running at the gate, stopped when the dial ends.
            MeshVaultDial.afterStart(c, latest = { c }, relayRunning = { checks++ == 0 }, restart = { restarts++; true },
                ingress = { FipsIngress(url = ingressBase) })!!.join()
        }
        assertEquals(1, restarts)
        assertNull(RelayConfiguration.pendingMeshRelay)
        // A web slot with no mesh Vault, or a mesh slot after its start (it dialed before), never dials here.
        assertNull(MeshVaultDial.afterStart(config(slot = "https://web.example.com", fips = true), latest = { c }, relayRunning = { true }))
        assertNull(MeshVaultDial.afterStart(config(slot = macA, fips = true).takingInDesktopVaultSlot(ownNpub = null), latest = { c }, relayRunning = { true }))
    }

    // ── The env ──

    /** A Vault reached over the mesh keeps its wss as the fallback (Tron M2 on #2506); a plain ws:// slot keeps ws://. */
    @Test fun envListKeepsTheDialedVaultsWSSAndPlainWS() {
        val vaults = listOf(vault("a", https = "https://a.example.com", mesh = macA, order = 0),
            vault("b", https = "https://b.example.com/haven", order = 1),
            vault("c", https = "https://192.168.1.5:3355", order = 2))
        assertEquals("wss://a.example.com,wss://b.example.com/haven,ws://192.168.1.5:3355",
            DesktopVaultsRules.envList(vaults, meshURL, typed = "ws://192.168.1.5:3355"))
        assertEquals("wss://b.example.com/haven,wss://192.168.1.5:3355", DesktopVaultsRules.envList(vaults, "wss://a.example.com"))
    }

    // ── DM inbox and self-copy (§2.2 rule 2) ──

    @Test fun everyHTTPSVaultIsADMInboxInListOrder() {
        val vaults = listOf(vault("b", https = "https://b.example.com/haven/", order = 1),
            vault("m", mesh = macA, order = 0),
            vault("a", https = "https://a.example.com", order = 2),
            vault("lan", https = "https://192.168.1.9:3355", order = 3),
            vault("ts", https = "https://mac.tail1234.ts.net", order = 4))
        assertEquals(listOf("wss://b.example.com/haven/inbox", "wss://a.example.com/inbox"), DesktopVaultsRules.dmInboxURLs(vaults, ""))
        // A slot typed as plain ws:// was never a public inbox and still isn't.
        assertEquals(emptyList<String>(), DesktopVaultsRules.dmInboxURLs(listOf(vault("p", https = "https://p.example.com", order = 0)), "ws://p.example.com"))
        assertEquals(listOf("wss://b.example.com/haven/inbox", "wss://a.example.com/inbox", "wss://inbox.nostr.wine"),
            DMInbox.merged(listOf("wss://b.example.com/haven/inbox", "wss://a.example.com/inbox"),
                listOf("wss://a.example.com/inbox/", "wss://inbox.nostr.wine")))
        // The config's DM inbox list puts every HTTPS Vault first, in list order.
        val c = HavenConfig(desktopVaults = vaults, desktopVaultsSlot = "", dmRelays = listOf("wss://inbox.nostr.wine"))
        assertEquals(listOf("wss://b.example.com/haven/inbox", "wss://a.example.com/inbox", "wss://inbox.nostr.wine"), c.dmInboxRelays)
        assertEquals("wss://b.example.com/haven/inbox", c.ownHavenDMInboxURL)
    }

    /** A one-slot user's inbox is what the slot gave before P6. */
    @Test fun slotUserKeepsTheirInbox() {
        for (slot in listOf("wss://mac.example.com/", "https://mac.example.com/haven", "mac.example.com")) {
            val c = config(slot = slot).takingInDesktopVaultSlot(ownNpub = null)
            assertEquals(slot, listOf("wss://${c.macRelayNormalizedBase}/inbox"), c.desktopVaultDMInboxURLs)
        }
    }

    // ── DesktopVaultListEdit's change (§2.5 rule 7) ──

    @Test fun switchChangesOnlyThisVaultsEntryOnTheNewestList() {
        val a = vault("a", https = "https://a.example.com", mesh = macA, order = 0)
        val b = vault("b", https = "https://b.example.com", order = 1)
        val newest = listOf(listOf("relay", "wss://inbox.nostr.wine"), listOf("relay", "wss://b.example.com/inbox"))
        // In front of b, the next Vault; no existing entry moves (rule 2).
        assertEquals(DesktopVaultListChange.Tags(listOf(listOf("relay", "wss://inbox.nostr.wine"), listOf("relay", "wss://a.example.com/inbox"),
            listOf("relay", "wss://b.example.com/inbox"))),
            DesktopVaultsLists.switching(true, a, DesktopVaultPath.WEB, DesktopVaultList.INBOX, newest, listOf(a, b)))
        assertEquals(DesktopVaultListChange.Tags(listOf(listOf("relay", "wss://inbox.nostr.wine"))),
            DesktopVaultsLists.switching(false, b, DesktopVaultPath.WEB, DesktopVaultList.INBOX, newest, listOf(a, b)))
        assertEquals(DesktopVaultListChange.Refused(DesktopVaultList.INBOX),
            DesktopVaultsLists.switching(false, b, DesktopVaultPath.WEB, DesktopVaultList.INBOX, listOf(listOf("relay", "wss://b.example.com/inbox")), listOf(a, b)))
    }

    /** The relays agree there is no list yet: on starts one when it is usable on its own, off changes nothing. */
    @Test fun switchWithNoPublishedList() {
        val a = vault("a", https = "https://a.example.com", mesh = macA, order = 0)
        assertEquals(DesktopVaultListChange.Tags(listOf(listOf("server", "https://a.example.com"))),
            DesktopVaultsLists.switching(true, a, DesktopVaultPath.WEB, DesktopVaultList.MEDIA, null, listOf(a)))
        assertEquals(DesktopVaultListChange.Refused(DesktopVaultList.MEDIA),
            DesktopVaultsLists.switching(true, a, DesktopVaultPath.MESH, DesktopVaultList.MEDIA, null, listOf(a)))
        assertEquals(DesktopVaultListChange.Tags(emptyList()),
            DesktopVaultsLists.switching(false, a, DesktopVaultPath.WEB, DesktopVaultList.RELAYS, null, listOf(a)))
    }

    // ── 10002 saves carry fipsmesh tags over ──

    /** A Relays Save rebases onto the newest 10002 and keeps every tag that isn't an `r` tag, `fipsmesh` included, last. */
    @Test fun relaysSaveKeepsTheNewestListsMeshTagsLast() {
        val fips = listOf("fipsmesh", "fipsmesh://$macA/", "write")
        val newest = listOf(listOf("r", "wss://nostr.land"), fips, listOf("r", "ws://192.168.1.5:3355"))
        val out = RelayDraft.rebaseRelayList(listOf(listOf("r", "wss://nostr.land")), listOf(listOf("r", "wss://nostr.land", "read")), newest)
        assertEquals(fips, out.last())
        assertEquals(listOf(fips), out.filter { it.first() == "fipsmesh" })
    }

    // ── Tron F1 on #2506: the dial's hand-over ──

    /** A hand-over the restart didn't take is dropped, so a later start can't take a mesh address that may be dead; another one stays. */
    @Test fun unusedHandOverIsDroppedAfterTheRestart() {
        val found = RelayConfiguration.MacMeshRelay(macA, meshURL)
        RelayConfiguration.pendingMeshRelay = found
        RelayConfiguration.droppingUnusedHandOver(found)
        assertNull(RelayConfiguration.pendingMeshRelay)

        val other = RelayConfiguration.MacMeshRelay(macB, meshURL)
        RelayConfiguration.pendingMeshRelay = other
        RelayConfiguration.droppingUnusedHandOver(found)
        assertEquals(other, RelayConfiguration.pendingMeshRelay)
    }

    // ── Tron's M1, M2, L1 on #2513 ──

    /** M1: a mesh-npub slot whose start found nobody is dialed again by a save, and the restart takes what it found. */
    @Test fun aSaveRedialsAMeshSlotThatFoundNobody() {
        val c = config(slot = macA, fips = true).takingInDesktopVaultSlot(ownNpub = null)
        var restarts = 0
        var taken: RelayConfiguration.MacMeshRelay? = null
        val reach: (String) -> FipsIngress = { FipsIngress(url = ingressBase) }
        // A start dialed before it, so the dial after it does nothing.
        assertNull(MeshVaultDial.afterStart(c, latest = { c }, relayRunning = { true }, restart = { restarts++; true }, ingress = reach))
        val job = MeshVaultDial.afterStart(c, latest = { c }, fromSave = true, relayRunning = { true },
            restart = { restarts++; taken = RelayConfiguration.pendingMeshRelay; true }, ingress = reach)
        kotlinx.coroutines.runBlocking { job!!.join() }
        assertEquals(1, restarts)
        assertEquals(RelayConfiguration.MacMeshRelay(macA, meshURL), taken)
        // That restart's start takes it with no dial.
        RelayConfiguration.pendingMeshRelay = taken
        val env = RelayConfiguration.launchInputs(c, dir) { throw IllegalStateException("no dial") }.env
        assertEquals(meshURL, env["MAC_RELAY_URL"])
        // Once it holds one, a save does nothing.
        assertNull(MeshVaultDial.afterStart(c, latest = { c }, fromSave = true, relayRunning = { true }, ingress = reach))
    }

    /** M2: a wss start keeps the mesh Vault the relay had (one re-dial of it alone), as the settings check predicted. */
    @Test fun aWebSlotRestartKeepsTheHeldMeshVault() {
        val c = config(slot = "https://web.example.com", devices = listOf(mac(macA), mac(macB)), fips = true)
            .takingInDesktopVaultSlot(ownNpub = null)
        RelayConfiguration.macMeshRelay = RelayConfiguration.MacMeshRelay(macB, meshURL)
        val predicted = RelayConfiguration.comparedInputs(c, dir)
        assertEquals(meshURL, predicted.env["MAC_RELAY_URL"])
        val dialed = mutableListOf<String>()
        val started = RelayConfiguration.launchInputs(c, dir) { dialed += it; FipsIngress(url = ingressBase) }
        assertEquals(predicted, started)
        assertEquals(listOf(macB), dialed)
        assertEquals(RelayConfiguration.MacMeshRelay(macB, meshURL), RelayConfiguration.macMeshRelay)

        // It no longer answers: the start is on wss and the list is dialed after it.
        val env = RelayConfiguration.launchInputs(c, dir) { FipsIngress(error = com.nostrvault.fips.FipsBridge.ERR_START) }.env
        assertEquals("wss://web.example.com", env["MAC_RELAY_URL"])
        assertNull(RelayConfiguration.macMeshRelay)
    }

    /** L1: a restart still draining when the wait ends keeps the hand-over for the start it makes later. */
    @Test fun aRestartThatTimedOutKeepsTheHandOver() {
        val c = config(slot = "https://web.example.com", devices = listOf(mac(macA)), fips = true).takingInDesktopVaultSlot(ownNpub = null)
        val job = MeshVaultDial.afterStart(c, latest = { c }, relayRunning = { true }, restart = { false },
            ingress = { FipsIngress(url = ingressBase) })
        kotlinx.coroutines.runBlocking { job!!.join() }
        assertEquals(RelayConfiguration.MacMeshRelay(macA, meshURL), RelayConfiguration.pendingMeshRelay)
    }

    /** L3: a hand-over left by a restart that never started goes stale, so a much later start dials instead of taking it. */
    @Test fun aStaleHandOverIsNotTaken() {
        val found = RelayConfiguration.MacMeshRelay(macA, meshURL)
        RelayConfiguration.pendingMeshRelay = found
        val now = System.currentTimeMillis()
        assertEquals(found, RelayConfiguration.freshHandOver(now))
        assertNull(RelayConfiguration.freshHandOver(now + RelayConfiguration.HAND_OVER_MAX_AGE_MS + 1))
    }
}
