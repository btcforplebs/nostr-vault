package com.nostrvault.ui.screens.pairing

import android.os.Build
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.di.ApplicationScope
import com.nostrvault.fips.DeviceRole
import com.nostrvault.fips.FipsMeshManager
import com.nostrvault.fips.HomeVaultSender
import com.nostrvault.fips.MeshCopyStarter
import com.nostrvault.fips.MeshCopyV2
import com.nostrvault.fips.MeshPairing
import com.nostrvault.fips.MeshPairingHello
import com.nostrvault.fips.MeshPairingJoiner
import com.nostrvault.fips.MeshPairingSession
import com.nostrvault.fips.MyDevicesRules
import com.nostrvault.service.NostrService
import com.nostrvault.service.serverListDropsAfter
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
 * Two-scan device linking (PLANS/NV_TWO_SCAN_PAIRING_PLAN.md, docs/MESH_PAIRING_CONTRACT.md). This phone plays A
 * (shows its code first) or B (scans first). The rules are the phase-0 [MeshPairingSession] and [MeshPairingJoiner];
 * this only moves the screen between them, sends and reads the hello/ack, and stores the device at the very end.
 * Accept with check words is never offered here: a phone always has a camera (T3). Twin of iOS `PairDeviceFlow.swift`.
 */
@HiltViewModel
class PairDeviceViewModel @Inject constructor(
    private val mesh: FipsMeshManager,
    private val configStore: ConfigStore,
    private val nostrService: NostrService,
    private val homeVault: HomeVaultSender,
    private val copyStarter: MeshCopyStarter,
    @ApplicationScope private val appScope: CoroutineScope,
) : ViewModel() {

    sealed interface Ui {
        /** No mesh key yet: the mesh has to be turned on once. */
        data class NoMesh(val error: String? = null, val starting: Boolean = false) : Ui
        /** A: this phone's code, waiting for the other device to scan it. [note]: a hello that was turned away. */
        data class ShowCode(val uri: String, val secondsLeft: Long, val note: String? = null) : Ui
        /** A: the other device scanned us; scan its screen now. The camera opens on its own once. */
        data class ScanTheirs(val name: String, val note: String? = null) : Ui
        /** B: scan the other device's code. */
        data class ScanFirst(val note: String? = null) : Ui
        /** Either side: the person confirms the role in plain words before anything is stored (Tron 1). */
        data class ConfirmRole(val text: String, val shortAddress: String) : Ui
        /** B: this phone's own code, for the other device to scan; waiting for its ack. */
        data class ShowMyCode(val uri: String, val name: String, val secondsLeft: Long) : Ui
        /** B: A linked by Accept, so this side checks the words too (Tron 2). */
        data class CheckWords(val words: List<String>, val shortAddress: String, val name: String, val tapped: Boolean) : Ui
        data class SwitchAccount(val text: String, val npub: String) : Ui
        /**
         * [keepOpen]: A shares its vault for the other device's copy, so this device should stay open meanwhile.
         * [copy]: B, the copy from the device just linked (its own line), or empty.
         */
        data class Linked(val name: String, val already: Boolean = false, val keepOpen: Boolean = false, val copy: String = "") : Ui
        /** Over: expired, aborted or refused. Nothing was stored. */
        data class Stopped(val text: String) : Ui
    }

    private val _ui = MutableStateFlow<Ui>(Ui.NoMesh())
    val ui: StateFlow<Ui> = _ui.asStateFlow()

    /** One-shot: open the camera (A, after a good hello; B, when choosing to scan). */
    private val _openCamera = MutableSharedFlow<Unit>(extraBufferCapacity = 1)
    val openCamera: SharedFlow<Unit> = _openCamera.asSharedFlow()

    private var hello: MeshPairingHello? = null
    private var session: MeshPairingSession? = null
    private var joiner: MeshPairingJoiner? = null
    private var ownHex: String? = null
    private var ticker: Job? = null
    /** What waits for the role confirm: (npub, name, role), and whether this is A (send the ack) or B (send the hello). */
    private var pending: Pending? = null

    private sealed interface Pending {
        data class AddB(val npub: String, val name: String, val role: DeviceRole) : Pending
        data class JoinA(val a: MeshPairing.Payload, val scannedAt: Long) : Pending
    }

    /** B's side, once its hello is out: the code it showed and A's details, kept for storing on the ack. */
    private var joined: MeshPairing.Payload? = null
    private var joinedSecret: String? = null
    private var wordsTapped = false

    init { showCode() }

    // ---- A: show the code ----

    fun showCode() {
        reset()
        val h = newHello()
        val own = h.ownHex()
        if (own == null) {
            _ui.value = Ui.NoMesh()
            return
        }
        ownHex = own
        val now = now()
        val secret = MeshPairing.newSecret()
        // Any shared signing account links (Logen, 2026-11-06; Tron, PR 1809); the code carries them as salted tags.
        session = MeshPairingSession(secret, now, own, activeNpub(), accounts(), matchAnyAccount = true)
        val uri = MeshPairing.build(MeshPairing.npub(own), deviceName(), DeviceRole.PHONE, activeNpub().orEmpty(), MeshPairing.Code.Secret(secret), accounts())
        _ui.value = Ui.ShowCode(uri, MeshPairing.CODE_LIFETIME)
        h.open(::onIncoming)
        tick { t ->
            val s = session ?: return@tick
            when (val ui = _ui.value) {
                is Ui.ShowCode -> {
                    val left = MeshPairing.CODE_LIFETIME - (t - s.createdAt)
                    if (left <= 0 && s.state == MeshPairingSession.State.Waiting) stop(MeshPairing.EXPIRED_TEXT)
                    else _ui.value = ui.copy(secondsLeft = left.coerceAtLeast(0))
                }
                is Ui.ScanTheirs -> if (s.state == MeshPairingSession.State.Camera && t - helloAt > MeshPairing.SCAN_WINDOW) stop(MeshPairing.EXPIRED_TEXT)
                else -> Unit
            }
        }
    }

    private var helloAt = 0L

    private fun onIncoming(sender: String, plaintext: String) {
        session?.let { onHello(it, sender, plaintext) }
        joiner?.let { onAck(it, sender, plaintext) }
    }

    private fun onHello(s: MeshPairingSession, sender: String, plaintext: String) {
        when (val o = s.receiveHello(sender, plaintext, now())) {
            is MeshPairingSession.Outcome.Camera -> {
                helloAt = now()
                _ui.value = Ui.ScanTheirs(MeshPairing.displayName(o.hello.name))
                _openCamera.tryEmit(Unit)
            }
            MeshPairingSession.Outcome.Abort -> stop(MeshPairing.ABORT_TEXT)
            MeshPairingSession.Outcome.Expired -> stop(MeshPairing.EXPIRED_TEXT)
            is MeshPairingSession.Outcome.Refuse -> (_ui.value as? Ui.ShowCode)?.let {
                val owner = MeshPairing.parseHello(plaintext)?.owner
                val name = owner?.takeIf { o.why == "switchTo" }?.let(::accountName)
                _ui.value = it.copy(note = PairDeviceRules.helloRefusalText(o.why, name))
            }
            else -> Unit // a resend, or not for this code: keep waiting quietly
        }
    }

    // ---- Scanning (both sides) ----

    /** B: scan the other device's code instead of showing this one. */
    fun scanInstead() {
        reset()
        val own = newHello().ownHex()
        if (own == null) {
            _ui.value = Ui.NoMesh()
            return
        }
        ownHex = own
        _ui.value = Ui.ScanFirst()
        _openCamera.tryEmit(Unit)
    }

    fun onScanned(raw: String?) {
        val uri = raw?.trim().orEmpty()
        if (uri.isEmpty()) return // cancelled: the screen offers the camera again
        when (val ui = _ui.value) {
            is Ui.ScanTheirs -> scannedSecond(uri, ui)
            is Ui.ScanFirst -> scannedFirst(uri)
            else -> Unit
        }
    }

    /** A scanned B's code. */
    private fun scannedSecond(uri: String, ui: Ui.ScanTheirs) {
        val s = session ?: return
        when (val o = s.acceptSecondQR(uri, now())) {
            is MeshPairingSession.Outcome.Confirm -> when (val r = MeshPairing.roleCheck(o.npub, o.role, existing())) {
                is MeshPairing.RoleCheck.RefuseOtherRole -> stop(MeshPairing.otherRoleText(r.role))
                MeshPairing.RoleCheck.AlreadyLinked -> {
                    // Nothing to store; the ack still lets the other side finish.
                    sendAck(s)
                    _ui.value = Ui.Linked(MeshPairing.displayName(o.name), already = true)
                    appScope.launch { mesh.changeLock.withLock { shareForCopy() } }
                }
                MeshPairing.RoleCheck.Add -> {
                    pending = Pending.AddB(o.npub, o.name, o.role)
                    _ui.value = Ui.ConfirmRole(MeshPairing.roleConfirmText(o.role, o.name), MeshPairing.shortAddress(o.npub))
                }
            }
            is MeshPairingSession.Outcome.Unreadable -> _ui.value = ui.copy(note = MeshPairing.text(o.refusal))
            is MeshPairingSession.Outcome.Reject -> _ui.value = ui.copy(note = notTheirCodeText(ui.name))
            MeshPairingSession.Outcome.Expired -> stop(MeshPairing.EXPIRED_TEXT)
            MeshPairingSession.Outcome.Abort -> stop(MeshPairing.ABORT_TEXT)
            else -> Unit
        }
    }

    /** B scanned A's code. */
    private fun scannedFirst(uri: String) {
        val own = ownHex ?: return
        val p = when (val parsed = MeshPairing.parse(uri, MeshPairing.npub(own))) {
            is MeshPairing.Parsed.Refused -> { _ui.value = Ui.ScanFirst(MeshPairing.text(parsed.refusal)); return }
            is MeshPairing.Parsed.Ok -> parsed.payload
        }
        // B's code (an echo) scanned first: point at the right one.
        if (p.code !is MeshPairing.Code.Secret) { _ui.value = Ui.ScanFirst(FIRST_CODE_TEXT); return }
        // Any account the two devices share will do (Logen, 2026-11-06); only accounts this phone can sign for count.
        if (!MeshPairing.sharesAccount(p.owner, p.accountTags, p.code.value, accounts())) return stop(MeshPairing.OTHER_OWNER_TEXT)
        when (val next = PairDeviceRules.afterScanFirst(MeshPairing.roleCheck(p.mesh, p.role, existing()))) {
            is PairDeviceRules.AfterScan.Refuse -> return stop(next.text)
            // Known already: the hello goes out at once so the other side can add this phone again.
            PairDeviceRules.AfterScan.JoinAgain -> return join(p, now())
            PairDeviceRules.AfterScan.Confirm -> Unit
        }
        pending = Pending.JoinA(p, now())
        _ui.value = Ui.ConfirmRole(MeshPairing.roleConfirmText(p.role, p.name), MeshPairing.shortAddress(p.mesh))
    }

    // ---- The role confirm ----

    fun confirmRole() {
        // Only from the confirm screen: a late tap after a stop does nothing.
        if (_ui.value !is Ui.ConfirmRole) return
        when (val p = pending.also { pending = null }) {
            is Pending.AddB -> {
                val s = session ?: return
                // B stops waiting for the ack 360 s after it scanned, which is no earlier than its hello: past A's
                // scan window from that hello, don't link this side alone.
                if (now() - helloAt > MeshPairing.SCAN_WINDOW) return stop(MeshPairing.EXPIRED_TEXT)
                store(p.npub, p.role, p.name, shareAfter = true)
                sendAck(s)
                _ui.value = Ui.Linked(MeshPairing.displayName(p.name))
            }
            is Pending.JoinA -> join(p.a, p.scannedAt)
            null -> Unit
        }
    }

    /** B: send the hello, show this phone's code, wait for the ack. */
    private fun join(a: MeshPairing.Payload, scannedAt: Long) {
        val own = ownHex ?: return
        val h = hello ?: return
        val aSecret = (a.code as? MeshPairing.Code.Secret)?.value ?: return
        val bSecret = MeshPairing.newSecret()
        val j = MeshPairingJoiner.start(a, own, bSecret, scannedAt) ?: return stop(MeshPairing.UNREADABLE)
        joiner = j
        joined = a
        joinedSecret = aSecret
        val name = MeshPairing.displayName(a.name)
        if (!h.open(::onIncoming)) return run { _ui.value = Ui.NoMesh() }
        val sent = h.send(a.meshHex, MeshPairing.helloJson(aSecret, deviceName(), DeviceRole.PHONE, activeNpub().orEmpty(), now(), accounts()))
        if (!sent) return stop(SEND_FAILED_TEXT)
        val myCode = MeshPairing.build(MeshPairing.npub(own), deviceName(), DeviceRole.PHONE, activeNpub().orEmpty(), MeshPairing.Code.Echo(aSecret, bSecret))
        _ui.value = Ui.ShowMyCode(myCode, name, MeshPairing.ACK_WINDOW - (now() - scannedAt))
        tick { t ->
            // The same hello again, byte for byte: a changed one would abort A (Tron 3).
            if (t % (MeshPairingHello.RESEND_EVERY_MS / 1000) == 0L) h.resend()
            val left = MeshPairing.ACK_WINDOW - (t - scannedAt)
            if (left <= 0 && j.state != MeshPairingJoiner.State.Linked) return@tick stop(MeshPairing.EXPIRED_TEXT)
            (_ui.value as? Ui.ShowMyCode)?.let { _ui.value = it.copy(secondsLeft = left) }
        }
    }

    private fun onAck(j: MeshPairingJoiner, sender: String, plaintext: String) {
        val a = joined ?: return
        when (j.receiveAck(sender, plaintext, now())) {
            MeshPairingJoiner.Outcome.Linked -> linkedB(a)
            MeshPairingJoiner.Outcome.WaitWords -> {
                val words = MeshPairing.checkWords(a.meshHex, ownHex.orEmpty(), joinedSecret.orEmpty()) ?: return stop(MeshPairing.UNREADABLE)
                _ui.value = Ui.CheckWords(words, MeshPairing.shortAddress(a.mesh), MeshPairing.displayName(a.name), tapped = wordsTapped)
            }
            MeshPairingJoiner.Outcome.Expired -> stop(MeshPairing.EXPIRED_TEXT)
            else -> Unit
        }
    }

    /** B: "They match", on the Accept path only. */
    fun wordsMatch() {
        val j = joiner ?: return
        val a = joined ?: return
        wordsTapped = true
        when (j.confirmWords(now())) {
            MeshPairingJoiner.Outcome.Linked -> linkedB(a)
            MeshPairingJoiner.Outcome.Expired -> stop(MeshPairing.EXPIRED_TEXT)
            else -> (_ui.value as? Ui.CheckWords)?.let { _ui.value = it.copy(tapped = true) }
        }
    }

    private fun linkedB(a: MeshPairing.Payload) {
        store(a.mesh, a.role, a.name)
        val name = MeshPairing.displayName(a.name)
        _ui.value = Ui.Linked(name)
        stopTicker()
        copyFrom(a.mesh, name)
    }

    /**
     * B: any link starts the copy from the device just linked (docs/MESH_COPY_V2_CONTRACT.md §3), on the app's
     * scope so it carries on when this screen closes. The engine makes the copy; its `COPY` lines are the status.
     */
    private fun copyFrom(npub: String, name: String) {
        appScope.launch {
            val url = copyStarter.dial(npub) ?: return@launch copyLine(MeshCopyV2.errorLine("unreachable", name))
            when (val r = copyStarter.start(npub, url, name)) {
                MeshCopyStarter.Result.Started -> viewModelScope.launch {
                    copyStarter.progress.collect { l -> l?.let { copyLine(MeshCopyV2.statusText(it, name)) } }
                }
                is MeshCopyStarter.Result.Failed -> copyLine(r.line)
            }
        }
    }

    private fun copyLine(text: String) {
        (_ui.value as? Ui.Linked)?.let { _ui.value = it.copy(copy = text) }
    }

    private fun sendAck(s: MeshPairingSession) {
        val sender = s.senderHex ?: return
        s.ack?.let { hello?.send(sender, it) }
        stopTicker()
        // Resent a few times on the same bytes, for a B that was between relays when it went out.
        ticker = viewModelScope.launch {
            repeat(ACK_RESENDS) {
                delay(MeshPairingHello.RESEND_EVERY_MS)
                hello?.resend()
            }
        }
    }

    // ---- Mesh off, account switch ----

    fun turnOnMesh() {
        _ui.value = Ui.NoMesh(starting = true)
        viewModelScope.launch {
            // Behind any Mesh settings change still queued (Tron, #1706): never a start while Mesh off is stopping it.
            val ok = mesh.changeLock.withLock { mesh.status.value.running || mesh.start() }
            if (ok) showCode() else _ui.value = Ui.NoMesh(error = mesh.lastError.value ?: "The mesh did not start.")
        }
    }

    fun switchAccount(npub: String) {
        viewModelScope.launch {
            configStore.switchActiveAccount(npub)
            scanInstead()
        }
    }

    // ---- Storing: the same add as Mesh settings › Add a device ----

    /** [shareAfter]: A, so the device just linked can copy from this one (after the store's own restart). */
    private fun store(npub: String, role: DeviceRole, name: String, shareAfter: Boolean = false) {
        val own = ownHex?.let(MeshPairing::npub)
        // In the same queue as Mesh settings, reading the config inside it: a Remove or Mesh off queued before this
        // is finished first and not undone (Tron, #1706).
        appScope.launch {
            mesh.changeLock.withLock {
                storeNow(own, npub, role, name)
                if (shareAfter) shareForCopy()
            }
        }
    }

    /** A, linked: its vault is shared with its own devices for the copy window (Share off too); in the change queue. */
    private suspend fun shareForCopy() {
        if (!mesh.shareForCopy()) return
        (_ui.value as? Ui.Linked)?.let { _ui.value = it.copy(keepOpen = true) }
    }

    private suspend fun storeNow(own: String?, npub: String, role: DeviceRole, name: String) {
        val before = configStore.config.value
        // Linked by the account active now: only its posts go to the device (Logen 2026-11-05).
        val change = MyDevicesRules.add(
            before.fipsPeers, before.homeVaultNpub, before.fipsMesh.devices, own, npub, role, name,
            linkedBy = activeNpub().orEmpty(), ownerNpub = before.ownerNpub,
        ) ?: return
        configStore.updateAsync { it.copy(fipsMesh = it.fipsMesh.copy(devices = change.labels)) }
        if (change.peers != before.fipsPeers) mesh.setPeers(change.peers)
        if (change.homeVault != before.homeVaultNpub) homeVault.setHomeVault(change.homeVault)
        configStore.updateAsync { it.copy(serverListDropMesh = serverListDropsAfter(before, it)) }
    }

    // ---- Helpers ----

    private fun newHello(): MeshPairingHello =
        MeshPairingHello(configStore.config.value.fipsMesh.engineFinderRelays, viewModelScope).also { hello = it }

    private fun existing(): List<Pair<String, DeviceRole>> {
        val cfg = configStore.config.value
        return MyDevicesRules.list(cfg.fipsPeers, cfg.homeVaultNpub, cfg.fipsMesh.devices, emptyList(), cfg.ownerNpub).map { it.npub to it.role }
    }

    private fun activeNpub(): String? {
        val cfg = configStore.config.value
        return cfg.activeAccountNpub?.trim()?.takeIf { it.isNotEmpty() } ?: cfg.ownerNpub.takeIf { it.isNotEmpty() }
    }

    /** What this phone pairs on: the owner and the accounts it can sign for, never a look-only one. */
    private fun accounts(): List<String> = configStore.signingAccountNpubs()

    private fun accountName(npub: String): String {
        val hex = MeshPairing.npubHex(npub)
        return hex?.let { nostrService.profiles.value[it]?.bestName }?.takeIf { it.isNotBlank() } ?: MeshPairing.shortAddress(npub)
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

    private fun stop(text: String) {
        stopTicker()
        pending = null
        hello?.close()
        _ui.value = Ui.Stopped(text)
    }

    private fun reset() {
        stopTicker()
        hello?.close()
        hello = null
        session = null
        joiner = null
        joined = null
        joinedSecret = null
        pending = null
        wordsTapped = false
    }

    override fun onCleared() {
        reset()
    }

    companion object {
        const val FIRST_CODE_TEXT = "That's the second code. Scan the code your other device shows first."
        const val SEND_FAILED_TEXT = "Couldn't reach your other device. Check your connection and try again."
        const val ACK_RESENDS = 6

        fun notTheirCodeText(name: String) = "That isn't the code on $name. Scan the code it's showing now."

        private fun now() = System.currentTimeMillis() / 1000

        /** The device model for now ("Moto G Play 2026"); Logen still picks the defaults. */
        fun deviceName(manufacturer: String = Build.MANUFACTURER.orEmpty(), model: String = Build.MODEL.orEmpty()): String {
            val m = model.trim()
            val maker = manufacturer.trim().replaceFirstChar { it.titlecase() }
            val name = if (maker.isEmpty() || m.startsWith(maker, ignoreCase = true)) m else "$maker $m"
            return name.ifEmpty { "Android phone" }.take(MeshPairing.NAME_MAX)
        }
    }
}
