package com.nostrvault.fips

import com.nostrvault.fips.CopyAccounts.Account
import com.nostrvault.relay.HavenConfig
import com.nostrvault.relay.RelayConfiguration
import com.nostrvault.ui.screens.CopyAccountsAsk
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** Where the ask and the any-account rule are wired in, and what reaches the relay's whitelist (source checks). */
class CopyAccountsWiringTest {
    private val main = File("src/main/java/com/nostrvault")
    private fun source(path: String) = File(main, path).readText()

    /** The text of [fn]'s body, up to [length] characters after its signature. */
    private fun body(text: String, fn: String, length: Int = 1400): String {
        val at = text.indexOf(fn)
        assertTrue(fn, at >= 0)
        return text.substring(at + fn.length).take(length)
    }

    private val owner = "npub1fsgzj6t7udv8zhf6zj32mkqhcjcpv52yph5qsdcl0qt94jgdckqs4yjc3w"
    private val other = "npub13evkv42fprxqfpqdp966kn2cwpjrk9jflp08yelkkue20g977wpsv6pcap"
    private val third = "npub1ks0t9yldwmqlr2k8jnm25gs92za45mp5rhwtkk0r0wlz9wg688zs99ny60"

    @Test
    fun `the ask hands on only the ticked, nothing to start`() {
        val list = listOf(Account(other), Account(third))
        assertEquals(emptyList<String>(), CopyAccountsAsk.chosen(list, emptySet()))
        val ticked = CopyAccountsAsk.toggle(emptySet(), third)
        assertEquals(listOf(third), CopyAccountsAsk.chosen(list, ticked))
        assertEquals(emptyList<String>(), CopyAccountsAsk.chosen(list, CopyAccountsAsk.toggle(ticked, third)))
        // Not on the list: never handed on.
        assertEquals(emptyList<String>(), CopyAccountsAsk.chosen(list, setOf(owner)))
        val view = source("ui/screens/setupwizard/CopyAccountsAskView.kt")
        assertTrue(view.contains("mutableStateOf(emptySet<String>())"))
        assertTrue(view.contains("onClick = { onAnswer(emptyList()) }"))
    }

    @Test
    fun `the whitelist file holds the ticked accounts still on this device, nothing else`() {
        val c = HavenConfig(ownerNpub = owner, accountNpubs = listOf(other, third), broughtAccountNpubs = listOf(third, owner, "npub1gone"))
        assertEquals(listOf(third), RelayConfiguration.whitelistNpubs(c))
        assertEquals(emptyList<String>(), RelayConfiguration.whitelistNpubs(HavenConfig(ownerNpub = owner, accountNpubs = listOf(other))))
        assertTrue(source("relay/RelayConfiguration.kt").contains("write(\"WHITELISTED_NPUBS_FILE\", WHITELIST_FILE_NAME, whitelistNpubs(config))"))
    }

    /** Only the answer calls AddAccountsC, and it stores npubs only: no key, signer or bunker. */
    @Test
    fun `nothing but the ticked answer adds an account`() {
        val callers = main.walkTopDown().filter { it.extension == "kt" && it.readText().contains("HavenBridge.addAccounts(") }.map { it.name }.toList()
        assertEquals(listOf("CopyAccountsSync.kt"), callers)
        val sync = source("fips/CopyAccountsSync.kt")
        val answer = body(sync, "fun answer(ticked: Collection<String>) {", 900)
        assertTrue(answer.contains("CopyAccounts.answer(_offered.value, ticked)"))
        assertTrue(answer.contains("CopyAccounts.addJson(a.add"))
        assertTrue(answer.contains("device.addLookOnly(a.add.map { it.npub })"))
        val lookOnly = body(sync, "override fun addLookOnly(npubs: List<String>) {", 700)
        for (text in listOf(answer, lookOnly)) {
            for (banned in listOf("Credential", "Nsec", "nsec", "Bunker", "bunker", "Keystore", "publish", "amber")) {
                assertFalse(banned, text.contains(banned))
            }
        }
        assertTrue(lookOnly.contains("configStore.setSigningMode(n, \"local\")"))
        val jni = File("src/main/java/com/nostrvault/relay/HavenBridgeJNI.c").readText()
        assertTrue(jni.contains("extern int AddAccountsC(char* accountsJSON);"))
        assertTrue(jni.contains("Java_com_nostrvault_relay_HavenBridge_addAccounts"))
    }

    @Test
    fun `a finished copy offers, setup asks before it goes on, and the app asks later`() {
        val service = source("relay/RelayForegroundService.kt")
        assertTrue(body(service, "if (meshCopy.onLogLine(line)?.stage == \"done\") {", 300).contains("copyAccounts.refreshOffer()"))
        val vm = source("ui/screens/setupwizard/OtherDeviceViewModel.kt")
        val done = body(vm, "\"done\" -> {", 700)
        assertTrue(done.contains("copyAccounts.refreshOffer()"))
        assertTrue(done.contains("if (offered.isEmpty()) Ui.Copied else Ui.AskAccounts(offered)"))
        assertTrue(body(vm, "fun answerAccounts(ticked: List<String>) {", 200).contains("copyAccounts.answer(ticked)"))
        assertTrue(source("ui/screens/setupwizard/OtherDeviceFlow.kt").contains("CopyAccountsAskView(s.accounts, onAnswer = viewModel::answerAccounts)"))
        assertTrue(source("MainActivity.kt").contains("CopyAccountsAskSheet(copyAccountsSync, enabled = config.hasCompletedSetup)"))
        assertTrue(source("NostrVaultApp.kt").contains("copyAccountsSync.start()"))
    }

    /** Both pairing flows use the any-account rule on signing accounts only, and send them. */
    @Test
    fun `pairing links on any shared signing account`() {
        val pair = source("ui/screens/pairing/PairDeviceViewModel.kt")
        assertTrue(pair.contains("matchAnyAccount = true"))
        assertTrue(pair.contains("MeshPairing.sharesAccount(p.owner, p.accountTags, p.code.value, accounts())"))
        assertTrue(pair.contains("MeshPairing.Code.Secret(secret), accounts())"))
        assertTrue(pair.contains("now(), accounts()))"))
        assertTrue(pair.contains("private fun accounts(): List<String> = configStore.signingAccountNpubs()"))
        assertFalse(pair.contains("MeshPairing.ownerCheck("))
        assertFalse("look-only accounts never reach pairing", pair.contains("allAccountNpubs"))
        assertTrue("B's code carries no accounts", pair.contains("MeshPairing.Code.Echo(aSecret, bSecret))"))
        val setup = source("ui/screens/setupwizard/OtherDeviceViewModel.kt")
        assertTrue(setup.contains("MeshPairing.sharesAccount(p.owner, p.accountTags, p.code.value, configStore.signingAccountNpubs())"))
        assertTrue(setup.contains("now(), configStore.signingAccountNpubs())"))
        assertFalse(setup.contains("MeshPairing.ownerCheck("))
        val store = body(source("data/local/ConfigStore.kt"), "fun signingAccountNpubs(): List<String> {", 600)
        assertTrue(store.contains("MeshPairing.signingAccounts(cfg.ownerNpub, cfg.allAccountNpubs())"))
        assertTrue(store.contains(".getOrDefault(false)"))
    }
}
