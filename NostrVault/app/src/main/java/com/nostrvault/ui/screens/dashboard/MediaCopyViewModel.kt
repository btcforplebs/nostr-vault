package com.nostrvault.ui.screens.dashboard

import android.util.Log
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.nostrvault.service.BlobCopyOutcome
import com.nostrvault.service.BlobPresence
import com.nostrvault.service.BlossomService
import com.nostrvault.service.copyStoredBlob
import com.nostrvault.service.localBlobFile
import com.nostrvault.service.makeBatchUploadAuth
import com.nostrvault.service.signerProblem
import com.nostrvault.service.sniffContentType
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext
import java.io.File
import java.net.URI
import javax.inject.Inject

/** One file on this phone that a server is missing, and what the last copy did with it. */
data class MediaCopyFile(
    val hash: String,
    val file: File,
    val kind: Kind,
    val size: Long,
    val addedMillis: Long,
    /** The servers that do not have it yet. */
    val servers: List<String>,
    val status: Status = Status.Waiting,
) {
    data class Failure(val server: String, val reason: String)

    sealed interface Status {
        data object Waiting : Status
        data object Copying : Status
        data object Copied : Status
        data class Failed(val failures: List<Failure>) : Status
    }

    enum class Kind(val label: String) {
        PHOTO("Photo"), GIF("GIF"), VIDEO("Video"), AUDIO("Audio"), FILE("File");

        companion object {
            fun of(mime: String): Kind = when {
                mime == "image/gif" -> GIF
                mime.startsWith("image/") -> PHOTO
                mime.startsWith("video/") -> VIDEO
                mime.startsWith("audio/") -> AUDIO
                else -> FILE
            }
        }
    }

    val isFailed: Boolean get() = status is Status.Failed
}

/** A Blossom server and what the check found about it. */
data class MediaServer(val url: String, val host: String, val health: Health = Health.UNKNOWN) {
    enum class Health {
        UNKNOWN,
        /** Holds at least one of your files: a real Blossom server. */
        WORKING,
        /** Answered, but holds none of your files to prove it. */
        ANSWERS,
        OFFLINE,
    }
}

/**
 * Media servers › Copy to servers, self-contained so the dashboard only has
 * to place [MirrorStatusSection]. Port of iOS `MediaServersModel`: measures
 * which files on this phone a server does not have, then sends them with a
 * visible state per file. The old push ran one file at a time, signed each
 * one separately, and could wait half an hour on a single upload without a
 * word on screen.
 */
@HiltViewModel
class MediaCopyViewModel @Inject constructor(
    private val blossomService: BlossomService,
) : ViewModel() {

    data class UiState(
        val servers: List<MediaServer> = emptyList(),
        val filesStored: Int? = null,
        /** Files some server says it does not have; null until checked. */
        val waiting: Int? = null,
        val scan: Pair<Int, Int>? = null,
        val copy: Pair<Int, Int>? = null,
        val signing: Boolean = false,
        val files: List<MediaCopyFile> = emptyList(),
        val note: String? = null,
    ) {
        val isScanning get() = scan != null
        val isCopying get() = copy != null
        val hasFailures get() = files.any { it.isFailed }
    }

    private val _state = MutableStateFlow(UiState())
    val state: StateFlow<UiState> = _state.asStateFlow()

    private var localFiles: Map<String, File> = emptyMap()
    private var loadJob: Job? = null
    private var copyJob: Job? = null

    init {
        load()
    }

    fun host(server: String): String = runCatching { URI(server).host }.getOrNull() ?: server

    /** Lists the vault folder, then asks each server about each file, four files at a time. */
    fun load() {
        if (_state.value.isCopying) return
        loadJob?.cancel()
        loadJob = viewModelScope.launch {
            val mirrors = blossomService.configStore.config.value.activeBlossomMirrors
            localFiles = withContext(Dispatchers.IO) { listVault() }
            _state.update { s ->
                s.copy(
                    servers = mirrors.map { url -> s.servers.firstOrNull { it.url == url } ?: MediaServer(url, host(url)) },
                    filesStored = localFiles.size,
                )
            }
            if (mirrors.isEmpty()) return@launch
            val hashes = localFiles.keys.toList()
            var done = 0
            _state.update { it.copy(scan = 0 to hashes.size) }
            val gate = Semaphore(4)
            coroutineScope {
                hashes.map { hash ->
                    async {
                        gate.withPermit { blossomService.checkMirrorPresence(hash) }
                        synchronized(this@MediaCopyViewModel) { done += 1 }
                        _state.update { it.copy(scan = done to hashes.size) }
                    }
                }.awaitAll()
            }
            rebuild(mirrors)
        }
    }

    private fun listVault(): Map<String, File> {
        val config = blossomService.configStore.config.value
        val dir = config.relayDataDir?.let { File(it, config.blossomPath) } ?: return emptyMap()
        return dir.listFiles { f -> f.isFile }.orEmpty().mapNotNull { f ->
            val hash = f.nameWithoutExtension.lowercase()
            if (hash.length == 64 && hash.all { it in '0'..'9' || it in 'a'..'f' }) hash to f else null
        }.toMap()
    }

    /** The list under Copy: every file a server is missing. A failed file keeps its reasons. */
    private suspend fun rebuild(mirrors: List<String>) {
        val presence = blossomService.mirrorPresence.value
        val previous = _state.value.files.associateBy { it.hash }
        val files = withContext(Dispatchers.IO) {
            localFiles.toSortedMap().mapNotNull { (hash, file) ->
                val absentOn = mirrors.filter { presence[hash]?.get(it) == BlobPresence.ABSENT }
                if (absentOn.isEmpty()) return@mapNotNull null
                val old = previous[hash]
                MediaCopyFile(
                    hash = hash,
                    file = file,
                    kind = old?.kind ?: MediaCopyFile.Kind.of(sniffContentType(file)),
                    size = file.length(),
                    addedMillis = file.lastModified(),
                    servers = absentOn,
                    status = old?.status?.takeIf { it is MediaCopyFile.Status.Failed } ?: MediaCopyFile.Status.Waiting,
                )
            }
        }
        val servers = _state.value.servers.map { server ->
            val answers = localFiles.keys.mapNotNull { presence[it]?.get(server.url) }
            server.copy(
                health = when {
                    answers.any { it == BlobPresence.PRESENT } -> MediaServer.Health.WORKING
                    answers.isNotEmpty() && answers.all { it == BlobPresence.UNREACHABLE } -> MediaServer.Health.OFFLINE
                    answers.isNotEmpty() -> MediaServer.Health.ANSWERS
                    else -> MediaServer.Health.UNKNOWN
                },
            )
        }
        _state.update { it.copy(files = files, servers = servers, waiting = files.size, scan = null) }
    }

    fun startCopy() {
        if (_state.value.isCopying || _state.value.isScanning) return
        copyJob = viewModelScope.launch { copyToServers() }
    }

    /** Stops after the files already on their way; the rest stay waiting. */
    fun stopCopy() {
        copyJob?.cancel()
    }

    private suspend fun copyToServers() {
        val work = _state.value.files.filter { it.status != MediaCopyFile.Status.Copied }
        if (work.isEmpty()) return
        val ids = work.map { it.hash }.toSet()
        _state.update { s ->
            s.copy(
                note = null,
                copy = 0 to work.size,
                files = s.files.map { if (it.hash in ids) it.copy(status = MediaCopyFile.Status.Waiting) else it },
            )
        }
        Log.i(TAG, "copy to servers: ${work.size} file(s)")
        var done = 0
        var stopped = false
        try {
            // One signature per batch, not per file: with a remote signer every
            // signature is a round trip, and maybe a prompt to approve.
            for (batch in work.chunked(FILES_PER_SIGNATURE)) {
                _state.update { it.copy(signing = true) }
                val auth = blossomService.makeBatchUploadAuth(batch.map { it.hash })
                _state.update { it.copy(signing = false) }
                if (auth == null) {
                    // The next batch would ask the same signer: stop here and say why.
                    val reason = blossomService.signerProblem()
                    val rest = work.drop(work.indexOf(batch.first())).map { it.hash }.toSet()
                    update(rest) { f -> f.copy(status = MediaCopyFile.Status.Failed(f.servers.map { MediaCopyFile.Failure(it, reason) })) }
                    break
                }
                val gate = Semaphore(2)
                coroutineScope {
                    batch.map { job ->
                        async {
                            gate.withPermit {
                                if (!isActive) return@withPermit
                                update(setOf(job.hash)) { it.copy(status = MediaCopyFile.Status.Copying) }
                                val outcomes = blossomService.copyStoredBlob(job.hash, job.file, job.servers, auth)
                                record(job.hash, outcomes)
                                synchronized(this@MediaCopyViewModel) { done += 1 }
                                _state.update { it.copy(copy = done to work.size) }
                            }
                        }
                    }.awaitAll()
                }
            }
        } catch (e: kotlinx.coroutines.CancellationException) {
            stopped = true
        } finally {
            finish(work.size, ids, stopped)
        }
    }

    private fun finish(total: Int, ids: Set<String>, stopped: Boolean) {
        val files = _state.value.files
        val copied = files.count { it.hash in ids && it.status == MediaCopyFile.Status.Copied }
        val failed = files.count { it.isFailed }
        Log.i(TAG, "copy to servers: $copied copied, $failed failed${if (stopped) ", stopped" else ""} of $total")
        val left = files
            .filter { it.status != MediaCopyFile.Status.Copied }
            .map { if (it.status == MediaCopyFile.Status.Copying) it.copy(status = MediaCopyFile.Status.Waiting) else it }
        _state.update {
            it.copy(
                copy = null,
                signing = false,
                files = left,
                waiting = left.size,
                note = when {
                    stopped -> "Stopped. $copied copied; the rest are still waiting."
                    failed == 1 -> "1 file couldn't be copied. The reason is under it in the list. Fix that, then tap Retry."
                    failed > 1 -> "$failed files couldn't be copied. The reason is under each one. Fix that, then tap Retry."
                    else -> null
                },
            )
        }
    }

    private fun record(hash: String, outcomes: Map<String, BlobCopyOutcome>) {
        val copiedTo = outcomes.filterValues { it == BlobCopyOutcome.Copied }.keys
        if (copiedTo.isNotEmpty()) {
            viewModelScope.launch { blossomService.checkMirrorPresence(hash, force = true) }
        }
        val failures = outcomes.mapNotNull { (server, outcome) ->
            (outcome as? BlobCopyOutcome.Failed)?.let { MediaCopyFile.Failure(server, it.reason) }
        }.sortedBy { it.server }
        update(setOf(hash)) { f ->
            f.copy(
                servers = f.servers - copiedTo,
                status = if (failures.isEmpty()) MediaCopyFile.Status.Copied else MediaCopyFile.Status.Failed(failures),
            )
        }
    }

    private fun update(ids: Set<String>, change: (MediaCopyFile) -> MediaCopyFile) {
        _state.update { s -> s.copy(files = s.files.map { if (it.hash in ids) change(it) else it }) }
    }

    /** The one-file copy behind the media viewer's mirror sheet. */
    suspend fun copyOne(hash: String): Map<String, BlobCopyOutcome>? {
        val file = withContext(Dispatchers.IO) { blossomService.localBlobFile(hash) } ?: return null
        val presence = blossomService.checkMirrorPresence(hash, force = true)
        val missing = presence.filterValues { it == BlobPresence.ABSENT }.keys.toList()
        if (missing.isEmpty()) return emptyMap()
        val outcomes = blossomService.copyStoredBlob(hash, file, missing)
        blossomService.checkMirrorPresence(hash, force = true)
        return outcomes
    }

    private companion object {
        const val TAG = "MediaCopy"
        const val FILES_PER_SIGNATURE = 25
    }
}
