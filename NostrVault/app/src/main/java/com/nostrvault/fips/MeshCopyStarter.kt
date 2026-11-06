package com.nostrvault.fips

import android.content.Context
import android.util.Log
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.di.ApplicationScope
import com.nostrvault.relay.HavenBridge
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
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
) {
    @Inject constructor(
        @ApplicationContext context: Context,
        configStore: ConfigStore,
        otherVaultLink: OtherVaultLink,
        @ApplicationScope scope: CoroutineScope,
    ) : this(
        link = { npub -> otherVaultLink.open(npub)?.takeIf(::answers) },
        sign = { tags -> MeshKeySigner.authorization(MeshKeyAuth.START_KIND, "", tags) },
        engine = BridgeEngine,
        records = PrefsRecordStore(context),
        setupDone = { configStore.config.value.hasCompletedSetup },
        scope = scope,
    )

    /** The libhaven copy calls (a fake in the tests). Codes: [MeshCopyV2.RUN_STARTED] and the rest. */
    interface Engine {
        /** StartCopyFromC: [startAuth] is base64 of the signed start, or "" to resume with the token the engine holds. */
        fun startCopyFrom(peer: String, base: String, startAuth: String): Int
        /** CopySyncC: one catch-up with [peer]. */
        fun copySync(peer: String, base: String): Int
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
    private var record = records.load()
        set(v) { if (v != field) { field = v; records.save(v) } }
    /** The peer the running copy or catch-up is with. */
    @Volatile private var current: String? = null

    /** What is kept: for the tests. */
    internal val kept: MeshCopyV2.Record get() = record

    /** A relay log line: a `COPY` line becomes [progress] (and is returned); a finished one updates the record. */
    fun onLogLine(raw: String): MeshCopyV2.Line? {
        if (!raw.contains("COPY ")) return null
        val l = MeshCopyV2.parseLine(raw) ?: return null
        if (l.stage == "done" || l.stage == "failed") {
            val peer = synchronized(this) {
                (current ?: record.pending?.peer)?.also { record = record.finished(l, it, nowS()) }.also { current = null }
            }
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
            val url = withContext(Dispatchers.IO) { link(meshNpub) }
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
        if (current != null || !lock.tryLock()) return
        try {
            val p = record.pending?.takeIf { it.peer == peer } ?: return
            val url = link(p.peer) ?: return missed(peer)
            val r = run(p.peer, url, p.name, p.freshStart)
            if ((r as? Result.Failed)?.code == "unreachable") missed(peer)
        } finally {
            lock.unlock()
        }
    }

    /** The relay came up or the app came back: the pending copy resumes, else a copied device that is due gets a catch-up. */
    fun reconnect() {
        scope.launch(Dispatchers.IO) { reconnectNow() }
    }

    internal suspend fun reconnectNow() {
        if (current != null || !lock.tryLock()) return
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
            val peer = r.syncDue(nowS()).firstOrNull() ?: return
            val (base, prefix) = link(peer)?.let(MeshCopyV2::splitLink) ?: return
            if (engine.copySync(peer, base + prefix) == MeshCopyV2.RUN_STARTED) {
                current = peer
                synchronized(this) { record = record.copy(copied = record.copied + (peer to nowS())) }
            }
        } finally {
            lock.unlock()
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

    private fun fail(code: String, name: String) = Result.Failed(code, MeshCopyV2.errorLine(code, name))

    private object BridgeEngine : Engine {
        override fun startCopyFrom(peer: String, base: String, startAuth: String): Int = call { HavenBridge.startCopyFrom(peer, base, startAuth) }
        override fun copySync(peer: String, base: String): Int = call { HavenBridge.copySync(peer, base) }
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

        private val probe by lazy {
            okhttp3.OkHttpClient.Builder()
                .connectTimeout(PROBE_TIMEOUT_S, TimeUnit.SECONDS)
                .readTimeout(PROBE_TIMEOUT_S, TimeUnit.SECONDS)
                .build()
        }

        private fun answers(wsUrl: String): Boolean = runCatching {
            val request = okhttp3.Request.Builder().url(wsUrl.replaceFirst("ws://", "http://"))
                .header("Accept", "application/nostr+json").header("Connection", "close").build()
            probe.newCall(request).execute().use { it.isSuccessful }
        }.getOrDefault(false)

        internal fun ownerOnly(f: File) {
            f.setReadable(false, false); f.setReadable(true, true)
            f.setWritable(false, false); f.setWritable(true, true)
            f.setExecutable(false, false)
        }
    }
}
