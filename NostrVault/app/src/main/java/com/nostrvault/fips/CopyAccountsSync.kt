package com.nostrvault.fips

import android.content.Context
import android.util.Log
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.di.ApplicationScope
import com.nostrvault.relay.HavenBridge
import com.nostrvault.service.NostrService
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.launch
import java.io.File
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Keeps [CopyAccounts.FILE] in the relay root current with this device's accounts and names
 * (docs/MESH_COPY_V2_CONTRACT.md §3.4), and asks the person which accounts a copy or catch-up brought over to add
 * here. Twin of iOS `CopyAccountsSync.swift`.
 *
 * Logen's rule (2026-11-06): nothing is added on its own. The ticked ones become look-only accounts (npub only: no
 * nsec, no bunker, no signer), through AddAccountsC now and the whitelist file for the next relay start. Every
 * offered account is settled either way and never asked again.
 */
@Singleton
class CopyAccountsSync internal constructor(
    private val dataDir: () -> File,
    private val device: Device,
    private val settledStore: Settled,
    private val scope: CoroutineScope,
    private val nowS: () -> Long = { System.currentTimeMillis() / 1000 },
) {
    @Inject constructor(
        @ApplicationContext context: Context,
        configStore: ConfigStore,
        nostrService: dagger.Lazy<NostrService>,
        @ApplicationScope scope: CoroutineScope,
    ) : this(
        dataDir = { configStore.config.value.relayDataDir?.let(::File) ?: File(context.filesDir, "relay_data") },
        device = AppDevice(configStore, nostrService),
        settledStore = PrefsSettled(context),
        scope = scope,
    )

    /** What this class needs from the app, so the tests can stand in for it. */
    interface Device {
        /** Emits whenever the accounts or their names change. */
        fun changes(): Flow<Any?>
        /** Every account on this device, owner first (npubs). */
        fun accounts(): List<String>
        /** A display name for [hex], or empty. */
        fun name(hex: String): String
        /** AddAccountsC: how many were new, or -1 when refused (0 when the relay library isn't loaded). */
        fun addLive(json: String): Int
        /** Adds [npubs] here look-only (no key, no signer) and to the relay's whitelist file. */
        fun addLookOnly(npubs: List<String>)
    }

    /** Accounts never asked about again (hex). */
    interface Settled {
        var hexes: Set<String>
    }

    private val _offered = MutableStateFlow<List<CopyAccounts.Account>>(emptyList())
    /** The accounts to ask about now (empty: nothing to ask). */
    val offered: StateFlow<List<CopyAccounts.Account>> = _offered.asStateFlow()

    private val file get() = File(dataDir(), CopyAccounts.FILE)

    /** From app start: the file is rewritten whenever this device's accounts or their names change, and what a copy left is offered. */
    @OptIn(FlowPreview::class)
    fun start() {
        scope.launch(Dispatchers.IO) {
            device.changes().distinctUntilChanged().debounce(2_000).collect {
                writeOwn()
                refreshOffer()
            }
        }
    }

    // ---- The file ----

    private fun readFile(): List<CopyAccounts.Account> {
        val raw = runCatching { file.takeIf { it.exists() }?.readText() }.getOrNull() ?: return emptyList()
        return when (val c = CopyAccounts.check(raw)) {
            is CopyAccounts.Checked.Ok -> c.accounts
            is CopyAccounts.Checked.Refused -> emptyList<CopyAccounts.Account>().also { Log.w(TAG, "copied accounts not used: ${c.refusal.code}") }
        }
    }

    private fun ownHex(): Set<String> = device.accounts().mapNotNull(MeshPairing::npubHex).toSet()

    /** This device's accounts, owner first, named from their profiles. */
    private fun ownAccounts(): List<CopyAccounts.Account> = device.accounts().mapNotNull { npub ->
        val hex = MeshPairing.npubHex(npub) ?: return@mapNotNull null
        CopyAccounts.Account(MeshPairing.npub(hex), CopyAccounts.cleanName(device.name(hex)))
    }.distinctBy { it.npub }

    /** Writes the file when this device's accounts or names change. Never drops what a copy or catch-up merged in. */
    @Synchronized
    fun writeOwn() {
        val own = ownAccounts()
        if (own.isEmpty()) return
        // Own once, never offered back after it is removed here.
        settledStore.hexes = settledStore.hexes + ownHex()
        val existing = readFile()
        val next = CopyAccounts.ownFile(own, existing)
        if (next == existing) return
        val body = CopyAccounts.fileJson(next, nowS()) ?: return
        val f = file
        f.parentFile?.mkdirs()
        val tmp = File(f.parentFile, "${f.name}.partial")
        tmp.delete()
        tmp.createNewFile()
        MeshCopyStarter.ownerOnly(tmp)
        tmp.writeText(body)
        if (!tmp.renameTo(f)) tmp.delete()
    }

    // ---- The ask ----

    /** Reads what the engine merged in (after a copy or a catch-up) and offers what this device lacks and was never asked. */
    @Synchronized
    fun refreshOffer(): List<CopyAccounts.Account> =
        CopyAccounts.offered(readFile(), ownHex(), settledStore.hexes).also { _offered.value = it }

    /**
     * The person's answer: [ticked] (npubs) become look-only accounts here; every offered one, ticked or not, is
     * settled and not asked again. Nothing that was not offered is ever added.
     */
    @Synchronized
    fun answer(ticked: Collection<String>) {
        val a = CopyAccounts.answer(_offered.value, ticked)
        settledStore.hexes = settledStore.hexes + a.settle
        _offered.value = emptyList()
        val json = CopyAccounts.addJson(a.add, nowS()) ?: return
        // Live now, without a relay restart.
        if (device.addLive(json) < 0) {
            Log.e(TAG, "accounts not added: the list was refused")
            return
        }
        // And here, for the next relay start. Look-only: the npub is all that is stored.
        device.addLookOnly(a.add.map { it.npub })
        Log.i(TAG, "added ${a.add.size} brought-over account(s), look-only")
    }

    private class AppDevice(private val configStore: ConfigStore, private val nostr: dagger.Lazy<NostrService>) : Device {
        override fun changes(): Flow<Any?> = combine(configStore.config, nostr.get().profiles) { c, p ->
            c.allAccountNpubs().map { n -> n to MeshPairing.npubHex(n)?.let { p[it]?.bestName } }
        }
        override fun accounts() = configStore.config.value.allAccountNpubs()
        override fun name(hex: String): String =
            runCatching { nostr.get().profiles.value[hex]?.bestName }.getOrNull().orEmpty()
        override fun addLive(json: String): Int =
            if (HavenBridge.isLoaded) runCatching { HavenBridge.addAccounts(json) }.getOrDefault(-1) else 0
        override fun addLookOnly(npubs: List<String>) {
            // As Settings › Accounts › add a view-only npub (AccountSettingsViewModel.addViewOnly).
            for (n in npubs) {
                val cfg = configStore.config.value
                if (n == cfg.ownerNpub || n in cfg.accountNpubs) continue
                configStore.addAccount(n)
                configStore.setSigningMode(n, "local")
            }
            configStore.update { it.copy(broughtAccountNpubs = (it.broughtAccountNpubs + npubs).distinct()) }
        }
    }

    private class PrefsSettled(context: Context) : Settled {
        private val prefs = context.getSharedPreferences("copy_accounts", Context.MODE_PRIVATE)
        override var hexes: Set<String>
            get() = prefs.getStringSet("settled", emptySet()).orEmpty().toSet()
            set(v) { prefs.edit().putStringSet("settled", v.toSet()).apply() }
    }

    private companion object {
        const val TAG = "CopyAccountsSync"
    }
}
