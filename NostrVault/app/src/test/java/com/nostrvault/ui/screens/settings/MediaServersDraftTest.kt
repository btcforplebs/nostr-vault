package com.nostrvault.ui.screens.settings

import com.nostrvault.fips.DeviceRole
import com.nostrvault.fips.FipsDevice
import com.nostrvault.fips.FipsMeshSettings
import com.nostrvault.fips.MediaServerVaults
import com.nostrvault.relay.HavenConfig
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Media Servers Save (Logen via Tod, 2026-11-08): Add / Take off on typed servers and Your Vaults only change the list
 * on screen; Save stores it and publishes the 10063 once; Back with unsaved changes asks Save / Discard.
 */
class MediaServersDraftTest {
    private val mac = "npub1qgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpq2yz0cn"
    private val kiosk = "npub1qvpsxqcrqvpsxqcrqvpsxqcrqvpsxqcrqvpsxqcrqvpsxqcrqvps0km4w3"
    private val config = HavenConfig(
        blossomMirrors = listOf("https://a.example"),
        fipsPeers = listOf(mac, kiosk),
        homeVaultNpub = kiosk,
        fipsMesh = FipsMeshSettings(devices = listOf(FipsDevice(mac, DeviceRole.MAC, name = "Studio Mac"), FipsDevice(kiosk, DeviceRole.HOME_VAULT))),
    )
    private val opened = MediaServersDraft(config.blossomMirrors)

    @Test fun `typed and suggested servers change only the list on screen`() {
        val d = opened.addMirror(" b.example ").addMirror("https://c.example").removeMirror("https://a.example")
        assertEquals(listOf("https://b.example", "https://c.example"), d.mirrors)
        assertEquals(listOf("https://a.example"), d.savedMirrors)
        assertEquals(3, d.changeCount)
        // Blank or already there: nothing changes.
        assertEquals(d, d.addMirror("  ").addMirror("b.example"))
        // Putting it back is no change.
        assertFalse(opened.removeMirror("https://a.example").addMirror("a.example").hasChanges)
    }

    @Test fun `vault Add and Take off wait for Save, and undoing leaves nothing to save`() {
        val d = opened.setVault(kiosk, list = true, listedNow = false).setVault(mac, list = false, listedNow = true)
        assertEquals(2, d.changeCount)
        assertEquals(mapOf(kiosk to true, mac to false), d.vaults)
        assertFalse(d.setVault(kiosk, list = false, listedNow = false).vaults.containsKey(kiosk))
        // The rows show the draft; the stored config is untouched until Save.
        val published = listOf("fipsmesh://$mac/")
        assertEquals(listOf(false, true), MediaServerVaults.rows(config, published).map { it.listed })
        assertEquals(listOf(true, false), MediaServerVaults.rows(d.applyVaults(config), published).map { it.listed })
        assertEquals(emptyList<String>(), config.serverListAddMesh)
    }

    @Test fun `Save stores servers and vault choices together`() {
        val d = opened.addMirror("b.example").setVault(kiosk, list = true, listedNow = false)
        val stored = d.saveInto(config, nowSeconds = 42)
        assertEquals(listOf("https://a.example", "https://b.example"), stored.blossomMirrors)
        assertEquals(42L, stored.blossomMirrorsUpdatedAt)
        assertEquals(listOf(kiosk), stored.serverListAddMesh)
        assertFalse(d.saved().hasChanges)
        assertEquals(d.mirrors, d.saved().savedMirrors)
        // Vault-only Save leaves the typed servers' date alone.
        assertEquals(null, opened.setVault(kiosk, true, false).saveInto(config, 42).blossomMirrorsUpdatedAt)
    }

    @Test fun `Discard goes back to the saved list`() {
        val d = opened.addMirror("b.example").setVault(kiosk, true, false).discarded()
        assertEquals(opened, d)
    }

    @Test fun `another device's list is followed only without unsaved edits`() {
        assertEquals(listOf("https://z.example"), opened.savedMirrorsChanged(listOf("https://z.example")).mirrors)
        val edited = opened.addMirror("b.example")
        assertEquals(edited, edited.savedMirrorsChanged(listOf("https://z.example")))
    }

    // Source checks on the screen: the draft is only useful if the view model routes every edit through it.
    private val screen = File("src/main/java/com/nostrvault/ui/screens/settings/BlossomSettingsScreen.kt").readText()
    private fun body(fn: String) = screen.substringAfter("fun $fn(").substringBefore("\n    }\n").substringBefore("\n\n    ")

    @Test fun `only Save publishes or stores the list`() {
        assertEquals(1, Regex("publishServerList").findAll(screen).count())
        assertTrue(body("save").contains("nostrService.publishServerList("))
        assertTrue(body("save").contains("configStore.update { draft.saveInto("))
        for (fn in listOf("setVaultListed", "addMirror", "addSuggested", "removeMirror", "discard")) {
            val b = body(fn)
            assertFalse("$fn publishes", Regex("""\.publish\w*\(""").containsMatchIn(b))
            assertFalse("$fn stores", b.contains("configStore.update"))
            assertTrue("$fn edits the draft", b.contains("_draft.value"))
        }
        assertFalse("no publish-on-every-change helper", screen.contains("saveAndPublish"))
        assertTrue(screen.contains("bottomBar = { MediaServersSaveBar(changes, colors.primary, viewModel::save) }"))
    }

    @Test fun `Back with unsaved changes asks Save or Discard`() {
        assertTrue(screen.contains("BackHandler(enabled = changes > 0) { leaving = true }"))
        assertTrue(screen.contains("IconButton(onClick = back)"))
        assertFalse("top bar Back skips the question", screen.contains("IconButton(onClick = onBack)"))
        assertTrue(screen.contains("viewModel.save(); onBack()"))
        assertTrue(screen.contains("viewModel.discard(); onBack()"))
    }
}
