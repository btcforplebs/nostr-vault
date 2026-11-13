package com.nostrvault.data.local

import com.nostrvault.data.model.VaultSnapshotRules
import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.io.File

/**
 * The Vault tab's saved screens, one per account and list (Android twin of
 * iOS NostrService+VaultSnapshot, #2034): the newest events, written when the
 * app goes to the background and before an account switch clears memory,
 * read back at launch and right after a switch so the last screen shows at
 * once and the refresh only tops it up.
 *
 * Files live in `<app support>/vault-snapshots/<list>-<hex>.json`.
 */
class VaultSnapshotStore(appSupportDir: File) {
    private val dir = File(appSupportDir, FOLDER)

    @Serializable
    private data class Saved<T>(val savedAt: Long, val events: List<T>)

    /** Saves the newest [VaultSnapshotRules.KEEP] of [items] as [account]'s [list]. Empty saves nothing. */
    fun <T> write(
        list: String,
        account: String,
        items: Collection<T>,
        serializer: KSerializer<T>,
        now: Long = System.currentTimeMillis(),
        createdAt: (T) -> Long,
    ) {
        val name = VaultSnapshotRules.fileName(list, account) ?: return
        if (items.isEmpty()) return
        dir.mkdirs()
        val saved = Saved(now, VaultSnapshotRules.newest(items, createdAt = createdAt))
        val tmp = File(dir, "$name.tmp")
        tmp.writeText(json.encodeToString(Saved.serializer(serializer), saved))
        if (!tmp.renameTo(File(dir, name))) tmp.delete()
    }

    /** [account]'s saved [list], or null when there is none or it is older than [maxAgeMs]. */
    fun <T> read(
        list: String,
        account: String,
        serializer: KSerializer<T>,
        maxAgeMs: Long,
        now: Long = System.currentTimeMillis(),
    ): List<T>? {
        val name = VaultSnapshotRules.fileName(list, account) ?: return null
        val file = File(dir, name)
        if (!file.exists()) return null
        val saved = runCatching { json.decodeFromString(Saved.serializer(serializer), file.readText()) }
            .getOrNull() ?: return null.also { file.delete() }
        if (now - saved.savedAt > maxAgeMs) {
            file.delete()
            return null
        }
        return saved.events
    }

    companion object {
        const val FOLDER = "vault-snapshots"
        /** The Notes / Likes / Zaps lists' events (DashboardViewModel). */
        const val NOTES = "vault-notes"
        /** The "Vault" list's events (VaultActivityViewModel). */
        const val ACTIVITY = "vault-activity"

        private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    }
}
