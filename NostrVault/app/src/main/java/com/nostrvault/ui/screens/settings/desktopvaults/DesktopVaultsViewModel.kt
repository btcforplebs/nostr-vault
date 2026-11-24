package com.nostrvault.ui.screens.settings.desktopvaults

import android.content.Context
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.fips.DeviceRole
import com.nostrvault.fips.FipsDevice
import com.nostrvault.relay.DesktopVault
import com.nostrvault.relay.DesktopVaultKind
import com.nostrvault.relay.DesktopVaultList
import com.nostrvault.relay.DesktopVaultPath
import com.nostrvault.relay.DesktopVaultsEditing
import com.nostrvault.relay.DesktopVaultsLists
import com.nostrvault.relay.DesktopVaultsRules
import com.nostrvault.relay.MacSync
import com.nostrvault.relay.OwnMeshNpub
import com.nostrvault.relay.addingDesktopVault
import com.nostrvault.relay.deletingDesktopVault
import com.nostrvault.relay.desktopVaultsInEffect
import com.nostrvault.relay.withDesktopVaults
import com.nostrvault.service.DesktopVaultListEdit
import com.nostrvault.service.NostrService
import dagger.hilt.android.lifecycle.HiltViewModel
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import javax.inject.Inject

/**
 * The Desktop Vaults screens' state and edits (Desktop Vaults P7, PLANS/NV_DESKTOP_VAULTS_PLAN.md §2.7). Every edit
 * goes through [ConfigStore.update], which takes the slot in again and hands the relay its new MAC_RELAY_URL /
 * DESKTOP_VAULT_URLS (it restarts only when those changed). A list switch, a drag and Delete's unlist go through
 * [DesktopVaultListEdit]. iOS: the `@State` of `DesktopVaultsSettingsView` / `DesktopVaultDetailView` and
 * `ConfigService.editDesktopVaults`.
 */
@HiltViewModel
class DesktopVaultsViewModel @Inject constructor(
    private val configStore: ConfigStore,
    private val nostr: NostrService,
    @ApplicationContext private val context: Context,
) : ViewModel() {
    val vaults: StateFlow<List<DesktopVault>> = configStore.config.map { it.desktopVaultsInEffect }
        .stateIn(viewModelScope, SharingStarted.Eagerly, configStore.config.value.desktopVaultsInEffect)

    /** The newest published lists, read when a Vault's page opens. A list missing here didn't load. */
    private val _lists = MutableStateFlow<Map<DesktopVaultList, List<List<String>>>>(emptyMap())
    val lists = _lists.asStateFlow()
    private val _loading = MutableStateFlow(false)
    val loading = _loading.asStateFlow()

    /** Switches waiting on a publish, as "path|list". */
    private val _busy = MutableStateFlow<Set<String>>(emptySet())
    val busy = _busy.asStateFlow()

    /** What the last drag's republish said, when it didn't all go out. */
    private val _orderLine = MutableStateFlow<String?>(null)
    val orderLine = _orderLine.asStateFlow()

    fun vault(id: String): DesktopVault? = vaults.value.firstOrNull { it.id == id }

    fun load() {
        viewModelScope.launch {
            _loading.value = true
            val read = mutableMapOf<DesktopVaultList, List<List<String>>>()
            for (list in DesktopVaultList.entries) DesktopVaultListEdit.current(nostr, list)?.let { read[list] = it }
            _lists.value = read
            _loading.value = false
        }
    }

    // ── The list ──

    /** Paired desktops that are not a Vault now (their Vault was deleted). */
    fun pairedLeftOut(): List<FipsDevice> {
        val vaults = vaults.value
        return configStore.config.value.fipsMesh.devices.filter { d -> d.role == DeviceRole.MAC && vaults.none { it.meshNpub == d.npub } }
    }

    /** Adds a Vault; null when it went, else why not. */
    fun add(name: String, typed: String, meshNpub: String?, kind: DesktopVaultKind): String? =
        when (val r = DesktopVaultsEditing.adding(name, typed, meshNpub, kind, vaults.value, OwnMeshNpub.value)) {
            is DesktopVaultsEditing.Added.Refused -> r.why.message
            is DesktopVaultsEditing.Added.Ok -> {
                configStore.update { it.addingDesktopVault(r.vault) }
                null
            }
        }

    /** Moves the Vault at [from] to [to], saves the order, and moves its entries in the public lists (rule 2). */
    fun move(from: Int, to: Int) {
        val now = vaults.value
        val moved = DesktopVaultsEditing.moving(now, from, to)
        if (moved.map { it.id } == DesktopVaultsRules.ordered(now).map { it.id }) return
        configStore.update { it.withDesktopVaults(moved) }
        _orderLine.value = null
        viewModelScope.launch {
            _orderLine.value = DesktopVaultListEdit.reorder(nostr, moved)?.let { "Order saved here, but a list wasn't changed: $it" }
        }
    }

    // ── One Vault ──

    fun rename(id: String, name: String) {
        val trimmed = name.trim()
        if (vault(id)?.name == trimmed) return
        configStore.update { it.withDesktopVaults(DesktopVaultsEditing.renaming(id, trimmed, it.desktopVaultsInEffect)) }
    }

    /** Changes a Vault's web address; null when that went, else why not. */
    fun setAddress(id: String, typed: String): String? {
        val cfg = configStore.config.value
        return when (val r = DesktopVaultsEditing.changingAddress(id, typed, cfg.desktopVaultsInEffect, cfg.desktopVaultsRemoved)) {
            is DesktopVaultsEditing.AddressChange.Refused -> r.why.message
            is DesktopVaultsEditing.AddressChange.Ok -> {
                configStore.update { it.copy(desktopVaults = r.edited.vaults, desktopVaultsRemoved = r.edited.removed) }
                null
            }
        }
    }

    /**
     * The address can change only once every list is read and none names it: a list still loading (or that failed
     * to) may name the old host, which would be left listed with no Vault (Tron should-fix 4 on #2511). Null: it may.
     */
    fun addressLockedLine(vault: DesktopVault): String? {
        val lists = _lists.value
        return when {
            _loading.value -> "Checking your public lists…"
            DesktopVaultList.entries.any { it !in lists } -> "Your public lists couldn't be read, so the address can't change now."
            DesktopVaultList.entries.any { l -> lists[l]?.let { DesktopVaultsLists.isListed(vault, DesktopVaultPath.WEB, l, it) } == true } ->
                "Turn its public lists off below first to change the address."
            else -> null
        }
    }

    /** The Vault's last copy, from its own status file; null for a mesh-only Vault. */
    suspend fun statusLine(vault: DesktopVault): String? {
        val https = vault.httpsURL ?: return null
        val url = "wss://" + DesktopVaultsRules.base(https)
        val status = withContext(Dispatchers.IO) { MacSync.read(File(context.filesDir, "relay_data"), url) }
        val view = MacSync.view(status, url, checkRequested = false, nowSec = System.currentTimeMillis() / 1000)
        return listOfNotNull(view.headline, view.detail).joinToString(" · ")
    }

    // ── Switches (§2.4) ──

    fun isListed(vault: DesktopVault, path: DesktopVaultPath, list: DesktopVaultList): Boolean =
        _lists.value[list]?.let { DesktopVaultsLists.isListed(vault, path, list, it) } ?: false

    /** One switch; the line it snaps back with, or null when it went. */
    fun set(on: Boolean, vault: DesktopVault, path: DesktopVaultPath, list: DesktopVaultList, done: (String?) -> Unit) {
        if (on && path == DesktopVaultPath.WEB && vault.httpsURL?.let(DesktopVaultsEditing::isIPHost) == true) {
            done(DesktopVaultsEditing.IP_HOST_MESSAGE)
            return
        }
        val key = "$path|$list"
        _busy.update { it + key }
        viewModelScope.launch {
            val outcome = DesktopVaultListEdit.set(nostr, on, vault, path, list)
            _busy.update { it - key }
            outcome.message?.let { return@launch done(it) }
            // Show the change now; the relays echo it back later.
            val next = DesktopVaultsLists.switching(on, vault, path, list, _lists.value[list], vaults.value)
            if (next is com.nostrvault.relay.DesktopVaultListChange.Tags) _lists.update { it + (list to next.tags) }
            done(null)
        }
    }

    // ── Delete (rule 5) ──

    /** Deletes the Vault, after taking it out of the lists when [unlist]. [done] gets null when it went, else why not. */
    fun delete(vault: DesktopVault, unlist: Boolean, done: (String?) -> Unit) {
        if (!unlist) {
            removeHere(vault)
            return done(null)
        }
        viewModelScope.launch {
            when (val outcome = DesktopVaultListEdit.remove(nostr, vault)) {
                DesktopVaultListEdit.Outcome.Published, DesktopVaultListEdit.Outcome.Unchanged -> {
                    removeHere(vault)
                    done(null)
                }
                else -> {
                    if (outcome is DesktopVaultListEdit.Outcome.PartlyPublished) load()
                    done((outcome.message ?: DesktopVaultListEdit.NOT_LOADED_MESSAGE) + " The Vault was not deleted.")
                }
            }
        }
    }

    private fun removeHere(vault: DesktopVault) {
        configStore.update { it.deletingDesktopVault(vault.id) }
        // Its media entry is no longer this phone's to drop: after "No, leave my lists" a later Media Servers Save
        // must keep it (should-fix 3 on #2511).
        vault.hostKey?.let { host -> viewModelScope.launch(Dispatchers.IO) { DesktopVaultListEdit.forgetManagedServer(nostr, host) } }
    }
}
