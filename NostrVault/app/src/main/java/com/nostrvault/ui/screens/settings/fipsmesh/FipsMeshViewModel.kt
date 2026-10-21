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
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.CoroutineScope
import com.nostrvault.di.ApplicationScope
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
    @ApplicationScope private val appScope: CoroutineScope,
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

    /** Add a device: into the allowlist, and the home vault when that is its role. -> false when not a mesh address. */
    fun addDevice(npub: String, role: DeviceRole, name: String): Boolean {
        val own = mesh.status.value.npub
        if (!MyDevicesRules.isMeshNpub(npub) || npub == own) return false
        change { cfg -> MyDevicesRules.add(cfg.fipsPeers, cfg.homeVaultNpub, cfg.fipsMesh.devices, own, npub, role, name) }
        return true
    }

    fun removeDevice(npub: String) =
        change { cfg -> MyDevicesRules.remove(cfg.fipsPeers, cfg.homeVaultNpub, cfg.fipsMesh.devices, npub) }

    /** Name and switches on the device page. Synchronous, so a save as the page closes is not lost with its scope. */
    fun updateDevice(npub: String, change: (FipsDevice) -> FipsDevice) {
        configStore.update { cfg ->
            val labels = cfg.fipsMesh.devices
            val updated = if (labels.any { it.npub == npub }) labels.map { if (it.npub == npub) change(it) else it }
            else labels + change(FipsDevice(npub, role = if (npub == cfg.homeVaultNpub) DeviceRole.HOME_VAULT else DeviceRole.PHONE))
            cfg.copy(fipsMesh = cfg.fipsMesh.copy(devices = updated))
        }
    }

    fun updateSettings(change: (FipsMeshSettings) -> FipsMeshSettings) {
        configStore.update { it.copy(fipsMesh = change(it.fipsMesh)) }
    }

    fun setFinderRelays(relays: List<String>) = guarded { mesh.setAdvanced(relays, configStore.config.value.fipsMesh.middleServer) }
    fun setMiddleServer(key: String) = guarded { mesh.setAdvanced(configStore.config.value.fipsMesh.finderRelays, key) }
    fun resetAdvanced() = guarded { mesh.setAdvanced(emptyList(), FipsMeshSettings.MIDDLE_NONE) }

    /**
     * Apply one My Devices change, start to finish. On the app's scope, not this screen's: Remove closes the device
     * page at once, and a cancelled half-change would leave a device out of the allowlist but still the home vault.
     * One at a time, each read from the config as the one before left it, so quick taps are queued, not dropped.
     */
    private fun change(compute: (com.nostrvault.relay.HavenConfig) -> MyDevicesRules.Change?) {
        appScope.launch {
            devicesLock.withLock {
                _busy.value = true
                try {
                    val before = configStore.config.value
                    val change = compute(before) ?: return@withLock
                    configStore.updateAsync { it.copy(fipsMesh = it.fipsMesh.copy(devices = change.labels)) }
                    if (change.peers != before.fipsPeers) mesh.setPeers(change.peers)
                    if (change.homeVault != before.homeVaultNpub) {
                        homeVault.setHomeVault(change.homeVault)
                        // This phone lists its home vault in the owner's 10063; a changed one drops the old entry.
                        nostrService.publishServerList(dropMesh = before.homeVaultNpub?.takeIf { it != change.homeVault })
                    }
                } finally {
                    _busy.value = false
                }
            }
        }
    }

    /** A mesh action (start, stop, restart for a setting) runs to the end even if the page closes: a restart cut
     *  between stop and start would leave the mesh off. A tap while one runs is ignored, as before. */
    private fun guarded(block: suspend () -> Unit) {
        if (_busy.value) return
        appScope.launch {
            _busy.value = true
            try { block() } finally { _busy.value = false }
        }
    }

    private companion object {
        /** Shared by every FIPS Mesh page: the list page and a device page each have their own view model. */
        val devicesLock = kotlinx.coroutines.sync.Mutex()
    }
}
