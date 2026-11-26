package com.nostrvault.fips

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.util.Log
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.di.ApplicationScope
import com.nostrvault.relay.HavenBridge
import com.nostrvault.ui.screens.settings.YourDevicesRules
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.File
import java.util.concurrent.TimeUnit
import javax.inject.Inject
import javax.inject.Singleton

/**
 * B, on any link (setup's "Copy from my other vault" and Vault › Your devices › Add): dials the other vault, signs
 * the one start with this device's own mesh key ([MeshKeySigner], never the owner's: §2) and hands it to the engine
 * (StartCopyFromC), which makes the start call, checks the manifest and the
 * free space, fetches, restores and says `/done`. It also resumes a cut copy and runs a catch-up (CopySyncC) when the
 * relay comes up and when the app comes back, for devices copied from before. The engine's `COPY` lines come back
 * through [onLogLine] as [progress]. Twin of Apple's `MeshCopyV2Service` (docs/MESH_COPY_V2_CONTRACT.md).
 */
@Singleton
class MeshCopyStarter internal constructor(
    private val link: (String) -> String?,
    /** Base64 of the signed start for these tags, or null with no mesh key (the engine adds "Nostr "). */
    private val sign: suspend (List<List<String>>) -> String?,
    private val engine: Engine,
    private val records: RecordStore,
    private val setupDone: () -> Boolean,
    private val scope: CoroutineScope,
    private val nowS: () -> Long = { System.currentTimeMillis() / 1000 },
    /** Where the unreachable retries run (the link dial blocks); the tests' scheduler in the tests. */
    private val io: CoroutineDispatcher = Dispatchers.IO,
    /**
     * Whether a catch-up moves files as well as notes (multi-Mac rules §3, rule 7): false for a light phone (Full
     * copy off) or a full one off Wi-Fi while Wi-Fi only is on ([YourDevicesRules.catchUpMovesFiles]).
     */
    private val filesToo: () -> Boolean = { true },
    /** A paired device's name from My Devices (by mesh npub), or "" when it has none. */
    private val deviceName: (String) -> String = { "" },
    /** The paired desktops (a Mac or a box) by mesh npub, for the rank pull ([MeshRankPull]). */
    private val desktops: () -> List<String> = { emptyList() },
    /** A rank pull brought a new rank: read it now. */
    private val rankArrived: () -> Unit = {},
    /** The mesh npubs with a live link now (the engine's peers): tried first, as the ones that answer. */
    private val connected: () -> Collection<String> = { emptyList() },
    /** The setup or import dial's address, the one kept across restarts ([OtherVaultLink.open] keep). */
    private val seedLink: (String) -> String? = link,
) {
    @Inject constructor(
        @ApplicationContext context: Context,
        configStore: ConfigStore,
        otherVaultLink: OtherVaultLink,
        @ApplicationScope scope: CoroutineScope,
        reach: dagger.Lazy<com.nostrvault.service.DiscoveryReachStore>,
        mesh: dagger.Lazy<FipsMeshManager>,
    ) : this(
        link = { npub -> openChecked(npub) { otherVaultLink.open(npub, keep = false) } },
        sign = { tags -> MeshKeySigner.authorization(MeshKeyAuth.START_KIND, "", tags) },
        engine = BridgeEngine,
        records = PrefsRecordStore(context),
        setupDone = { configStore.config.value.hasCompletedSetup },
        scope = scope,
        filesToo = {
            val cfg = configStore.config.value
            YourDevicesRules.catchUpMovesFiles(
                fullCopy = YourDevicesRules.keepsFullCopy(mobileVault = cfg.fipsShareRelay, stored = cfg.keepFullCopy),
                wifiOnly = cfg.fullCopyWifiOnly,
                onWiFi = onWiFi(context),
            )
        },
        deviceName = { npub -> configStore.config.value.fipsMesh.devices.firstOrNull { it.npub == npub }?.name.orEmpty() },
        desktops = {
            val cfg = configStore.config.value
            MyDevicesRules.list(cfg.fipsPeers, cfg.homeVaultNpub, cfg.fipsMesh.devices, emptyList(), cfg.ownerNpub)
                .filter { it.role == DeviceRole.MAC }.map { it.npub }
        },
        rankArrived = { reach.get().refresh() },
        connected = { mesh.get().status.value.peers },
        seedLink = { npub -> openChecked(npub) { otherVaultLink.open(npub, keep = true) } },
    )

    /** The libhaven copy calls (a fake in the tests). Codes: [MeshCopyV2.RUN_STARTED] and the rest. */
    interface Engine {
        /** StartCopyFromC: [startAuth] is base64 of the signed start, or "" to resume with the token the engine holds. */
        fun startCopyFrom(peer: String, base: String, startAuth: String): Int
        /** CopySyncC: one catch-up with [peer]; CopySyncNotesOnlyC when not [filesToo]. */
        fun copySync(peer: String, base: String, filesToo: Boolean): Int
        /** CopyHeldPeersC: the paired devices the engine copied from ([MeshCopyV2.Record.adopt]). */
        fun heldPeers(): List<String> = emptyList()
        /** CopyRefusedPeersC: paired devices whose first copy stopped on a refused token ([MeshCopyV2.Record.restartRefused]). */
        fun refusedPeers(): List<String> = emptyList()
        /** RankPullC: one rank pull from [peer] ([MeshRankPull]); [startAuth] is used only when no held token works. */
        fun rankPull(peer: String, base: String, startAuth: String): Int = MeshCopyV2.RUN_RELAY_NOT_RUNNING
    }

    interface RecordStore {
        fun load(): MeshCopyV2.Record
        fun save(r: MeshCopyV2.Record)
    }

    sealed interface Result {
        /** The engine has the copy (or one was already running); [progress] follows it. */
        data object Started : Result
        /** A contract error code; [line] is what the screen says (may be empty). */
        data class Failed(val code: String, val line: String) : Result
    }

    private val _progress = MutableStateFlow<MeshCopyV2.Line?>(null)
    /** The engine's newest `COPY` line, or null before any. */
    val progress: StateFlow<MeshCopyV2.Line?> = _progress.asStateFlow()

    private val _unreachable = MutableStateFlow<MeshCopyV2.Retry>(MeshCopyV2.Retry.None)
    /**
     * The other device can't be reached: [MeshCopyV2.Retry.After] while this phone keeps trying every ~15 s,
     * [MeshCopyV2.Retry.GaveUp] once it has tried for a few minutes (then [tryAgain]).
     */
    val unreachable: StateFlow<MeshCopyV2.Retry> = _unreachable.asStateFlow()
    /** The next try at an unreachable copy, while one waits. */
    private var retryJob: Job? = null

    private val lock = Mutex()
    /**
     * A check that found [lock] held (a queued pull may dial for about a minute): run again once it is let go, so a
     * relay start or a pending copy's retry is not lost (Tron, #2550).
     */
    @Volatile private var checkAgain = false
    private var record = records.load()
        set(v) { if (v != field) { field = v; records.save(v); _sync.update { it.copy(lastAt = v.copied) } } }

    /**
     * Each copied-from device's catch-up as Settings › Your Devices shows it ([MeshSyncState]). Declared after
     * [record], which it starts from.
     */
    private val _sync = MutableStateFlow(MeshSyncState(lastAt = record.copied))
    val sync: StateFlow<MeshSyncState> = _sync.asStateFlow()

    /** When each paired desktop never copied from last had a rank pull started, this run ([MeshRankPull.due]). */
    private val rankPulledAt = java.util.concurrent.ConcurrentHashMap<String, Long>()

    /** The peer the running copy or catch-up is with. */
    @Volatile private var current: String? = null
        set(v) { field = v; _sync.update { it.copy(running = v) } }

    /** What is kept: for the tests. */
    internal val kept: MeshCopyV2.Record get() = record

    /** A relay log line: a `COPY` line becomes [progress] (and is returned); a finished one updates the record. */
    fun onLogLine(raw: String): MeshCopyV2.Line? {
        MeshRankNudge.readyPeer(raw)?.let { rankReady(it); return null }
        MeshRankPull.parse(raw)?.let { rankPulled(it); return null }
        if (!raw.contains("COPY ")) return null
        val l = MeshCopyV2.parseLine(raw) ?: return null
        if (l.stage == "done" || l.stage == "failed") {
            val peer = synchronized(this) {
                (current ?: record.pending?.peer)?.also { record = record.finished(l, it, nowS()) }.also { current = null }
            }
            if (peer != null) {
                _sync.update { if (l.stage == "done") it.copy(failed = it.failed - peer) else it.copy(failed = it.failed + (peer to l.error.ifEmpty { "failed" })) }
            }
            // Sync now's next device, if it queued more than one.
            if (_sync.value.queued.isNotEmpty()) scope.launch(io) { syncQueued() }
            // Can't reach the device: try again every ~15 s for a few minutes, then say it failed (set before
            // [progress], which the copy screen follows).
            if (l.error == "unreachable" && peer != null && record.pending?.peer == peer) missed(peer)
            else if (_unreachable.value != MeshCopyV2.Retry.None) stopRetrying()
        } else if (_unreachable.value != MeshCopyV2.Retry.None) {
            // Moving again: it is reachable.
            synchronized(this) { record = record.retryNow() }
            stopRetrying()
        }
        _progress.value = l
        return l
    }

    /** The relay stopped: its copy run ended (the engine keeps the state) and the next start resumes it. */
    fun relayStopped() {
        current = null
    }

    /**
     * The other vault's kept address once it answers, dialed every [OtherVaultCopy.DIAL_RETRY_S] for up to
     * [OtherVaultCopy.DIAL_WINDOW_S] (a phone just linked is often still finding the other one), else null.
     */
    suspend fun dial(meshNpub: String): String? {
        val startedAt = nowS()
        while (true) {
            val url = withContext(Dispatchers.IO) { seedLink(meshNpub) }
            if (url != null) return url
            if (!OtherVaultCopy.dialsAgain(startedAt, nowS())) return null
            delay(OtherVaultCopy.DIAL_RETRY_S * 1000)
        }
    }

    /** Copies this vault from the linked device [peer] (its mesh npub), called [name], through [linkWs]. */
    suspend fun start(peer: String, linkWs: String, name: String): Result {
        if (current == peer) return Result.Started
        _progress.value = null
        stopRetrying()
        synchronized(this) {
            record = record.copy(pending = MeshCopyV2.Record.Pending(peer, name, freshStart = true), unreachableSince = null)
        }
        return lock.withLock { run(peer, linkWs, name, fresh = true) }
    }

    /** The failed state's Try again: a fresh few minutes of tries. */
    fun tryAgain() {
        val peer = record.pending?.peer ?: return
        synchronized(this) { record = record.retryNow() }
        stopRetrying()
        scope.launch(io) { retryOnce(peer) }
    }

    private fun stopRetrying() {
        retryJob?.cancel()
        retryJob = null
        _unreachable.value = MeshCopyV2.Retry.None
    }

    /** The pending copy with [peer] missed its device: try again shortly, or after a few minutes show it failed. */
    private fun missed(peer: String) {
        val next = synchronized(this) {
            record = record.missed(peer, nowS())
            record.retry(nowS())
        }
        retryJob?.cancel()
        _unreachable.value = next
        retryJob = (next as? MeshCopyV2.Retry.After)?.let { after ->
            scope.launch(io) {
                delay(after.seconds * 1000)
                retryJob = null
                retryOnce(peer)
            }
        }
    }

    /** One more try at the pending copy with [peer]; a try that can't reach it counts as a miss. */
    internal suspend fun retryOnce(peer: String) {
        if (current != null) return
        if (!lockOrAskAgain()) return
        try {
            val p = record.pending?.takeIf { it.peer == peer } ?: return
            val url = link(p.peer) ?: return missed(peer)
            val r = run(p.peer, url, p.name, p.freshStart)
            if ((r as? Result.Failed)?.code == "unreachable") missed(peer)
        } finally {
            lock.unlock()
            runAgainIfAsked()
        }
    }

    /** The relay came up or the app came back: the pending copy resumes, else a copied device that is due gets a catch-up. */
    /**
     * The base to read [peer]'s desktop Vault status through (VaultStatusBridge), or null when it can't be dialed.
     * Only after setup: opening a peer's link closes a setup seed's.
     */
    fun statusBase(peer: String): String? =
        if (!setupDone()) null else link(peer)?.let(MeshCopyV2::splitLink)?.let { (base, prefix) -> base + prefix }

    fun reconnect() {
        scope.launch(Dispatchers.IO) { reconnectNow() }
    }

    internal suspend fun reconnectNow() {
        if (current != null) return
        if (!lockOrAskAgain()) return
        try {
            val r = record
            r.pending?.let { p ->
                // The relay came up or the app came back: a fresh window of tries.
                synchronized(this) { record = record.retryNow() }
                stopRetrying()
                val url = link(p.peer) ?: return
                run(p.peer, url, p.name, p.freshStart)
                return
            }
            // A catch-up opens the link for its peer, which would close a setup seed's: none until setup is done.
            if (!setupDone()) return
            adoptHeld()
            // A first copy stopped on a refused token starts again, signed by this device's mesh key.
            val refused = engine.refusedPeers()
            if (refused.isNotEmpty()) synchronized(this) { record = record.restartRefused(refused, deviceName) }
            record.pending?.let { p ->
                val url = link(p.peer) ?: return
                run(p.peer, url, p.name, p.freshStart)
                return
            }
            val peer = record.syncDue(nowS()).firstOrNull()
            if (peer == null) {
                // Rank only: every paired desktop never copied from, hourly (queued: syncQueued takes the lock).
                val due = synchronized(this) { MeshRankPull.due(desktops(), record.copied, record.pending?.peer, rankPulledAt, nowS()) }
                if (due.isEmpty()) return
                val order = reachableFirst(due)
                Log.i(TAG, "rank check: picked ${order.joinToString { short(it) }}")
                _sync.update { s -> s.copy(queued = (s.queued + order).distinct().filter { it != s.running }) }
                scope.launch(io) { syncQueued() }
                return
            }
            val (base, prefix) = link(peer)?.let(MeshCopyV2::splitLink) ?: return
            // Stamped by the done line ([MeshCopyV2.Record.finished]), not here: a run cut short is due again.
            if (engine.copySync(peer, base + prefix, filesToo()) == MeshCopyV2.RUN_STARTED) current = peer
        } finally {
            lock.unlock()
            runAgainIfAsked()
        }
    }

    /** Devices the engine copied from that the record lost come back ([MeshCopyV2.Record.adopt]). */
    private fun adoptHeld() {
        val held = engine.heldPeers()
        if (held.isNotEmpty()) synchronized(this) { record = record.adopt(held) }
    }

    /**
     * A device this one copies from has a new trust rank (`RANK_READY`, [MeshRankNudge]): catch up with it now, due
     * or not. While another copy runs it stays queued for that one's end.
     */
    fun rankReady(peer: String) {
        scope.launch(io) {
            if (!setupDone()) return@launch
            adoptHeld()
            // A paired desktop never copied from gets a rank pull instead ([MeshRankPull]).
            val known = synchronized(this@MeshCopyStarter) {
                peer != record.pending?.peer &&
                    (peer in record.copied || peer in MeshRankPull.peers(desktops(), record.copied, record.pending?.peer))
            }
            if (!known) { Log.i(TAG, "rank ready: ${short(peer)} is no desktop to pull from, skipped"); return@launch }
            _sync.update { s -> s.copy(queued = (s.queued + peer).distinct().filter { it != s.running }) }
            syncQueued()
        }
    }

    /** Every [MeshRankNudge.RECHECK_EVERY_S] while the app runs: the usual check, so a missed nudge waits an hour at most. */
    fun startHourlyCheck() {
        scope.launch(io) {
            while (true) {
                delay(MeshRankNudge.RECHECK_EVERY_S * 1000)
                reconnectNow()
            }
        }
    }

    /**
     * Settings › Your Devices › Sync now: a catch-up with every device this one copied from, the longest ago first,
     * one after another (the engine runs one at a time), due or not. Not before setup, and not with the device a
     * copy is still pending with (that copy resumes on its own). Twin of Apple's MeshCopyV2Service sync-now (A4).
     */
    fun syncNow() {
        if (!setupDone()) return
        val peers = synchronized(this) {
            record.copied.entries.filter { it.key != record.pending?.peer }.sortedBy { it.value }.map { it.key }
        }
        if (peers.isEmpty()) return
        _sync.update { s -> s.copy(queued = (s.queued + peers).distinct().filter { it != s.running }) }
        scope.launch(io) { syncQueued() }
    }

    /**
     * My Web › Desktop Vault › Pull: every paired desktop, the ones with a live mesh link first, each in turn (a
     * catch-up for one copied from, a rank pull for the rest). Not only the one the card shows: that one may be out
     * of reach while another that has the rank answers (Logen's Pull 2026-11-25 22:38Z, Tod 417659c3).
     */
    fun pullAll() {
        scope.launch(io) {
            if (!setupDone()) { Log.i(TAG, "pull: setup not done"); return@launch }
            adoptHeld()
            val all = synchronized(this@MeshCopyStarter) { desktops().filter { it != record.pending?.peer }.distinct() }
            if (all.isEmpty()) { Log.i(TAG, "pull: no paired desktop"); return@launch }
            val order = reachableFirst(all)
            Log.i(TAG, "pull: picked ${order.joinToString { short(it) }}")
            _sync.update { s -> s.copy(queued = (s.queued + order).distinct().filter { it != s.running }) }
            syncQueued()
        }
    }

    /** [peers] with the ones that have a live mesh link first, order kept otherwise. */
    private fun reachableFirst(peers: List<String>): List<String> {
        val live = runCatching { connected().toSet() }.getOrDefault(emptySet())
        return peers.sortedBy { it !in live }
    }

    /**
     * Starts the next queued catch-up, unless one is running (its end comes back here through [onLogLine]). A device
     * that can't be dialed or that the engine refuses is marked and skipped; a busy engine keeps the queue.
     */
    internal suspend fun syncQueued() {
        try {
            syncQueuedLocked()
        } finally {
            runAgainIfAsked()
        }
    }

    /**
     * [lock], or a note to run the check again once its holder lets go. Tried twice: the holder may unlock and read
     * [checkAgain] between this check's first try and the note, and then this check runs itself (Tron, #2550).
     */
    private fun lockOrAskAgain(): Boolean {
        if (lock.tryLock()) return true
        checkAgain = true
        if (!lock.tryLock()) return false
        checkAgain = false
        return true
    }

    /** A check lost [lock] while it was held: run it now. */
    private fun runAgainIfAsked() {
        if (checkAgain) { checkAgain = false; scope.launch(io) { reconnectNow() } }
    }

    private suspend fun syncQueuedLocked() = lock.withLock {
        while (current == null) {
            val peer = _sync.value.queued.firstOrNull() ?: return@withLock
            val split = linkSoon(peer)?.let(MeshCopyV2::splitLink)
            if (split == null) Log.w(TAG, "sync ${short(peer)}: link null, not reached")
            val catchUp = peer in record.copied
            val code = split?.let { (base, prefix) ->
                if (catchUp) engine.copySync(peer, base + prefix, filesToo()) else rankPull(peer, base, prefix)
            }
            if (code != null) Log.i(TAG, "sync ${short(peer)}: ${if (catchUp) "catch-up" else "rank pull"} engine code $code")
            if (code == MeshCopyV2.RUN_BUSY) return@withLock
            _sync.update { it.copy(queued = it.queued - peer) }
            if (code == MeshCopyV2.RUN_STARTED) {
                current = peer
                _sync.update { it.copy(failed = it.failed - peer) }
            } else {
                _sync.update { it.copy(failed = it.failed + (peer to if (split == null) "unreachable" else "not_started")) }
            }
        }
    }

    /**
     * [peer]'s address, dialed again every [OtherVaultCopy.DIAL_RETRY_S] for up to [OtherVaultCopy.DIAL_WINDOW_S]
     * like [dial]: right after this relay starts the mesh is often still finding the desktop, and one miss marked it
     * failed until the next hourly check (Tao, nv-android e9bfe229).
     */
    private suspend fun linkSoon(peer: String): String? {
        val startedAt = nowS()
        while (true) {
            link(peer)?.let { return it }
            if (!OtherVaultCopy.dialsAgain(startedAt, nowS())) return null
            delay(OtherVaultCopy.DIAL_RETRY_S * 1000)
        }
    }

    /**
     * Hands the copy to the engine: [fresh] signs a start right before each call (A wants it within 60 s), else the
     * engine resumes with the token it holds. Retries while this device's relay comes up.
     */
    private suspend fun run(peer: String, linkWs: String, name: String, fresh: Boolean): Result {
        val (base, prefix) = MeshCopyV2.splitLink(linkWs) ?: return fail("unreachable", name)
        val startedAt = nowS()
        var code: Int
        while (true) {
            // `p` = A's mesh npub ([peer]): A takes the start only from a device in its paired set. No owner fallback:
            // the engine posts the start in the background, so A must run a build that has the set (§2).
            val auth = if (fresh) {
                val tags = MeshKeyAuth.copyStartTags(base, peer) ?: return fail("unreachable", name)
                sign(tags) ?: return fail("auth_refused", name)
            } else ""
            code = engine.startCopyFrom(peer, base + prefix, auth)
            if (code != MeshCopyV2.RUN_RELAY_NOT_RUNNING || nowS() - startedAt >= MeshCopyV2.RELAY_WAIT_S) break
            delay(MeshCopyV2.RETRY_EVERY_S * 1000)
        }
        if (code != MeshCopyV2.RUN_STARTED && code != MeshCopyV2.RUN_BUSY) {
            Log.w(TAG, "Mesh copy: not started ($code)")
            return fail("unreachable", name)
        }
        current = peer
        // The engine holds the token now: a cut copy resumes without a new proof.
        synchronized(this) {
            record.pending?.takeIf { it.peer == peer }?.let { record = record.copy(pending = it.copy(freshStart = false)) }
        }
        return Result.Started
    }

    /** Hands one rank pull to the engine, with a fresh start signed by this device's mesh key for when it holds no token. */
    private suspend fun rankPull(peer: String, base: String, prefix: String): Int {
        val auth = MeshRankPull.startTags(base, peer)?.let { sign(it) }
            ?: return NOT_SIGNED.also { Log.w(TAG, "rank pull ${short(peer)}: sign failed") }
        val code = engine.rankPull(peer, base + prefix, auth)
        if (code == MeshCopyV2.RUN_STARTED) rankPulledAt[peer] = nowS()
        return code
    }

    /** A rank pull ended (`RANK_PULLED`): its failure kept for My Web's Desktop Vault, a new rank read, the next device. */
    private fun rankPulled(p: MeshRankPull.Pulled) {
        if (MeshRankPull.cutShort(p.error)) rankPulledAt.remove(p.peer)
        _sync.update { if (p.error.isEmpty()) it.copy(failed = it.failed - p.peer) else it.copy(failed = it.failed + (p.peer to p.error)) }
        if (p.got > 0) rankArrived()
        synchronized(this) { if (current == p.peer) current = null }
        if (_sync.value.queued.isNotEmpty()) scope.launch(io) { syncQueued() }
    }

    private fun fail(code: String, name: String) = Result.Failed(code, MeshCopyV2.errorLine(code, name))

    private object BridgeEngine : Engine {
        override fun startCopyFrom(peer: String, base: String, startAuth: String): Int = call { HavenBridge.startCopyFrom(peer, base, startAuth) }
        override fun copySync(peer: String, base: String, filesToo: Boolean): Int =
            call { if (filesToo) HavenBridge.copySync(peer, base) else HavenBridge.copySyncNotesOnly(peer, base) }
        override fun heldPeers(): List<String> =
            if (!HavenBridge.isLoaded) emptyList() else MeshRankNudge.parseHeld(runCatching { HavenBridge.copyHeldPeers() }.getOrNull())
        override fun refusedPeers(): List<String> =
            if (!HavenBridge.isLoaded) emptyList() else MeshRankNudge.parseHeld(runCatching { HavenBridge.copyRefusedPeers() }.getOrNull())
        override fun rankPull(peer: String, base: String, startAuth: String): Int = call { HavenBridge.rankPull(peer, base, startAuth) }
        private fun call(f: () -> Int): Int =
            if (!HavenBridge.isLoaded) MeshCopyV2.RUN_RELAY_NOT_RUNNING else runCatching(f).getOrDefault(MeshCopyV2.RUN_RELAY_NOT_RUNNING)
    }

    private class PrefsRecordStore(context: Context) : RecordStore {
        private val prefs = context.getSharedPreferences("mesh_copy", Context.MODE_PRIVATE)
        override fun load() = MeshCopyV2.Record.fromJson(prefs.getString("record", null))
        override fun save(r: MeshCopyV2.Record) { prefs.edit().putString("record", r.toJson()).apply() }
    }

    companion object {
        private const val TAG = "MeshCopy"
        private const val PROBE_TIMEOUT_S = 8L
        /** No mesh key to sign a rank start with: shown as not started. */
        private const val NOT_SIGNED = -1

        /** Enough of a mesh npub to tell devices apart in a log (public: no address, no token). */
        private fun short(npub: String): String = npub.take(16)

        private val probe by lazy {
            okhttp3.OkHttpClient.Builder()
                .connectTimeout(PROBE_TIMEOUT_S, TimeUnit.SECONDS)
                .readTimeout(PROBE_TIMEOUT_S, TimeUnit.SECONDS)
                .build()
        }

        /** [npub]'s link address once its probe answers, with the step that failed logged otherwise. */
        private fun openChecked(npub: String, open: () -> String?): String? {
            val url = open() ?: return null.also { Log.w(TAG, "link ${short(npub)}: no local port") }
            val failed = probeFailure(url) ?: return url
            Log.w(TAG, "link ${short(npub)}: $failed")
            return null
        }

        /**
         * One NIP-11 GET through [wsUrl]: null when it answers 2xx, else which step failed and what came back (the
         * status and the head of the body), so a `link null` says why (Tod, nv-android ff220e33). Never the address:
         * its path is the link's secret, so anything token-like is taken out.
         */
        internal fun probeFailure(wsUrl: String, client: okhttp3.OkHttpClient = probe): String? = try {
            val request = okhttp3.Request.Builder().url(wsUrl.replaceFirst("ws://", "http://"))
                .header("Accept", "application/nostr+json").header("Connection", "close").build()
            client.newCall(request).execute().use { r ->
                if (r.isSuccessful) null
                else "probe answered ${r.code}, body \"${scrub(r.peekBody(BODY_HEAD.toLong()).string())}\""
            }
        } catch (e: Exception) {
            "probe got no answer (${e.javaClass.simpleName}: ${scrub(e.message.orEmpty())})"
        }

        private const val BODY_HEAD = 120

        /** One line, short, with no hex run long enough to be a token. */
        private fun scrub(s: String): String =
            s.replace(Regex("[0-9a-fA-F]{16,}"), "<hex>").replace(Regex("\\s+"), " ").trim().take(BODY_HEAD)

        internal fun ownerOnly(f: File) {
            f.setReadable(false, false); f.setReadable(true, true)
            f.setWritable(false, false); f.setWritable(true, true)
            f.setExecutable(false, false)
        }
    }
}

/** Wi-Fi (or a wire) now, for Wi-Fi only. */
private fun onWiFi(context: Context): Boolean {
    val cm = context.getSystemService(ConnectivityManager::class.java) ?: return false
    val caps = cm.getNetworkCapabilities(cm.activeNetwork) ?: return false
    return caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) || caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)
}

/**
 * The catch-ups Settings › Your Devices shows: when each copied-from device last synced ([lastAt], Unix s, the
 * record's own map), the one running now, the ones Sync now still has to start, and the last failure per device
 * (the engine's `COPY` error code, `unreachable` when it could not be dialed) until a later one finishes.
 */
data class MeshSyncState(
    val lastAt: Map<String, Long> = emptyMap(),
    val running: String? = null,
    val queued: List<String> = emptyList(),
    val failed: Map<String, String> = emptyMap(),
)
