package com.nostrvault.service

import android.util.Base64
import android.util.Log
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.remote.BlossomClient
import com.nostrvault.data.remote.LocalTls
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.sync.withPermit
import kotlinx.serialization.json.*
import okhttp3.*
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.RequestBody.Companion.asRequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.File
import java.io.IOException
import java.security.MessageDigest
import java.util.concurrent.Semaphore
import java.util.concurrent.TimeUnit
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Full Blossom media service.
 * Handles BUD-02 uploads, mirroring to external servers,
 * downloading, deletion, and mirror status checks.
 *
 * Port of BlossomService.swift.
 */
@Singleton
class BlossomService @Inject constructor(
    internal val configStore: ConfigStore,
    internal val nostrService: NostrService,
    private val mediaCacheService: MediaCacheService,
    /** "Last ran" times for the Vault Dashboard (iOS VaultHistory). */
    private val vaultHistory: com.nostrvault.data.local.VaultHistoryStore,
    internal val homeVault: com.nostrvault.fips.HomeVaultSender,
    /** The photo screen's server answers, kept on disk for a day. */
    private val presenceStore: BlossomPresenceStore = BlossomPresenceStore(file = null),
    /** Auto-Mirror's last start and fetched links, kept across launches. */
    internal val autoMirrorState: AutoMirrorState = AutoMirrorState(dir = null),
) {
    companion object {
        internal const val TAG = "BlossomService"
        internal const val AUTH_KIND = 24242
        internal const val MAX_UPLOAD_RETRIES = 3

        /** Signer attempts for one Blossom auth event, and the pause between them. */
        internal const val AUTH_SIGN_ATTEMPTS = 3
        internal const val AUTH_SIGN_RETRY_DELAY_MS = 1_000L
        private const val MIRROR_CONCURRENCY = 4

        /** Hard ceiling on any single downloaded blob held in memory. */
        internal const val MAX_BLOB_BYTES = 50L * 1024 * 1024 // 50 MB

        /** How long a mesh delete keeps retrying a link that is still coming up, and the pause between tries. */
        internal const val MESH_DELETE_PATIENCE_MS = 20_000L
        internal const val MESH_DELETE_RETRY_MS = 1_000L
        /** Auto-Mirror lists every server and scans every note, so it waits this long after the last start. */
        internal const val AUTO_MIRROR_EVERY_MS = AutoMirrorRules.EVERY_MS

        /** Whether the Media tab's Auto-Mirror should run, given the last finished import (iOS `autoMirrorEvery`). */
        /**
         * A Mirror Now result. A server that didn't answer is named: "All media
         * already mirrored" was shown when the only server couldn't be reached.
         */
        internal fun mirrorResultText(count: Int, unreachableHosts: List<String>): String {
            val done = if (count > 0) "Mirrored $count file${if (count == 1) "" else "s"}" else null
            if (unreachableHosts.isEmpty()) return done ?: "All media already mirrored"
            val missed = "Couldn't reach ${unreachableHosts.distinct().joinToString(", ")}"
            return if (done != null) "$done. $missed" else missed
        }

        internal fun autoMirrorDue(lastImport: Long?, now: Long): Boolean = AutoMirrorRules.due(lastImport, now)
    }

    internal val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val json = Json { ignoreUnknownKeys = true }
    private val mirrorSemaphore = Semaphore(MIRROR_CONCURRENCY)

    internal val localClient = OkHttpClient.Builder()
        .connectTimeout(30, TimeUnit.SECONDS)
        .writeTimeout(120, TimeUnit.SECONDS)
        .readTimeout(60, TimeUnit.SECONDS)
        .applyLocalhostTrust()
        .build()

    /**
     * One mirror-from-servers run shared by Settings, the dashboard and the
     * Media tab's auto-mirror, like iOS MirrorService: a second start while
     * one runs is ignored.
     */
    data class MirrorRun(
        val running: Boolean = false,
        /** 0..1 once the blob count is known, else null. */
        val progress: Float? = null,
        val status: String = "",
        /** "Mirrored N files" / "All media already mirrored" after a run. */
        val lastResult: String = "",
    )

    private val _mirrorRun = MutableStateFlow(MirrorRun())
    val mirrorRun: StateFlow<MirrorRun> = _mirrorRun.asStateFlow()

    /**
     * The Media tab's Auto-Mirror: a mirror run, unless one started in the
     * last 3 hours (a relaunch mid-run does not reset that). False when it didn't start.
     */
    fun runAutoMirrorIfDue(now: Long = System.currentTimeMillis()): Boolean {
        val lastImport = vaultHistory.state.value[com.nostrvault.data.local.VaultHistory.Entry.MEDIA_IMPORT]
        if (!autoMirrorDue(listOfNotNull(autoMirrorState.lastStart, lastImport).maxOrNull(), now)) return false
        return runMirror(startedAt = now)
    }

    /**
     * Starts a mirror-from-servers run; false if one is already running.
     * One signature and at most [AutoMirrorRules.MAX_PER_RUN] downloads for
     * the whole run ([RunLimits]); the rest come next run.
     */
    fun runMirror(startedAt: Long = System.currentTimeMillis()): Boolean {
        synchronized(_mirrorRun) {
            if (_mirrorRun.value.running) return false
            _mirrorRun.value = MirrorRun(running = true, status = "Starting...")
        }
        autoMirrorState.recordStart(startedAt)
        val limits = RunLimits(RunSignature { ownVaultAuth(listOf("list", "upload")) })
        scope.launch {
            val result = try {
                var count = 0
                val unreachable = java.util.concurrent.CopyOnWriteArrayList<String>()
                // 1. From your Blossom servers (their /list of your files).
                if (configStore.config.value.activeBlossomMirrors.isNotEmpty()) {
                    count += mirrorAllFromExternal(
                        onProgress = { pct -> _mirrorRun.value = _mirrorRun.value.copy(progress = pct) },
                        onLogMessage = { msg -> _mirrorRun.value = _mirrorRun.value.copy(status = msg) },
                        onUnreachable = { unreachable += it },
                        limits = limits,
                    )
                }
                // 2. From the media links in your notes, on any server (iOS MirrorService).
                _mirrorRun.value = _mirrorRun.value.copy(status = "Scanning notes for media...", progress = null)
                count += mirrorFromNoteMedia(
                    onProgress = { pct -> _mirrorRun.value = _mirrorRun.value.copy(progress = pct) },
                    onLogMessage = { msg -> _mirrorRun.value = _mirrorRun.value.copy(status = msg) },
                    limits = limits,
                )
                vaultHistory.record(com.nostrvault.data.local.VaultHistory.Entry.MEDIA_IMPORT)
                mirrorResultText(count, unreachable.map(::serverHost))
            } catch (e: Exception) {
                Log.w(TAG, "Mirror run failed: ${e.message}")
                "Mirror failed: ${e.message}"
            } finally {
                autoMirrorState.saveIfChanged()
            }
            _mirrorRun.value = MirrorRun(lastResult = result)
        }
        return true
    }

    init {
        homeVault.hostPublicly = { sha256, contentType, server, auth ->
            hostLocalBlob(sha256, contentType, servers = listOf(server), authHeader = auth) == "$server/$sha256"
        }
    }

    /**
     * No public server took [sha256], but the owner's home vault has it:
     * publish under the first public server's https URL now, and keep
     * pushing the copy there. NIP-F1 readers find it on the vault by hash
     * through the owner's 10063; other apps once the public copy lands.
     * Never mesh-only (NIP-F1): with no public server there is no URL to
     * publish, so this is null, as when there is no home vault or the vault
     * doesn't have it.
     */
    internal suspend fun hostedViaHomeVault(sha256: String, contentType: String, mirrors: List<String>): PostUploadOutcome? {
        homeVault.homeVaultNpub ?: return null
        val server = com.nostrvault.fips.HomeVaultRules.publicServerFor(mirrors) {
            com.nostrvault.relay.isPrivateNetworkURL(it)
        } ?: return null
        if (!homeVault.ensureOnVault(sha256)) return null
        // No queued copy (queue full), no URL: the post waits instead.
        if (!homeVault.needsPublicCopy(sha256, contentType, server)) return null
        Log.i(TAG, "${sha256.take(8)}: only on the home vault; publishing under $server, public copy pending")
        return PostUploadOutcome.Hosted("$server/$sha256")
    }

    // Idle limits (no bytes moving), not totals: a big video keeps uploading
    // as long as bytes flow. 10-15 minutes of silence from a dead server used
    // to hold the post.
    internal val remoteClient = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .writeTimeout(60, TimeUnit.SECONDS)
        .readTimeout(60, TimeUnit.SECONDS)
        .build()

    /**
     * [remoteClient] for a URL another app chose (the clipboard): every hop,
     * redirects included, must have connected to a public address, so a link
     * can't reach this device's relay on 127.0.0.1 or a LAN host. Checked on
     * the connected socket, so a name that re-resolves to 127.0.0.1 is caught too.
     */
    internal val publicOnlyClient = remoteClient.newBuilder()
        .addNetworkInterceptor { chain ->
            val addr = chain.connection()?.socket()?.inetAddress
            if (addr == null || com.nostrvault.util.UrlSafety.isInternalAddress(addr)) {
                throw IOException("Refused: ${chain.request().url.host} is not a public address")
            }
            chain.proceed(chain.request())
        }
        .build()

    // ══════════════════════════════════════════════════════════════════
    // Upload + Mirror
    // ══════════════════════════════════════════════════════════════════

    /**
     * Upload to local relay, then mirror to external servers.
     * @return External URL from first successful mirror, or null.
     * @param allowLocalFallback when true, a successful local-relay save counts as
     *   success and the LOCAL url is returned if every external mirror fails —
     *   for save-to-vault flows (gallery/share-sheet) where the blob just needs
     *   to be stored. DMs must leave this false: a URL embedded in a published
     *   event must be reachable by other clients, and a localhost URL silently
     *   masks the mirror failure. The note composer uses [uploadForPost].
     */
    suspend fun uploadAndMirror(
        data: ByteArray,
        sha256: String,
        contentType: String,
        onProgress: ((Float) -> Unit)? = null,
        allowLocalFallback: Boolean = false,
        toHomeVault: Boolean = true,
    ): String? = uploadAndMirror(UploadSource.Data(data), sha256, contentType, allowLocalFallback, toHomeVault)

    suspend fun uploadAndMirror(
        fileURL: File,
        sha256: String,
        contentType: String,
        onProgress: ((Float) -> Unit)? = null,
        allowLocalFallback: Boolean = false,
        toHomeVault: Boolean = true,
    ): String? = uploadAndMirror(UploadSource.FileSource(fileURL), sha256, contentType, allowLocalFallback, toHomeVault)

    private suspend fun uploadAndMirror(
        source: UploadSource,
        sha256: String,
        contentType: String,
        allowLocalFallback: Boolean,
        toHomeVault: Boolean,
    ): String? {
        val attempt = upload(source, sha256, contentType, skipOutsideServers = false, toHomeVault = toHomeVault)
        if (toHomeVault) homeVault.drainSoon()
        return when (val outcome = attempt.outcome) {
            is PostUploadOutcome.Hosted -> outcome.url
            // Local-relay URL, only ever returned for save-to-vault flows.
            else -> if (allowLocalFallback) attempt.localUrl else null
        }
    }

    /**
     * Where a post's attachment ended up. Four situations with four different
     * remedies — they used to share one null and one message ("check your
     * connection"), which sent us looking at the network when the blob was
     * sitting safely in the phone's own relay.
     */
    sealed class PostUploadOutcome {
        /** An outside server accepted it; this URL goes in the note. */
        data class Hosted(val url: String) : PostUploadOutcome()

        /**
         * In this device's relay, but no outside server took it. The post can
         * wait for one (`MediaPostQueue`). [unreachable] is what was tried.
         */
        data class SavedOnDevice(val unreachable: List<String>) : PostUploadOutcome()

        /** In this device's relay, and there is no outside server to try. */
        data object NoOutsideServer : PostUploadOutcome()

        /** Never reached this device's relay (and no outside server took it either). */
        data object NotSavedOnDevice : PostUploadOutcome()
    }

    /**
     * Upload a note attachment: this device's relay first, then the outside
     * Blossom servers. [skipOutsideServers] saves locally only — used once an
     * earlier attachment of the same post found every outside server down, so
     * the rest don't each wait out the same 10 s retry.
     */
    suspend fun uploadForPost(
        fileURL: File,
        sha256: String,
        contentType: String,
        skipOutsideServers: Boolean = false,
        onProgress: ((Float) -> Unit)? = null,
        /** The account the note posts as; it signs the upload (null: the owner). */
        signAs: com.nostrvault.data.model.PostingAccount.Lock? = null,
    ): PostUploadOutcome =
        upload(UploadSource.FileSource(fileURL), sha256, contentType, skipOutsideServers, signAs = signAs).outcome
            .also { homeVault.drainSoon() }

    /** What one upload did, plus the local URL when the local save succeeded. */
    internal data class UploadAttempt(val outcome: PostUploadOutcome, val localUrl: String?)

    /**
     * Fire a cheap unauthenticated HEAD at every configured mirror so sleeping
     * hosts (notably a Mac relay woken by wake-on-network) start waking as soon
     * as the composer opens, instead of during the post itself. Fire-and-forget;
     * responses are ignored — this is connection warming only.
     */
    fun prewarmMirrors() {
        val mirrors = configStore.config.value.activeBlossomMirrors
        if (mirrors.isEmpty()) return
        scope.launch {
            mirrors.forEach { mirror ->
                launch {
                    try {
                        val client = if (isLocalhost(mirror)) localClient else remoteClient
                        val request = Request.Builder().url(mirror).head().build()
                        client.newCall(request).execute().close()
                    } catch (_: Exception) {
                        // Warming only — failures are expected while a host wakes.
                    }
                }
            }
        }
    }

    /**
     * Back up a piece of external feed media to the local relay's Blossom store.
     *
     * Port of iOS FeedMediaViewer.mirrorToBlossomTapped(): downloads the bytes,
     * derives their sha256, and uploads to the local relay. Unlike [downloadFromURL]
     * this reports whether the local save actually succeeded (it returns the blob's
     * sha256), so the feed viewer can show an accurate "Mirrored / Failed" result.
     *
     * @param publicOnly when the URL came from another app (the clipboard):
     *   refuse loopback/LAN addresses on every hop ([publicOnlyClient]).
     * @return the blob's sha256 on success, or null if the download or local save failed.
     */
    suspend fun mirrorUrlToLocal(
        url: String,
        authHeader: String? = null,
        publicOnly: Boolean = false,
        /** Import media's way into the vault (keyless or signed); null: [authHeader], signed here if null. */
        ownVault: OwnVaultAuth? = null,
        /** Told why a file was not stored (no room, bad hash, cut short), for the import log. */
        onSkip: ((String) -> Unit)? = null,
    ): String? = withContext(Dispatchers.IO) {
        try {
            val request = Request.Builder().url(url).get().build()
            val client = if (publicOnly) publicOnlyClient else remoteClient
            var contentType: String
            var blob: StreamedBlob
            while (true) {
                val response = client.newCall(request).execute()
                if (!response.isSuccessful) {
                    response.close()
                    Log.w(TAG, "Mirror $url to local: download HTTP ${response.code}")
                    return@withContext null
                }
                // Prefer the source server's Content-Type — it's the authoritative format
                // metadata; the relay's magic library can't detect MP4/MOV from bytes alone.
                contentType = response.header("Content-Type") ?: "application/octet-stream"
                // To disk through one small buffer, then into the vault from the file (StreamedBlob.kt):
                // no size cap, only a free-storage check.
                when (val got = streamToTempFile(response)) {
                    is StreamResult.Ok -> { blob = got.blob; break }
                    StreamResult.Busy -> BigFileGate.shared.waitTurn()
                    is StreamResult.Skipped -> {
                        Log.w(TAG, "Mirror $url to local skipped: ${got.reason}")
                        onSkip?.invoke(got.reason)
                        return@withContext null
                    }
                }
            }
            val sha256 = blob.sha256
            if (storeStreamed(blob, contentType, ownVault, authHeader)) sha256 else null
        } catch (e: Exception) {
            Log.w(TAG, "Mirror $url to local failed: ${e.message}")
            null
        }
    }

    /**
     * What pushing one blob from this device's relay to the outside servers
     * did. "Pushed to mirrors" used to be shown whatever happened, including
     * when every server refused the upload.
     */
    sealed class MirrorPushResult {
        /** Every server tried accepted the blob. */
        data class AllAccepted(val count: Int) : MirrorPushResult()

        /** Some servers accepted it, some did not. */
        data class Partial(val accepted: Int, val attempted: Int) : MirrorPushResult()

        /** Every server tried refused it or could not be reached. */
        data class AllFailed(val attempted: Int) : MirrorPushResult()

        /** No outside server is configured (or none of the requested ones is). */
        data object NoOutsideServer : MirrorPushResult()

        /** The blob could not be read from this device's relay. */
        data object NotOnDevice : MirrorPushResult()

        /** The upload could not be signed. */
        data object SignerUnavailable : MirrorPushResult()

        /** At least one outside server now holds the blob. */
        val anyAccepted: Boolean get() = this is AllAccepted || this is Partial

        /** One short line for a toast. Wording follows iOS (PR #109). */
        val message: String
            get() = when (this) {
                is AllAccepted -> "Pushed to mirrors"
                is Partial -> "Copied to $accepted of $attempted media servers"
                is AllFailed -> "Could not push to mirrors"
                NoOutsideServer -> "No media servers added"
                NotOnDevice -> "Could not read this file from your vault"
                SignerUnavailable -> "Could not sign the upload"
            }

        companion object {
            fun of(accepted: Int, attempted: Int): MirrorPushResult = when {
                attempted <= 0 -> NoOutsideServer
                accepted >= attempted -> AllAccepted(attempted)
                accepted > 0 -> Partial(accepted, attempted)
                else -> AllFailed(attempted)
            }
        }
    }

    /** How a Save to Vault went, and the line to show for it. */
    enum class VaultSave(val message: String) {
        FAILED("Could not save to your vault"),
        ON_PHONE("Saved to your vault on this phone"),
        BACKED_UP("Saved to your vault and your media servers"),
    }

    /** What Save to Vault did, and the hash the vault stored the downloaded bytes under (null on failure). */
    data class VaultSaveResult(val outcome: VaultSave, val savedSha: String?)

    /**
     * Stores a file that is only on outside servers (or a link) in the vault
     * on this phone. Then, only when the URL itself names the blob (its last
     * path part is the 64-hex hash), uploads it to any server that lacks it;
     * otherwise it stays on this phone only. Port of iOS
     * `MediaBackupActions.saveToVault`, which guards on `blossomHash(in:)`.
     */
    suspend fun saveUrlToVault(url: String): VaultSaveResult {
        val saved = mirrorUrlToLocal(url) ?: return VaultSaveResult(VaultSave.FAILED, null)
        val hash = blossomHashInUrl(url)
        if (hash == null || configStore.config.value.activeBlossomMirrors.isEmpty()) {
            return VaultSaveResult(VaultSave.ON_PHONE, saved)
        }
        val backedUp = pushToMissing(hash).let { it == null || it is MirrorPushResult.AllAccepted }
        return VaultSaveResult(if (backedUp) VaultSave.BACKED_UP else VaultSave.ON_PHONE, saved)
    }

    /**
     * Push a blob that is already in this device's relay to the outside
     * servers. [only] limits the upload to those servers (the ones missing the
     * blob); null means every configured server. Port of iOS
     * `pushLocalToMirrors(sha256:only:)`.
     */
    suspend fun pushLocalToMirrors(sha256: String, only: Collection<String>? = null): MirrorPushResult =
        withContext(Dispatchers.IO) {
            val configured = configStore.config.value.activeBlossomMirrors
            val mirrors = if (only == null) configured else configured.filter { it in only }
            if (mirrors.isEmpty()) {
                Log.w(TAG, "Push of ${sha256.take(8)}: no outside Blossom server to push to")
                return@withContext MirrorPushResult.NoOutsideServer
            }

            val localUrl = localBlossomURL() ?: return@withContext MirrorPushResult.NotOnDevice

            // Read from this device's relay.
            var contentType = "application/octet-stream"
            val data = try {
                val request = Request.Builder().url("$localUrl/$sha256").get().build()
                clientFor(localUrl).newCall(request).execute().use { response ->
                    if (!response.isSuccessful) {
                        Log.w(TAG, "Push of ${sha256.take(8)}: local read HTTP ${response.code}")
                        return@withContext MirrorPushResult.NotOnDevice
                    }
                    response.header("Content-Type")?.takeIf { it.isNotBlank() }?.let { contentType = it }
                    readBodyCapped(response, MAX_BLOB_BYTES)
                } ?: return@withContext MirrorPushResult.NotOnDevice
            } catch (e: Exception) {
                Log.w(TAG, "Local download failed: ${e.message}")
                return@withContext MirrorPushResult.NotOnDevice
            }

            // Sign once and reuse across all mirrors (external signers fail on
            // concurrent signing requests).
            val authHeader = createAuthHeader("upload", sha256)
            if (authHeader.isEmpty()) {
                Log.e(TAG, "Push aborted: could not create Blossom auth event (signer unavailable)")
                return@withContext MirrorPushResult.SignerUnavailable
            }

            val tookIt = mirrors.map { mirror ->
                async {
                    try {
                        uploadToServer(
                            source = UploadSource.Data(data),
                            serverUrl = mirror,
                            sha256 = sha256,
                            contentType = contentType,
                            authHeader = authHeader,
                        ) != null
                    } catch (e: Exception) {
                        Log.w(TAG, "Push to mirror $mirror failed: ${e.message}")
                        false
                    }
                }
            }.awaitAll()
            val accepted = tookIt.count { it }
            // The owner's other devices hear of it on /files (a first note for it; a device's second is a duplicate).
            val hosted = mirrors.filterIndexed { i, _ -> tookIt[i] }
            if (hosted.isNotEmpty()) homeVault.offerFileNote(sha256, contentType, data.size.toLong(), hosted)

            MirrorPushResult.of(accepted, mirrors.size).also {
                Log.i(TAG, "Push of ${sha256.take(8)}: $accepted of ${mirrors.size} servers accepted")
            }
        }

    /**
     * Mirror all blobs from external to local.
     * @return how many blobs were saved to the local relay.
     */
    suspend fun mirrorAllFromExternal(
        onProgress: ((Float) -> Unit)? = null,
        onLogMessage: ((String) -> Unit)? = null,
        /** A server whose list of your files couldn't be read (no answer, or an error status). */
        onUnreachable: ((String) -> Unit)? = null,
        /** The run's one signature and download cap; alone (setup), its own signature and no cap. */
        limits: RunLimits = RunLimits(RunSignature { ownVaultAuth(listOf("list", "upload")) }, cap = Int.MAX_VALUE),
    ): Int = withContext(Dispatchers.IO) {
        BlobStream.sweepLeftovers()
        val mirrors = configStore.config.value.activeBlossomMirrors
        val ownerPubkey = nostrService.ownerHexPubkey

        val allHashes = mutableSetOf<String>()

        // Sign ONE kind 24242 auth event for the ENTIRE mirror-in and reuse it for
        // both the remote /list and every local /upload. It carries both "t" verbs
        // (list + upload) and no "x", so the relay accepts it for either operation
        // (upload isn't bound to a blob hash; list matches the "list" verb). This is
        // a single signer round-trip — one Amber/NIP-46 prompt for the whole pull,
        // instead of one per mirror plus one per blob.
        // A keyless vault signs nothing: its uploads go in-process (OwnVaultAuth).
        val ownVault = limits.signature.get()
        val batchAuth = (ownVault as? OwnVaultAuth.Signed)?.header.orEmpty()

        // Fetch blob lists from each mirror
        for (mirror in mirrors) {
            try {
                val request = Request.Builder()
                    .url("$mirror/list/$ownerPubkey")
                    .get()
                    .apply { if (batchAuth.isNotEmpty()) addHeader("Authorization", "Nostr $batchAuth") }
                    .build()

                val body = remoteClient.newCall(request).execute().use { response ->
                    if (response.isSuccessful) response.body?.string() else null
                }
                if (body == null) {
                    onUnreachable?.invoke(mirror)
                    continue
                }
                val blobs = json.decodeFromString<List<BlobDescriptor>>(body)
                blobs.mapNotNull { it.sha256 }.forEach { allHashes.add(it) }
            } catch (e: Exception) {
                Log.w(TAG, "Blob list fetch from $mirror failed: ${e.message}")
                onUnreachable?.invoke(mirror)
            }
        }

        // Filter to hashes not in local Blossom
        val missing = allHashes.filter { !mediaCacheService.isInLocalBlossom(it) }
        onLogMessage?.invoke("Found ${missing.size} blobs to mirror")
        if (missing.isEmpty()) return@withContext 0
        if (ownVault == null) {
            onLogMessage?.invoke("Mirror aborted: could not sign auth event (signer unavailable)")
            return@withContext 0
        }

        val completed = java.util.concurrent.atomic.AtomicInteger(0)
        val saved = java.util.concurrent.atomic.AtomicInteger(0)
        coroutineScope {
            for (hash in missing) {
                if (!limits.take()) break
                mirrorSemaphore.acquire()
                launch {
                    try {
                        val blob = downloadFromMirrors(hash) { onLogMessage?.invoke("Skipped ${hash.take(8)}: $it") }
                        if (blob != null && storeStreamed(blob, "application/octet-stream", ownVault)) {
                            saved.incrementAndGet()
                        }
                    } finally {
                        mirrorSemaphore.release()
                        onProgress?.invoke(completed.incrementAndGet().toFloat() / missing.size)
                    }
                }
            }
        }
        saved.get()
    }

    /**
     * Copies in the media your own notes link to on outside servers: your
     * notes are read from this device's relay, page by page, and each link
     * not already here is downloaded and stored, four at a time, under one
     * signed upload authorisation. iOS `BlossomService.mirrorFromNoteMedia`.
     * @return how many files were saved.
     */
    suspend fun mirrorFromNoteMedia(
        onProgress: ((Float) -> Unit)? = null,
        onLogMessage: ((String) -> Unit)? = null,
        limits: RunLimits = RunLimits(RunSignature { ownVaultAuth(listOf("list", "upload")) }, cap = Int.MAX_VALUE),
    ): Int = withContext(Dispatchers.IO) {
        BlobStream.sweepLeftovers()
        val owner = nostrService.ownerHexPubkey
        val relay = configStore.config.value.nostrURL
        if (owner.isEmpty() || relay == null) return@withContext 0

        val notes = NoteMediaScan.collect(owner) { filter ->
            nostrService.queryRawEvents(listOf(filter), listOf(relay), timeoutMs = 8_000L)
        }
        val urls = notes.flatMap { note ->
            nostrService.extractMediaURLs(note.content, note.pubkey, note.tags, note.createdAt).map { it.url }
        }
        onLogMessage?.invoke("Found ${urls.size} media link(s) in ${notes.size} note(s)")
        // A link's hash, known before any download: its name, the note's imeta x, or an earlier run.
        val imeta = notes.fold(HashMap<String, String>()) { acc, n -> acc.apply { putAll(AutoMirrorRules.imetaHashes(n.tags)) } }
        val toImport = NoteMediaScan.urlsToImport(urls, knownHash = { imeta[it] ?: autoMirrorState.hashFor(it) }) {
            mediaCacheService.isInLocalBlossom(it)
        }
        if (toImport.isEmpty()) {
            onLogMessage?.invoke("All note media already exists locally")
            return@withContext 0
        }
        // The run's one signature for every upload (none when keyless).
        val auth = limits.signature.get()
        if (auth == null) {
            onLogMessage?.invoke("Note media skipped: could not sign the upload (signer unavailable)")
            return@withContext 0
        }
        onLogMessage?.invoke("${toImport.size} media item(s) missing locally — downloading...")
        val completed = java.util.concurrent.atomic.AtomicInteger(0)
        val saved = java.util.concurrent.atomic.AtomicInteger(0)
        coroutineScope {
            for (url in toImport) {
                if (!limits.take()) break
                mirrorSemaphore.acquire()
                launch {
                    try {
                        val sha = mirrorUrlToLocal(url, ownVault = auth) { onLogMessage?.invoke("Skipped $url: $it") }
                        if (sha != null) {
                            autoMirrorState.remember(url, sha)
                            saved.incrementAndGet()
                        }
                    } finally {
                        mirrorSemaphore.release()
                        onProgress?.invoke(completed.incrementAndGet().toFloat() / toImport.size)
                    }
                }
            }
        }
        autoMirrorState.saveIfChanged()
        onLogMessage?.invoke("Mirror from notes complete: ${saved.get()} new file(s)")
        saved.get()
    }

    // ══════════════════════════════════════════════════════════════════
    // Deletion
    // ══════════════════════════════════════════════════════════════════

    /**
     * Which servers a delete reached. A delete is only done when [failed] is
     * empty: the file is still public on every server listed there.
     * Port of iOS `BlossomService.MirrorDeleteResult`.
     */
    data class MirrorDeleteResult(
        val deleted: List<String> = emptyList(),
        val failed: List<String> = emptyList(),
        /** What to call a mesh device in [failedHosts] ("Studio Mac"), by its `fipsmesh://` entry. */
        val names: Map<String, String> = emptyMap(),
        /** Left alone by Delete from mirrors: the owner runs them (NIP-11 pubkey), so their copy stays. */
        val skipped: List<String> = emptyList(),
    ) {
        val allDeleted: Boolean get() = failed.isEmpty() && deleted.isNotEmpty()

        /** Places still holding the file, for the banner ("blossom.primal.net", "Studio Mac"). */
        val failedHosts: List<String> get() = failed.map { names[it] ?: serverHost(it) }

        /** The owner's own vaults the delete left alone ("studio-mac.example.net"). */
        val skippedHosts: List<String> get() = skipped.map { names[it] ?: serverHost(it) }
    }

    /**
     * Delete a blob from every server that may hold it and report each one:
     * see [HavenConfig.blossomDeleteTargets]. "Delete from mirrors" leaves the
     * home vault out; "Delete everywhere" sets [includeHomeVault]. [photoUrl]
     * is where the photo was seen, so its own host is asked too. A 404 counts
     * as deleted: the file is not there either way. One mirror succeeding used
     * to count as success, so a file left on two of three servers read as deleted.
     * Delete everywhere also reaches the owner's mesh devices: [deleteOverMesh].
     */
    suspend fun deleteFromServers(
        sha256: String,
        photoUrl: String?,
        includeHomeVault: Boolean,
        /** The account that uploaded it signs the delete (null: the account active now). */
        signAs: com.nostrvault.data.model.PostingAccount.Lock? = null,
    ): MirrorDeleteResult = withContext(Dispatchers.IO) {
        val config = configStore.config.value
        // The active account signs, and its own published servers (kind 10063) are the list, as on
        // iOS: an added account's photo signed by the owner was refused by its mirror. Locked now,
        // so a switch mid-delete fails the token instead of signing as the other account.
        val account = signAs ?: nostrService.lockPostingAccount()
        val published = nostrService.serverLists.value[account.hex].orEmpty()
        val mirrors = config.blossomDeleteTargets(published, photoUrl, includeHomeVault)
        val mesh = com.nostrvault.fips.MeshDeleteTargets.of(config, includeHomeVault)
        if (mirrors.isEmpty() && mesh.isEmpty()) return@withContext MirrorDeleteResult()

        val owner = nostrService.ownerHexPubkey
        val outcomes = mirrors.map { mirror ->
            async {
                // Delete from mirrors: a server the owner runs is a home vault under a name this
                // device does not know (another phone's Mac, a tunnel). Its copy stays; a server
                // that cannot say who runs it is not deleted from either (Tron ship check, 2026-10-31).
                if (!includeHomeVault) when (serverOwner(mirror, owner)) {
                    ServerOwner.OWNER -> return@async Outcome.SKIPPED
                    ServerOwner.UNKNOWN -> return@async Outcome.LEFT
                    ServerOwner.OTHER -> Unit
                }
                val gone = try {
                    val deleteUrl = "${mirror.trimEnd('/')}/$sha256"
                    // A URL whose host can't be named in the token is not sent one: it could be replayed.
                    if (deleteUrl.toHttpUrlOrNull() == null) return@async Outcome.LEFT
                    val authHeader = createDeleteAuthHeader(sha256, deleteUrl, account)
                    val request = Request.Builder()
                        .url(deleteUrl)
                        .delete()
                        .addHeader("Authorization", "Nostr $authHeader")
                        .build()

                    remoteClient.newCall(request).execute().use { response ->
                        val gone = response.isSuccessful || response.code == 404
                        if (!gone) Log.w(TAG, "Delete from $mirror: HTTP ${response.code}")
                        gone
                    }
                } catch (e: Exception) {
                    Log.w(TAG, "Delete from $mirror failed: ${e.message}")
                    false
                }
                if (gone) Outcome.GONE else Outcome.LEFT
            }
        }
        // This device's mesh key for the mesh devices (MeshDeleteAuth). The owner's fallback names every mesh vault
        // (`<npub>.fips`, which a vault takes as itself) and covers the DELETE and the HEAD; owner's devices only.
        val meshAuth = MeshDeleteAuth.of(sha256, mesh.map { it.npub }) {
            signAuthHeader(
                "delete+get", sha256,
                BlossomDeleteAuth.tags(sha256, "", operations = listOf("delete", "get"), servers = mesh.map { "${it.npub}.fips" }),
            ).takeIf { it.isNotEmpty() }
        }
        val meshOutcomes = mesh.map { target -> async { target.key to deleteOnMeshDevice(target.npub, sha256, meshAuth) } }
        val served = mirrors.zip(outcomes.awaitAll())
        val all = served.filter { it.second != Outcome.SKIPPED }.map { it.first to (it.second == Outcome.GONE) } + meshOutcomes.awaitAll()
        // Delete everywhere, and something took it: every open Media tab of the owner's drops the tile (/files
        // kind 5, plan gap 3). Not Delete from mirrors: the home vault still has it, so the tile is still good.
        if (includeHomeVault && account.hex.equals(owner, ignoreCase = true) && all.any { it.second }) {
            homeVault.offerFileNoteDelete(sha256)
        }
        MirrorDeleteResult(
            deleted = all.filter { it.second }.map { it.first },
            failed = all.filterNot { it.second }.map { it.first },
            names = mesh.associate { it.key to it.name },
            skipped = served.filter { it.second == Outcome.SKIPPED }.map { it.first },
        )
    }

    /** One server's delete: gone (or 404), still there, or the owner's own vault left alone. */
    private enum class Outcome { GONE, LEFT, SKIPPED }

    /** Who runs a Blossom server, as [askServerOwner] reads it. */
    enum class ServerOwner { OWNER, OTHER, UNKNOWN }

    /** [askServerOwner], swapped in tests. */
    internal var serverOwner: suspend (server: String, ownerHex: String) -> ServerOwner = { server, owner -> askServerOwner(server, owner) }

    /**
     * Whether [ownerHex] runs [server]: a Haven vault serves its NIP-11 relay info at the root of
     * the same address as its Blossom server, with the owner as `pubkey` (OUTBOX_RELAY_NPUB, every
     * platform). Any other answer, or a 4xx, is someone else's server. No answer (offline, 5xx from
     * a tunnel whose Mac is down) is [ServerOwner.UNKNOWN]: it may be the vault, so no delete.
     */
    internal fun askServerOwner(server: String, ownerHex: String): ServerOwner {
        val origin = com.nostrvault.relay.blossomOrigin(server) ?: return ServerOwner.UNKNOWN
        val request = try {
            Request.Builder().url("$origin/").get().header("Accept", "application/nostr+json").build()
        } catch (_: IllegalArgumentException) {
            return ServerOwner.UNKNOWN
        }
        return try {
            ownerProbeClient.newCall(request).execute().use { response ->
                when {
                    response.code >= 500 -> ServerOwner.UNKNOWN
                    !response.isSuccessful -> ServerOwner.OTHER
                    else -> ownerVerdict(relayInfoPubkey(response.peekBody(64 * 1024).string()), ownerHex)
                }
            }
        } catch (e: IOException) {
            Log.w(TAG, "Who runs $origin: ${e.message}")
            ServerOwner.UNKNOWN
        }
    }

    /**
     * A relay info [pubkey] read against [ownerHex], as iOS `vaultCheckVerdict`: no pubkey is a
     * public server's page; a pubkey with no owner to compare it to may be the vault, so no delete.
     */
    internal fun ownerVerdict(pubkey: String, ownerHex: String): ServerOwner = when {
        pubkey.isBlank() -> ServerOwner.OTHER
        ownerHex.isBlank() -> ServerOwner.UNKNOWN
        pubkey.trim().equals(ownerHex.trim(), ignoreCase = true) -> ServerOwner.OWNER
        else -> ServerOwner.OTHER
    }

    private val ownerProbeClient by lazy { remoteClient.newBuilder().callTimeout(10, TimeUnit.SECONDS).build() }

    /** The loopback base reaching [npub]'s vault over the mesh, or null. Swapped in tests. */
    internal var meshIngress: (String) -> String? = { com.nostrvault.fips.FipsMediaRouter.ingressBase(it) }
    internal var meshForget: (String) -> Unit = { com.nostrvault.fips.FipsMediaRouter.forget(it) }
    internal var meshRetryDelayMs = MESH_DELETE_RETRY_MS

    /** @return true if the file is gone from this device (deleted, or never stored here). */
    fun deleteFromLocal(sha256: String): Boolean {
        // Gone from this device: nothing still queued sends it on (device sync map §4.3).
        homeVault.forgetBlob(sha256)
        val config = configStore.config.value
        val dir = config.relayDataDir?.let { File(it, config.blossomPath) } ?: return false
        // Bare-hash file (how the relay stores blobs) is the common case.
        val exact = File(dir, sha256)
        if (exact.exists()) return exact.delete()

        // Otherwise delete any `<hash>.<ext>` variant, regardless of extension
        // (covers audio/documents, not just images/video).
        val matches = dir.listFiles { f -> f.isFile && f.nameWithoutExtension == sha256 }
        if (!matches.isNullOrEmpty()) {
            return matches.all { it.delete() }
        }
        // Nothing to delete is the outcome asked for, like a mirror's 404.
        return true
    }

    // ══════════════════════════════════════════════════════════════════
    // Mirror status
    // ══════════════════════════════════════════════════════════════════

    /**
     * Each server's last answer per blob, kept for a day (on disk, see
     * [BlossomPresenceStore]). The viewer, the menus and the dashboard all
     * read this one map, so a file cannot show "3/3" in one place and offer
     * a Mirror button in another.
     */
    internal val _mirrorPresence = kotlinx.coroutines.flow.MutableStateFlow<Map<String, Map<String, BlobPresence>>>(emptyMap())
    val mirrorPresence: kotlinx.coroutines.flow.StateFlow<Map<String, Map<String, BlobPresence>>> = _mirrorPresence

    init {
        // Yesterday's answers, under any checks that finish first.
        scope.launch { presenceStore.load().presence().takeIf { it.isNotEmpty() }?.let { saved -> _mirrorPresence.update { saved + it } } }
    }

    /** Checks running now, by hash, so a grid of tiles asks each server once per blob. */
    private val presenceInFlight = mutableMapOf<String, Deferred<Map<String, BlobPresence>>>()

    /** Caps blobs checked at once; a scrolled grid would otherwise fire hundreds of HEADs. */
    private val presenceGate = kotlinx.coroutines.sync.Semaphore(6)

    /**
     * Check if a blob exists on each mirror. A server that could not be asked
     * counts as "does not have it" here; use [checkMirrorPresence] to tell the two apart.
     */
    suspend fun checkMirrorStatus(sha256: String, force: Boolean = true): Map<String, Boolean> =
        checkMirrorPresence(sha256, force).mapValues { it.value == BlobPresence.PRESENT }

    /**
     * Asks every configured Blossom server whether it holds [sha256] and
     * records the answer in [mirrorPresence]. Without [force], a check already
     * running is reused, and so is an answer under a day old in which every
     * configured server answered. Port of iOS `BlossomBackupStore.refresh`.
     */
    suspend fun checkMirrorPresence(sha256: String, force: Boolean = false): Map<String, BlobPresence> {
        val hash = sha256.lowercase()
        val mirrors = configStore.config.value.activeBlossomMirrors
        if (mirrors.isEmpty()) return emptyMap()
        val running = synchronized(presenceInFlight) { presenceInFlight[hash] }
        if (running != null) {
            val result = running.await()
            if (!force) return result
        } else if (!force) {
            _mirrorPresence.value[hash]
                ?.takeIf { cached -> presenceStore.isFresh(hash) && reusablePresence(cached, mirrors) }
                ?.let { return it }
        }
        // The check runs in the service scope and records its own answer, so a
        // tile scrolled away mid-check still fills the cache for when it returns.
        val job = synchronized(presenceInFlight) {
            presenceInFlight[hash]?.takeIf { !force } ?: scope.async {
                try {
                    presenceGate.withPermit {
                        mirrors.map { mirror -> async { mirror to checkBlobExists(mirror, hash) } }
                            .awaitAll().toMap()
                    }.also { result ->
                        _mirrorPresence.update { it + (hash to result) }
                        presenceStore.record(hash, result, scope)
                    }
                } finally {
                    synchronized(presenceInFlight) {
                        if (presenceInFlight[hash] === coroutineContext[Job]) presenceInFlight.remove(hash)
                    }
                }
            }.also { presenceInFlight[hash] = it }
        }
        return job.await()
    }

    /**
     * How many configured servers hold [sha256], or null until every one of
     * them has answered once.
     */
    fun backupSummary(sha256: String, presence: Map<String, Map<String, BlobPresence>> = _mirrorPresence.value): BlossomBackupSummary? =
        BlossomBackupSummary.of(presence[sha256.lowercase()], configStore.config.value.activeBlossomMirrors)

    /** Short timeouts: a sleeping server should read as "couldn't reach", not hang the badge. */
    internal val presenceClient by lazy {
        remoteClient.newBuilder()
            .connectTimeout(10, TimeUnit.SECONDS)
            .readTimeout(10, TimeUnit.SECONDS)
            .build()
    }

    // ══════════════════════════════════════════════════════════════════
    // Utilities
    // ══════════════════════════════════════════════════════════════════

    /** Embedded relay's Blossom, or the external one when that mode is on (null if unset). */
    fun localBlossomURL(): String? = configStore.config.value.localBlossomBaseURL

    internal fun computeSHA256(data: ByteArray): String {
        val digest = MessageDigest.getInstance("SHA-256")
        return digest.digest(data).joinToString("") { "%02x".format(it) }
    }

    /** Streaming SHA-256 of a file (does not load the whole file into memory). */
    fun computeSHA256(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(64 * 1024)
            var read: Int
            while (input.read(buffer).also { read = it } != -1) {
                digest.update(buffer, 0, read)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    /** This device's relay and LAN relays: trust follows [LocalTls]. */
    internal fun OkHttpClient.Builder.applyLocalhostTrust(): OkHttpClient.Builder {
        return with(LocalTls) { localTrust() }
    }

    sealed class UploadSource {
        data class Data(val data: ByteArray) : UploadSource() {
            val byteCount: Int get() = data.size
        }
        data class FileSource(val file: File) : UploadSource() {
            val byteCount: Long get() = file.length()
        }
    }
}

/** The `pubkey` of a NIP-11 relay info document, or "" for anything else. */
internal fun relayInfoPubkey(body: String): String = try {
    (Json.parseToJsonElement(body) as? JsonObject)?.get("pubkey")?.let { (it as? JsonPrimitive)?.contentOrNull }.orEmpty()
} catch (_: Exception) {
    ""
}
