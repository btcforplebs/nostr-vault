package com.nostrvault.ui.screens

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.di.ApplicationScope
import com.nostrvault.fips.DeviceRole
import com.nostrvault.fips.FipsMeshManager
import com.nostrvault.fips.HomeVaultSender
import com.nostrvault.fips.MeshPairing
import com.nostrvault.fips.MeshPairingHello
import com.nostrvault.fips.MeshPairingJoiner
import com.nostrvault.fips.MyDevicesRules
import com.nostrvault.service.serverListDropsAfter
import com.nostrvault.ui.screens.pairing.PairDeviceViewModel
import com.nostrvault.fips.FipsBridge
import com.nostrvault.relay.RelayConfiguration
import com.nostrvault.service.ImportResult
import com.nostrvault.service.RelayImportService
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withContext
import com.nostrvault.ui.notification.NotificationManager
import com.nostrvault.ui.notification.PillTone
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.withLock
import javax.inject.Inject

/**
 * "Copy from my other vault" in setup's import choice (§5a): this new phone plays B. It scans the other device's code, confirms in
 * setup words, sends the hello, shows its own code and waits for the ack, on the phase-0 [MeshPairingJoiner] and lane
 * B's [MeshPairingHello]. Anything that doesn't link (no code in 3 minutes, a refusal it can't get past, the ack
 * window running out) ends in [Ui.FellBack], and setup carries on to the relays quietly. Twin of iOS
 * `BringItOverFlow.swift`.
 */
@HiltViewModel
class OtherDeviceViewModel @Inject constructor(
    private val mesh: FipsMeshManager,
    private val configStore: ConfigStore,
    private val homeVault: HomeVaultSender,
    private val relayImportService: RelayImportService,
    private val notificationManager: NotificationManager,
    @ApplicationScope private val appScope: CoroutineScope,
) : ViewModel() {

    sealed interface Ui {
        data object Ask : Ui
        data object Starting : Ui
        data class Scan(val note: String? = null) : Ui
        data class Confirm(val text: String, val shortAddress: String) : Ui
        data class ShowMyCode(val uri: String, val name: String) : Ui
        data class CheckWords(val words: List<String>, val shortAddress: String, val name: String, val tapped: Boolean) : Ui
        /** Linked; importing from the other device now ([status]: the import's own line). */
        data class Copying(val name: String, val status: String = "") : Ui
        /** Copied (all or part): setup goes on to the normal relay import. */
        data object Copied : Ui
        /** Didn't link: setup goes on to the relays with one plain line. */
        data object FellBack : Ui
    }

    private val _ui = MutableStateFlow<Ui>(Ui.Ask)
    val ui: StateFlow<Ui> = _ui.asStateFlow()

    private val _openCamera = MutableSharedFlow<Unit>(extraBufferCapacity = 1)
    val openCamera: SharedFlow<Unit> = _openCamera.asSharedFlow()

    private var hello: MeshPairingHello? = null
    private var joiner: MeshPairingJoiner? = null
    private var other: MeshPairing.Payload? = null
    private var ownHex: String? = null
    private var ticker: Job? = null
    private var wordsTapped = false

    /** "Copy from my other vault": a mesh key first (quietly), then the camera. */
    fun yes() {
        _ui.value = Ui.Starting
        viewModelScope.launch {
            val h = MeshPairingHello(configStore.config.value.fipsMesh.engineFinderRelays, viewModelScope).also { hello = it }
            var own = h.ownHex()
            if (own == null) {
                // Same queue as Mesh settings (Tron, #1706).
                mesh.changeLock.withLock { if (!mesh.status.value.running) mesh.start() }
                own = h.ownHex()
            }
            if (own == null) return@launch fallBack()
            ownHex = own
            _ui.value = Ui.Scan()
            _openCamera.tryEmit(Unit)
            val startedAt = now()
            tick { t ->
                val noCode = other == null && t - startedAt > BringItOver.SCAN_WAIT_S
                val confirmLeft = other != null && t - scannedAt > MeshPairing.ACK_WINDOW
                if (noCode || confirmLeft) fallBack()
            }
        }
    }

    fun onScanned(raw: String?) {
        val uri = raw?.trim().orEmpty()
        if (uri.isEmpty() || _ui.value !is Ui.Scan) return
        val own = ownHex ?: return
        val p = when (val parsed = MeshPairing.parse(uri, MeshPairing.npub(own))) {
            is MeshPairing.Parsed.Refused -> return run { _ui.value = Ui.Scan(MeshPairing.text(parsed.refusal)) }
            is MeshPairing.Parsed.Ok -> parsed.payload
        }
        if (p.code !is MeshPairing.Code.Secret) return run { _ui.value = Ui.Scan(PairDeviceViewModel.FIRST_CODE_TEXT) }
        // A new install has one account: anything else is another account's device.
        if (MeshPairing.ownerCheck(p.owner, owner(), listOfNotNull(owner())) != MeshPairing.OwnerCheck.Ok) {
            return run { _ui.value = Ui.Scan(MeshPairing.OTHER_OWNER_TEXT) }
        }
        when (val r = MeshPairing.roleCheck(p.mesh, p.role, existing())) {
            is MeshPairing.RoleCheck.RefuseOtherRole -> return run { _ui.value = Ui.Scan(MeshPairing.otherRoleText(r.role)) }
            MeshPairing.RoleCheck.AlreadyLinked, MeshPairing.RoleCheck.Add -> Unit
        }
        other = p
        _ui.value = Ui.Confirm(MeshPairing.roleConfirmText(p.role, p.name, setup = true), MeshPairing.shortAddress(p.mesh))
        scannedAt = now()
    }

    private var scannedAt = 0L

    /** "Add it": the hello, this phone's code, and the wait for the ack. */
    fun confirm() {
        if (_ui.value !is Ui.Confirm) return
        val a = other ?: return
        val own = ownHex ?: return
        val h = hello ?: return
        val aSecret = (a.code as? MeshPairing.Code.Secret)?.value ?: return
        val bSecret = MeshPairing.newSecret()
        val j = MeshPairingJoiner.start(a, own, bSecret, scannedAt) ?: return fallBack()
        joiner = j
        if (!h.open(::onAck)) return fallBack()
        val name = PairDeviceViewModel.deviceName()
        if (!h.send(a.meshHex, MeshPairing.helloJson(aSecret, name, DeviceRole.PHONE, owner().orEmpty(), now()))) return fallBack()
        val code = MeshPairing.build(MeshPairing.npub(own), name, DeviceRole.PHONE, owner().orEmpty(), MeshPairing.Code.Echo(aSecret, bSecret))
        _ui.value = Ui.ShowMyCode(code, MeshPairing.displayName(a.name))
        tick { t ->
            // The same hello again, byte for byte (Tron 3).
            if ((t - scannedAt) % (MeshPairingHello.RESEND_EVERY_MS / 1000) == 0L) h.resend()
            if (t - scannedAt > MeshPairing.ACK_WINDOW && j.state != MeshPairingJoiner.State.Linked) fallBack()
        }
    }

    private fun onAck(sender: String, plaintext: String) {
        val j = joiner ?: return
        val a = other ?: return
        when (j.receiveAck(sender, plaintext, now())) {
            MeshPairingJoiner.Outcome.Linked -> linked(a)
            MeshPairingJoiner.Outcome.WaitWords -> {
                val words = MeshPairing.checkWords(a.meshHex, ownHex.orEmpty(), (a.code as MeshPairing.Code.Secret).value) ?: return fallBack()
                _ui.value = Ui.CheckWords(words, MeshPairing.shortAddress(a.mesh), MeshPairing.displayName(a.name), wordsTapped)
            }
            MeshPairingJoiner.Outcome.Expired -> fallBack()
            else -> Unit
        }
    }

    fun wordsMatch() {
        val j = joiner ?: return
        val a = other ?: return
        wordsTapped = true
        when (j.confirmWords(now())) {
            MeshPairingJoiner.Outcome.Linked -> linked(a)
            MeshPairingJoiner.Outcome.Expired -> fallBack()
            else -> (_ui.value as? Ui.CheckWords)?.let { _ui.value = it.copy(tapped = true) }
        }
    }

    /** Cancel or "They don't match", on any screen of the flow: back to the import choice, nothing stored. */
    fun giveUp() = reset()

    /** Back to the import choice (also once setup has acted on [Ui.FellBack]). */
    fun reset() {
        stopTicker()
        hello?.close()
        hello = null
        joiner = null
        other = null
        ownHex = null
        wordsTapped = false
        _ui.value = Ui.Ask
    }

    private fun linked(a: MeshPairing.Payload) {
        stopTicker()
        val own = ownHex?.let(MeshPairing::npub)
        // Stored in the same queue as Mesh settings, reading the config inside it (Tron, #1706).
        appScope.launch { mesh.changeLock.withLock { store(own, a.mesh, a.role, a.name) } }
        startCopy(a)
    }

    /**
     * The copy: an import with the other device's vault as one more seed relay, from [BringItOver.START_DATE]. Only
     * haven-go's IMPORT_RESULT ends it (#1720 twin); 2 minutes with no progress is a stall.
     */
    private fun startCopy(a: MeshPairing.Payload) {
        val name = MeshPairing.displayName(a.name)
        _ui.value = Ui.Copying(name)
        viewModelScope.launch {
            val url = withContext(Dispatchers.IO) { vaultUrl(a.mesh) } ?: return@launch fallBack()
            configStore.update { it.copy(importStartDate = BringItOver.START_DATE) }
            // Refused when the vault is busy: a copy never joins a running import (its relay would be dropped).
            if (!relayImportService.importNotes(alsoFrom = listOf(url), otherVault = url)) return@launch fallBack()
            var last = relayImportService.importProgress.value to relayImportService.importStatusMessage.value
            var lastAt = now()
            relayImportService.isImporting.first { it }
            while (isActive) {
                delay(1000)
                if (!relayImportService.isImporting.value) {
                    val outcome = relayImportService.importOutcome.value ?: ImportResult.NO_RESULT
                    return@launch when (BringItOver.after(outcome)) {
                        BringItOver.Copy.Done -> { _ui.value = Ui.Copied }
                        else -> fallBack()
                    }
                }
                val current = relayImportService.importProgress.value to relayImportService.importStatusMessage.value
                (_ui.value as? Ui.Copying)?.let { _ui.value = it.copy(status = current.second) }
                if (current != last) {
                    last = current
                    lastAt = now()
                } else if (BringItOver.isStalled(lastAt, now())) {
                    return@launch fallBack()
                }
            }
        }
    }

    /** The other device's vault as a local ws:// address over the link, or null. Never logged. */
    private fun vaultUrl(meshNpub: String): String? {
        var ingress = FipsBridge.ingress(meshNpub)
        var waited = 0L
        while (ingress.error == FipsBridge.ERR_NOT_RUNNING && waited < MESH_WAIT_MS) {
            Thread.sleep(MESH_POLL_MS)
            waited += MESH_POLL_MS
            ingress = FipsBridge.ingress(meshNpub)
        }
        return ingress.url?.let(RelayConfiguration::meshWebsocketURL)
    }

    private suspend fun store(own: String?, npub: String, role: DeviceRole, name: String) {
        val before = configStore.config.value
        // Setup links for the account being set up, the owner.
        val change = MyDevicesRules.add(
            before.fipsPeers, before.homeVaultNpub, before.fipsMesh.devices, own, npub, role, name,
            linkedBy = owner().orEmpty(), ownerNpub = before.ownerNpub,
        ) ?: return
        configStore.updateAsync { it.copy(fipsMesh = it.fipsMesh.copy(devices = change.labels)) }
        if (change.peers != before.fipsPeers) mesh.setPeers(change.peers)
        if (change.homeVault != before.homeVaultNpub) homeVault.setHomeVault(change.homeVault)
        configStore.updateAsync { it.copy(serverListDropMesh = serverListDropsAfter(before, it)) }
    }

    private fun fallBack() {
        if (_ui.value == Ui.Copied || _ui.value == Ui.FellBack) return
        stopTicker()
        hello?.close()
        // One plain line, no error screen (§5a).
        notificationManager.showToast(BringItOver.FALLBACK_LINE, PillTone.NEUTRAL)
        _ui.value = Ui.FellBack
    }

    private fun owner(): String? = configStore.config.value.ownerNpub.takeIf { it.startsWith("npub1") }

    private fun existing(): List<Pair<String, DeviceRole>> {
        val cfg = configStore.config.value
        return MyDevicesRules.list(cfg.fipsPeers, cfg.homeVaultNpub, cfg.fipsMesh.devices, emptyList(), cfg.ownerNpub).map { it.npub to it.role }
    }

    private fun tick(onTick: (Long) -> Unit) {
        stopTicker()
        ticker = viewModelScope.launch {
            while (isActive) {
                delay(1000)
                onTick(now())
            }
        }
    }

    private fun stopTicker() {
        ticker?.cancel()
        ticker = null
    }

    override fun onCleared() {
        stopTicker()
        hello?.close()
    }

    private companion object {
        fun now() = System.currentTimeMillis() / 1000
        const val MESH_WAIT_MS = 20_000L
        const val MESH_POLL_MS = 1_000L
    }
}
