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
import com.nostrvault.fips.MeshCopyStarter
import com.nostrvault.fips.MeshCopyV2
import com.nostrvault.fips.OtherVaultLink
import com.nostrvault.service.ImportResult
import com.nostrvault.service.RelayImportService
import kotlinx.coroutines.flow.first
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
 * "Copy from my other vault" as the No to setup's "New to Nostr Vault?" (§5a): this new phone plays B. It scans the other device's code, confirms in
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
    private val firstRunImport: com.nostrvault.service.FirstRunImport,
    private val otherVaultLink: OtherVaultLink,
    private val copyStarter: MeshCopyStarter,
    private val copyAccounts: com.nostrvault.fips.CopyAccountsSync,
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
        /** The other device couldn't be reached for a few minutes: [line], Try again, or go on to the relays. */
        data class CopyFailed(val name: String, val line: String) : Ui
        /** Copied, and the copy brought accounts this phone lacks: ask before setup goes on (Logen, 2026-11-06). */
        data class AskAccounts(val accounts: List<com.nostrvault.fips.CopyAccounts.Account>) : Ui
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
        // Any account the two share will do (Logen, 2026-11-06); only accounts this phone can sign for count (Tron, PR 1809).
        if (!MeshPairing.sharesAccount(p.owner, p.accountTags, p.code.value, configStore.signingAccountNpubs())) {
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
        if (!h.send(a.meshHex, MeshPairing.helloJson(aSecret, name, DeviceRole.PHONE, owner().orEmpty(), now(), configStore.signingAccountNpubs()))) return fallBack()
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

    /** The ask's answer: only [ticked] (npubs) are added, look-only; every offered account is settled. Then on. */
    fun answerAccounts(ticked: List<String>) {
        if (_ui.value !is Ui.AskAccounts) return
        copyAccounts.answer(ticked)
        _ui.value = Ui.Copied
    }

    /** Cancel or "They don't match", on any screen of the flow: back to the question, nothing stored. */
    fun giveUp() = reset()

    /** Back to the question (also once setup has acted on [Ui.FellBack]). */
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
     * The copy (docs/MESH_COPY_V2_CONTRACT.md): the zip copy when the other device serves it, its `COPY` lines as
     * [Ui.Copying]'s status. An other device without it (404), or a copy that stalls or fails, leaves today's way:
     * its vault becomes one more seed for the relay's own `setup` job, read from [BringItOver.START_DATE].
     */
    private fun startCopy(a: MeshPairing.Payload) {
        val name = MeshPairing.displayName(a.name)
        _ui.value = Ui.Copying(name)
        viewModelScope.launch {
            val url = copyStarter.dial(a.mesh) ?: return@launch run {
                otherVaultLink.close()
                fallBack()
            }
            when (val r = copyStarter.start(a.mesh, url, name)) {
                MeshCopyStarter.Result.Started -> if (followCopy(name)) return@launch
                is MeshCopyStarter.Result.Failed -> {
                    if (r.line.isNotEmpty()) notificationManager.showToast(r.line, PillTone.WARNING)
                    // Short of space here, or the other device is another account's: no copy from it at all.
                    if (MeshCopyV2.action(r.code) == MeshCopyV2.Action.STOP && r.code != "auth_refused") {
                        otherVaultLink.close()
                        return@launch quietFallBack()
                    }
                }
            }
            seedFromOtherVault(url)
        }
    }

    /**
     * The engine's copy, line by line: true once it is done (setup goes on; the relay service applies the settings it left). False when it
     * failed or no line came for [BringItOver.COPY_STALL_S]: the caller reads the other vault the old way.
     */
    private suspend fun followCopy(name: String): Boolean {
        var last = now()
        var seen: MeshCopyV2.Line? = null
        skipCopy = false
        while (true) {
            // Can't reach it: the starter keeps trying (that is not a stall), then says it failed.
            when (val u = copyStarter.unreachable.value) {
                MeshCopyV2.Retry.None -> Unit
                is MeshCopyV2.Retry.After -> {
                    last = now()
                    _ui.value = Ui.Copying(name, MeshCopyV2.unreachableLine(u, name).orEmpty())
                }
                MeshCopyV2.Retry.GaveUp -> {
                    last = now()
                    if (skipCopy) return false
                    _ui.value = Ui.CopyFailed(name, MeshCopyV2.unreachableLine(u, name).orEmpty())
                    delay(1000)
                    continue
                }
            }
            val l = copyStarter.progress.value
            if (l != null && l != seen) {
                seen = l
                last = now()
                _ui.value = Ui.Copying(name, MeshCopyV2.statusText(l, name))
                when (l.stage) {
                    "done" -> {
                        if (l.error.isNotEmpty()) notificationManager.showToast(MeshCopyV2.statusText(l, name), PillTone.NEUTRAL)
                        // The copy's accounts this phone lacks are asked about before setup goes on; none are added unasked.
                        val offered = copyAccounts.refreshOffer()
                        _ui.value = if (offered.isEmpty()) Ui.Copied else Ui.AskAccounts(offered)
                        return true
                    }
                    "failed" -> {
                        if (copyStarter.unreachable.value != MeshCopyV2.Retry.None) continue
                        MeshCopyV2.failedLine(l, name).takeIf { it.isNotEmpty() }?.let { notificationManager.showToast(it, PillTone.WARNING) }
                        return false
                    }
                }
            }
            if (BringItOver.isStalled(last, now())) return false
            delay(1000)
        }
    }

    /** The failed state's Continue: the relays, without the copy. */
    @Volatile private var skipCopy = false

    fun tryAgainCopy() {
        (_ui.value as? Ui.CopyFailed)?.let { _ui.value = Ui.Copying(it.name) }
        copyStarter.tryAgain()
    }

    fun continueWithoutCopy() {
        skipCopy = true
    }

    private suspend fun seedFromOtherVault(url: String) {
        configStore.update { it.copy(importStartDate = BringItOver.START_DATE) }
        firstRunImport.otherVault = url
        _ui.value = Ui.Copied
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
        if (_ui.value == Ui.Copied || _ui.value == Ui.FellBack || _ui.value is Ui.AskAccounts) return
        // One plain line, no error screen (§5a).
        notificationManager.showToast(BringItOver.FALLBACK_LINE, PillTone.NEUTRAL)
        quietFallBack()
    }

    /** On to the relays, the copy's own line already shown. */
    private fun quietFallBack() {
        if (_ui.value == Ui.Copied || _ui.value == Ui.FellBack || _ui.value is Ui.AskAccounts) return
        stopTicker()
        hello?.close()
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
    }
}
