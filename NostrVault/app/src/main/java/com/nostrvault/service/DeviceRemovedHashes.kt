package com.nostrvault.service

import android.util.Log
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.io.File

/**
 * Files the owner removed from THIS device with "Delete from this device" (D3), by sha256. Every pass that fills
 * the vault on its own (Auto-Mirror from servers, the note-media pass, the import after moving in) skips them, and
 * so does the engine (haven-go removed_here.go: the mesh copy catch-up and the mesh door). Only an explicit Save to
 * Vault takes a file off the list.
 *
 * One list per vault owner, at `removed_here/<owner>.json` beside the vault folder, `{"removed":{"<sha>":<secs>}}`:
 * the same file and shape as Apple `DeviceRemovedHashes` and the engine read.
 */
@Serializable
data class DeviceRemovedHashes(val removed: Map<String, Double> = emptyMap()) {
    fun contains(sha256: String): Boolean = removed.containsKey(sha256.lowercase())

    fun adding(sha256: String, nowSeconds: Double): DeviceRemovedHashes {
        val key = sha256.lowercase()
        return if (MediaSizeCache.isHash(key)) copy(removed = removed + (key to nowSeconds)) else this
    }

    fun removing(sha256: String): DeviceRemovedHashes = copy(removed = removed - sha256.lowercase())

    /** [hashes] without the removed ones, order kept. */
    fun keeping(hashes: List<String>): List<String> = if (removed.isEmpty()) hashes else hashes.filterNot { contains(it) }

    companion object {
        /** `removed_here/<owner>.json` in the folder holding [vault] (the Blossom folder, BLOSSOM_PATH). */
        fun fileFor(owner: String, vault: File): File? {
            val key = owner.lowercase()
            if (!MediaSizeCache.isHash(key)) return null
            val parent = vault.absoluteFile.normalize().parentFile ?: return null
            return File(File(parent, "removed_here"), "$key.json")
        }
    }
}

/** Reads and writes the lists, from any thread. */
object DeviceRemovedStore {
    private val json = Json { ignoreUnknownKeys = true }
    private val lists = HashMap<String, DeviceRemovedHashes>()

    fun list(owner: String, vault: File): DeviceRemovedHashes {
        val file = DeviceRemovedHashes.fileFor(owner, vault) ?: return DeviceRemovedHashes()
        return synchronized(this) { loadLocked(file) }
    }

    /** Puts [sha256] on the list and writes it; false when it could not be written (then nothing may be deleted). */
    fun add(sha256: String, owner: String, vault: File): Boolean {
        val file = DeviceRemovedHashes.fileFor(owner, vault) ?: return false
        return synchronized(this) {
            val next = loadLocked(file).adding(sha256, System.currentTimeMillis() / 1000.0)
            if (!next.contains(sha256) || !saveLocked(next, file)) return@synchronized false
            lists[file.path] = next
            true
        }
    }

    /** Takes [sha256] off the list (an explicit Save to Vault, or a delete that did not happen). */
    fun remove(sha256: String, owner: String, vault: File) {
        val file = DeviceRemovedHashes.fileFor(owner, vault) ?: return
        synchronized(this) {
            val have = loadLocked(file)
            if (!have.contains(sha256)) return
            val next = have.removing(sha256)
            if (saveLocked(next, file)) lists[file.path] = next
        }
    }

    /** For tests: forget what was read. */
    internal fun reset() = synchronized(this) { lists.clear() }

    private fun loadLocked(file: File): DeviceRemovedHashes = lists.getOrPut(file.path) {
        runCatching { file.takeIf { it.exists() }?.readText()?.let { json.decodeFromString<DeviceRemovedHashes>(it) } }
            .onFailure { Log.w("DeviceRemoved", "Unreadable ${file.name}: ${it.message}") }
            .getOrNull() ?: DeviceRemovedHashes()
    }

    private fun saveLocked(list: DeviceRemovedHashes, file: File): Boolean = runCatching {
        file.parentFile?.mkdirs()
        val tmp = File(file.parentFile, "${file.name}.tmp")
        tmp.writeText(json.encodeToString(DeviceRemovedHashes.serializer(), list))
        check(tmp.renameTo(file)) { "rename failed" }
    }.onFailure { Log.w("DeviceRemoved", "Could not save ${file.name}: ${it.message}") }.isSuccess
}
