package com.nostrvault.ui.screens

import android.os.FileObserver
import java.io.File

/**
 * The Media tab's live list: a file that lands in this phone's vault shows at
 * once, the way a new note shows in the feed, with no pull to refresh (Logen
 * 2026-11-11). Every way in ends in the vault folder: a feed Mirror,
 * Auto-Mirror, Import media, another of the owner's devices over the mesh, an
 * upload from another app. The relay writes `<sha>.<random>.tmp` and renames
 * it to `<sha>` once the bytes hash right (haven-go/blob_write.go), so the tab
 * watches the folder instead of each sender. A delete there takes the tile
 * away. iOS twin: Ted's MediaGalleryView change.
 */
internal object MediaLiveRules {
    sealed class Change {
        data class Landed(val sha256: String) : Change()
        data class Removed(val sha256: String) : Change()
    }

    /** Names in the vault folder that are never a stored blob: a part-written file, a set-aside bad one. */
    private val notBlobs = setOf("tmp", "corrupt")

    /** The blob a vault-folder name holds (bare hash or `<hash>.<ext>`), or null. */
    fun blobHash(name: String?): String? {
        if (name.isNullOrEmpty()) return null
        val dot = name.lastIndexOf('.')
        val base = if (dot < 0) name else name.substring(0, dot)
        if (dot >= 0 && name.substring(dot + 1) in notBlobs) return null
        if (base.length != 64 || !base.all { it in "0123456789abcdef" }) return null
        return base
    }

    /** What a folder event means for the list: the relay's rename into place or a direct write, or a delete. */
    fun change(event: Int, path: String?): Change? {
        val hash = blobHash(path) ?: return null
        val mask = event and FileObserver.ALL_EVENTS
        return when {
            (mask and (FileObserver.MOVED_TO or FileObserver.CLOSE_WRITE)) != 0 -> Change.Landed(hash)
            (mask and (FileObserver.DELETE or FileObserver.MOVED_FROM)) != 0 -> Change.Removed(hash)
            else -> null
        }
    }

    /** The types the Media tab lists (MediaGalleryViewModel's full load keeps the same ones). */
    fun shown(item: BlossomMediaItem): Boolean = item.isImage || item.isVideo || item.isAudio || item.mimeType == null

    /**
     * [current] with this phone's copy [item] in it, newest first. A tile that
     * was only on a server becomes this copy and keeps what the server said
     * (upload time, type, the note that posted it).
     */
    fun landed(current: List<BlossomMediaItem>, item: BlossomMediaItem): List<BlossomMediaItem> {
        val existing = current.firstOrNull { it.sha256 == item.sha256 }
        val merged = if (existing == null) item else item.copy(
            uploaded = existing.uploaded ?: item.uploaded,
            mimeType = existing.mimeType ?: item.mimeType,
            noteId = existing.noteId ?: item.noteId,
        )
        if (!shown(merged)) return current
        return (current.filter { it.sha256 != item.sha256 } + merged).sortedByDescending { it.sortTime }
    }

    /**
     * A tile from the owner's live file notes (`/files`, FileNotes.kt): another device uploaded it. Null with no
     * server link: a vault-only note has no address this tab can draw yet, and the server listing finds it once a
     * server has it.
     */
    fun noteItem(tile: com.nostrvault.fips.FileNoteTile): BlossomMediaItem? {
        val url = tile.urls.firstOrNull() ?: return null
        return BlossomMediaItem(
            sha256 = tile.sha256,
            displayUrl = url,
            localFile = null,
            mimeType = tile.mime,
            size = tile.size,
            uploaded = tile.createdAt,
            lastModified = null,
            isLocal = false,
        )
    }

    /** [current] with a note's tile in it, newest first; a hash already listed (here or on a server) keeps its tile. */
    fun noteLanded(current: List<BlossomMediaItem>, item: BlossomMediaItem): List<BlossomMediaItem> {
        if (current.any { it.sha256 == item.sha256 } || !shown(item)) return current
        return (current + item).sortedByDescending { it.sortTime }
    }

    /**
     * [current] after a `/files` kind 5 left no live note for [sha256]: its remote tile goes. This phone's own copy
     * stays: the folder watch owns that one.
     */
    fun noteRemoved(current: List<BlossomMediaItem>, sha256: String): List<BlossomMediaItem> =
        if (current.none { it.sha256 == sha256 && !it.isLocal }) current
        else current.filterNot { it.sha256 == sha256 && !it.isLocal }

    /** [current] without this phone's copy of [sha256]. A server-only tile of it is not this phone's to drop. */
    fun removed(current: List<BlossomMediaItem>, sha256: String): List<BlossomMediaItem> =
        if (current.none { it.sha256 == sha256 && it.isLocal }) current
        else current.filterNot { it.sha256 == sha256 && it.isLocal }
}

/**
 * Watches one vault folder and reports [MediaLiveRules.Change]s on the
 * observer's own thread. Kept in a field: a FileObserver stops when it is
 * collected.
 */
@Suppress("DEPRECATION") // FileObserver(String, Int) needs no API 29; minSdk is 26.
internal class VaultFolderWatch(val dir: File, private val onChange: (MediaLiveRules.Change) -> Unit) {
    private val observer = object : FileObserver(
        dir.absolutePath,
        CLOSE_WRITE or MOVED_TO or DELETE or MOVED_FROM,
    ) {
        override fun onEvent(event: Int, path: String?) {
            MediaLiveRules.change(event, path)?.let(onChange)
        }
    }

    fun start() = observer.startWatching()
    fun stop() = observer.stopWatching()
}
