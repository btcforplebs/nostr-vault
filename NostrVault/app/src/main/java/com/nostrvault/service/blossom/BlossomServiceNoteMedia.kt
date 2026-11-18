package com.nostrvault.service

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

// Moved out of BlossomService.kt unchanged (it was at the 1,000-line limit);
// BlossomService.mirrorFromNoteMedia calls it.

/**
 * Copies in the media your own notes link to on outside servers: your
 * notes are read from this device's relay, page by page (only the links
 * still to copy are kept), and each link not already here is downloaded and stored, four at a time, under one
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

    // Page by page: each page's links are checked as they come, only the
    // ones to copy are kept, and the page is dropped. Pages run newest
    // first, so a link's first sighting is its newest note, the date it
    // carries (iOS). Once the run's downloads are spoken for, the rest of an
    // old history is not read; the next run picks up from there.
    val room = (limits.cap.toLong() - limits.started).coerceAtLeast(0)
    if (room == 0L) {
        onLogMessage?.invoke("This run's downloads are used up; note media comes next run")
        return@withContext 0
    }
    val picker = NoteMediaScan.Picker { mediaCacheService.isInLocalBlossom(it) }
    val noteDates = LinkedHashMap<String, Long>() // url to copy -> its newest note's created_at
    var linkCount = 0
    val noteCount = NoteMediaScan.forEachPage(owner, { filter ->
        nostrService.queryRawEvents(listOf(filter), listOf(relay), timeoutMs = 8_000L)
    }) { page ->
        // A link's hash, known before any download: its name, a note's imeta x, or an earlier run.
        val imeta = HashMap<String, String>()
        page.forEach { imeta.putAll(AutoMirrorRules.imetaHashes(it.tags)) }
        for (note in page) {
            for (media in nostrService.extractMediaURLs(note.content, note.pubkey, note.tags, note.createdAt)) {
                linkCount++
                val url = media.url
                val had = noteDates[url]
                if (had != null) {
                    if (note.createdAt > had) noteDates[url] = note.createdAt
                } else if (picker.offer(url) { imeta[it] ?: autoMirrorState.hashFor(it) }) {
                    noteDates[url] = note.createdAt
                }
            }
        }
        noteDates.size < room
    }
    val toImport = noteDates.keys.toList()
    onLogMessage?.invoke("Found $linkCount media link(s) in $noteCount note(s)")
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
