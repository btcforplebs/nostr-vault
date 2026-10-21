package com.nostrvault.ui.screens.settings.fipsmesh

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.fips.DeviceRole
import com.nostrvault.fips.FipsDevice
import com.nostrvault.fips.FipsMeshManager
import com.nostrvault.fips.FipsMeshSettings
import com.nostrvault.fips.HomeVaultRules
import com.nostrvault.fips.HomeVaultSender
import com.nostrvault.fips.MyDevicesRules
import com.nostrvault.service.NostrService
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import javax.inject.Inject

/**
 * The FIPS Mesh screen and its pages (device, Advanced). One list both ways: My Devices is the mesh's allowlist
 * (fipsPeers), and the device marked Home vault also gets this phone's posts and media (homeVaultNpub).
 */
@HiltViewModel
class FipsMeshViewModel @Inject constructor(
    private val mesh: FipsMeshManager,
    private val configStore: ConfigStore,
    private val nostrService: NostrService,
    private val homeVault: HomeVaultSender,
) : ViewModel() {

    val status = mesh.status
    val lastError = mesh.lastError
    val isAvailable get() = mesh.isAvailable
    val shareRelay = mesh.shareRelay
    val serveLimit = mesh.serveLimitBytes
    val homeVaultState = homeVault.state

    private val _busy = MutableStateFlow(false)
    val busy = _busy.asStateFlow()

    val settings = configStore.config.map { it.fipsMesh }
        .stateIn(viewModelScope, SharingStarted.Eagerly, configStore.config.value.fipsMesh)

    val devices = combine(configStore.config, mesh.status) { cfg, st ->
        MyDevicesRules.list(cfg.fipsPeers, cfg.homeVaultNpub, cfg.fipsMesh.devices, st.peers)
    }.stateIn(viewModelScope, SharingStarted.Eagerly, emptyList())

    /** The owner's kiosks in their 10063 that are not in My Devices yet: offered in Add a Device. */
    val suggestions = combine(nostrService.serverLists, mesh.status, devices) { lists, st, devs ->
        HomeVaultRules.candidates(lists[nostrService.ownerHexPubkey].orEmpty(), st.npub)
            .filter { c -> devs.none { it.npub == c } }
    }.stateIn(viewModelScope, SharingStarted.Eagerly, emptyList())

    init {
        viewModelScope.launch { mesh.refresh() }
        nostrService.ownerHexPubkey.takeIf { it.isNotEmpty() }?.let { nostrService.fetchServerList(it) }
    }

    /** Re-read the mesh, and note when each device was last in reach. */
    suspend fun refresh() {
        mesh.refresh()
        val cfg = configStore.config.value
        val all = (cfg.fipsPeers + listOfNotNull(cfg.homeVaultNpub)).distinct()
        val seen = MyDevicesRules.seen(cfg.fipsMesh.devices, all, mesh.status.value.peers, System.currentTimeMillis() / 1000)
        if (seen != cfg.fipsMesh.devices) configStore.updateAsync { it.copy(fipsMesh = it.fipsMesh.copy(devices = seen)) }
    }

    fun setEnabled(enabled: Boolean) = guarded { if (enabled) mesh.start() else mesh.stop() }
    fun setShareRelay(enabled: Boolean) = guarded { mesh.setShareRelay(enabled) }
    fun setServeLimit(bytes: Long) = guarded { mesh.setServeLimit(bytes) }
    fun sendHomeVaultNow() = homeVault.drainSoon(userInitiated = true)

    /** Add a device: into the allowlist, and the home vault when that is its role. -> false when not added. */
    fun addDevice(npub: String, role: DeviceRole, name: String): Boolean {
        val cfg = configStore.config.value
        val change = MyDevicesRules.add(
            cfg.fipsPeers, cfg.homeVaultNpub, cfg.fipsMesh.devices, mesh.status.value.npub,
            npub, role, name, System.currentTimeMillis() / 1000,
        ) ?: return false
        apply(change)
        return true
    }

    fun removeDevice(npub: String) {
        val cfg = configStore.config.value
        apply(MyDevicesRules.remove(cfg.fipsPeers, cfg.homeVaultNpub, cfg.fipsMesh.devices, npub))
    }

    /** Name and switches on the device page. */
    fun updateDevice(npub: String, change: (FipsDevice) -> FipsDevice) = viewModelScope.launch {
        configStore.updateAsync { cfg ->
            val labels = cfg.fipsMesh.devices
            val updated = if (labels.any { it.npub == npub }) labels.map { if (it.npub == npub) change(it) else it }
            else labels + change(FipsDevice(npub, role = if (npub == cfg.homeVaultNpub) DeviceRole.HOME_VAULT else DeviceRole.PHONE))
            cfg.copy(fipsMesh = cfg.fipsMesh.copy(devices = updated))
        }
    }

    fun updateSettings(change: (FipsMeshSettings) -> FipsMeshSettings) = viewModelScope.launch {
        configStore.updateAsync { it.copy(fipsMesh = change(it.fipsMesh)) }
    }

    fun setFinderRelays(relays: List<String>) = guarded { mesh.setFinderRelays(relays) }

    private fun apply(change: MyDevicesRules.Change) = guarded {
        val before = configStore.config.value
        configStore.updateAsync { it.copy(fipsMesh = it.fipsMesh.copy(devices = change.labels)) }
        if (change.peers != before.fipsPeers) mesh.setPeers(change.peers)
        if (change.homeVault != before.homeVaultNpub) {
            homeVault.setHomeVault(change.homeVault)
            // This phone lists its home vault in the owner's 10063; a changed one drops the old entry.
            nostrService.publishServerList(dropMesh = before.homeVaultNpub?.takeIf { it != change.homeVault })
        }
    }

    private fun guarded(block: suspend () -> Unit) {
        if (_busy.value) return
        viewModelScope.launch {
            _busy.value = true
            try { block() } finally { _busy.value = false }
        }
    }
}
