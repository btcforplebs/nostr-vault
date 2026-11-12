package com.nostrvault.service

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

// Moved out of BlossomService.kt unchanged (it was at the 1,000-line limit);
// BlossomService.mirrorFromNoteMedia calls it.

/**
 * Copies in the media your own notes link to on outside servers: your
 * notes are read from this device's relay, page by page, and each link
 * not already here is downloaded and stored, four at a time, under one
 * signed upload authorisation. iOS `BlossomService.mirrorFromNoteMedia`.
 * @return how many files were saved.
 */
internal suspend fun BlossomService.copyNoteMediaIn(
    onProgress: ((Float) -> Unit)?,
    onLogMessage: ((String) -> Unit)?,
    limits: RunLimits,
): Int = withContext(Dispatchers.IO) {
    BlobStream.sweepLeftovers()
    val owner = nostrService.ownerHexPubkey
    val relay = configStore.config.value.nostrURL
    if (owner.isEmpty() || relay == null) return@withContext 0

    val notes = NoteMediaScan.collect(owner) { filter ->
        nostrService.queryRawEvents(listOf(filter), listOf(relay), timeoutMs = 8_000L)
    }
    val links = notes.flatMap { note ->
        nostrService.extractMediaURLs(note.content, note.pubkey, note.tags, note.createdAt).map { it.url to note.createdAt }
    }
    val urls = links.map { it.first }
    // Each copy carries its note's created_at; a link in several notes, the newest (iOS).
    val noteDates = CopiedInDate.newestByKey(links, { it.first }, { it.second })
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
                    val startedAt = System.currentTimeMillis()
                    val sha = mirrorUrlToLocal(url, ownVault = auth) { onLogMessage?.invoke("Skipped $url: $it") }
                    if (sha != null) {
                        stampCopiedIn(sha, noteDates[url], startedAt)
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
