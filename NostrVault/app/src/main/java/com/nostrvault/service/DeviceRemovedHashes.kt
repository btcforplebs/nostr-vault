package com.nostrvault.service

import android.content.Context
import android.util.Log
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.io.File
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Files the owner took off this device with "Delete from this device", per
 * account (hex pubkey), so the passes that copy what servers hold back into
 * the vault (Auto-Mirror, note media, import after Moving in) leave them on
 * the servers. Only Save to Vault takes a hash off ([allow]).
 *
 * In the relay data folder, not cache: a cleared cache must not pull 50 GB
 * back down. The engine reads the same `removed_here.json` (haven-go
 * copyv2_removed_here.go), so the copy v2 catch-up from a Mac skips these
 * too; keep the shape `{"byAccount":{"<hex>":["<sha256>",…]}}` in step.
 * [folderOf] gives the folder each time (it follows the relay data folder);
 * null keeps the list in memory (tests).
 */
@Singleton
class DeviceRemovedHashes(private val folderOf: () -> File?) {
    constructor(dir: File?) : this(folderOf = { dir })

    @Inject constructor(@ApplicationContext context: Context, configStore: com.nostrvault.data.local.ConfigStore) : this({
        configStore.config.value.relayDataDir?.let(::File) ?: File(context.filesDir, "relay_data")
    })

    @Serializable
    internal data class Disk(val byAccount: Map<String, List<String>> = emptyMap())

    private companion object {
        const val FILE_NAME = "removed_here.json"
        const val TAG = "DeviceRemovedHashes"
        val json = Json { ignoreUnknownKeys = true }
    }

    private val lock = Any()
    private var byAccount: MutableMap<String, LinkedHashSet<String>>? = null
    private var loadedFrom: File? = null

    /** Whether [sha256] was removed here under [accountHex]. */
    fun isRemoved(accountHex: String, sha256: String): Boolean = synchronized(lock) {
        loaded()[accountHex.lowercase()]?.contains(sha256.lowercase()) == true
    }

    /** Whether [sha256] was removed here under any account (the vault folder is shared). */
    fun isRemovedAnyAccount(sha256: String): Boolean = synchronized(lock) {
        val hash = sha256.lowercase()
        loaded().values.any { hash in it }
    }

    /** Every hash removed here under [accountHex]. */
    fun removed(accountHex: String): Set<String> = synchronized(lock) {
        loaded()[accountHex.lowercase()]?.toSet().orEmpty()
    }

    /**
     * Records [sha256] for [accountHex], written before the file is deleted:
     * if the save fails, false, and the caller keeps the file.
     */
    fun markRemoved(accountHex: String, sha256: String): Boolean = synchronized(lock) {
        val key = accountHex.lowercase()
        val hash = sha256.lowercase()
        if (key.isEmpty() || !AutoMirrorRules.isHash(hash)) return false
        val map = loaded()
        if (map[key]?.contains(hash) == true) return true
        map.getOrPut(key) { LinkedHashSet() }.add(hash)
        if (save(map)) return true
        // Not on disk: undo, so memory never claims more than the file does.
        map[key]?.remove(hash)
        if (map[key]?.isEmpty() == true) map.remove(key)
        false
    }

    /** Save to Vault: the owner wants it here again, under every account. */
    fun allow(sha256: String) {
        synchronized(lock) {
            val hash = sha256.lowercase()
            val map = loaded()
            // Every account's entry, not the first that had it.
            val hadIt = map.values.map { it.remove(hash) }.any { it }
            if (!hadIt) return
            map.entries.removeAll { it.value.isEmpty() }
            save(map)
        }
    }

    private fun loaded(): MutableMap<String, LinkedHashSet<String>> {
        val folder = folderOf()
        byAccount?.takeIf { folder == loadedFrom }?.let { return it }
        loadedFrom = folder
        val disk = runCatching {
            folder?.let { File(it, FILE_NAME) }?.takeIf { it.exists() }?.readText()?.let { json.decodeFromString<Disk>(it) }
        }.onFailure { Log.w(TAG, "Unreadable $FILE_NAME: ${it.message}") }.getOrNull() ?: Disk()
        return disk.byAccount.mapValuesTo(mutableMapOf()) { LinkedHashSet(it.value) }.also { byAccount = it }
    }

    private fun save(map: Map<String, Set<String>>): Boolean {
        val d = folderOf() ?: return true
        return runCatching {
            d.mkdirs()
            val target = File(d, FILE_NAME)
            val tmp = File(d, "$FILE_NAME.tmp")
            tmp.writeText(json.encodeToString(Disk.serializer(), Disk(map.mapValues { it.value.toList() })))
            if (!tmp.renameTo(target)) error("rename failed")
        }.onFailure { Log.w(TAG, "Couldn't save $FILE_NAME: ${it.message}") }.isSuccess
    }
}
