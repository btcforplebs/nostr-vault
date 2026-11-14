package com.nostrvault.relay

import android.util.Log
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.longOrNull
import java.io.File

/**
 * The Vault's rows straight from the on-device store (Logen 2026-11-14,
 * Android twin of iOS NostrService+VaultDirectRead): the engine runs in this
 * process, so the read asks it directly (haven-go QueryVaultC) instead of
 * over the local relay socket. No port, health check or socket handshake to
 * wait for. Live updates and the Mac relay stay on the socket.
 *
 * The store answers with the socket's read rules for / and /inbox: blocked
 * and brought-over accounts hidden, never private or chat. When it can't
 * answer (engine starting, import, a stop) [query] gives null and the caller
 * reads over the socket as before.
 */
object VaultStoreRead {
    private const val TAG = "VaultStoreRead"

    /** QueryVaultC takes at most this many filters per call. */
    internal const val MAX_FILTERS = 8

    /** Folder and file of the saved Vault screens this read replaced. */
    private const val OLD_SNAPSHOT_FOLDER = "vault-snapshots"
    private const val OLD_SNAPSHOT_FILE = "vault_snapshot.json"

    private val json = Json { ignoreUnknownKeys = true }

    private external fun queryVaultNative(request: ByteArray): ByteArray?

    /**
     * The local outbox's and inbox's events for [filters] (nostr filter JSON
     * objects), newest first, one per id; null when the store can't answer.
     * Blocking: call off the main thread.
     */
    fun query(filters: List<String>): List<JsonObject>? {
        if (!HavenBridge.isLoaded || filters.isEmpty()) return null
        val answers = filters.chunked(MAX_FILTERS).map { chunk ->
            val answer = try {
                queryVaultNative(request(chunk).toByteArray(Charsets.UTF_8))
            } catch (e: UnsatisfiedLinkError) {
                Log.w(TAG, "QueryVaultC unavailable: ${e.message}")
                null
            } ?: return null
            events(answer.toString(Charsets.UTF_8)) ?: return null
        }
        return merge(answers)
    }

    /** One list from each call's answer: one event per id, newest first. */
    internal fun merge(answers: List<List<JsonObject>>): List<JsonObject> {
        val byId = LinkedHashMap<String, JsonObject>()
        for (event in answers.flatten()) {
            val id = (event["id"] as? JsonPrimitive)?.contentOrNull ?: continue
            byId.putIfAbsent(id, event)
        }
        return byId.values.sortedByDescending { (it["created_at"] as? JsonPrimitive)?.longOrNull ?: 0L }
    }

    /** QueryVaultC's request for [filters]. */
    internal fun request(filters: List<String>): String = filters.joinToString(",", "{\"filters\":[", "]}")

    /** The events in QueryVaultC's [answer]; null for an error ("vault read not ready" too) or a bad answer. */
    internal fun events(answer: String): List<JsonObject>? {
        val obj = runCatching { json.parseToJsonElement(answer) as? JsonObject }.getOrNull() ?: return null
        if (obj["error"] != null) return null
        val events = obj["events"] as? JsonArray ?: return null
        return events.mapNotNull { it as? JsonObject }
    }

    /** Deletes the saved Vault screens of earlier builds. Blocking. */
    fun removeOldSavedScreens(appSupportDir: File) {
        runCatching {
            File(appSupportDir, OLD_SNAPSHOT_FOLDER).deleteRecursively()
            File(appSupportDir, OLD_SNAPSHOT_FILE).delete()
        }
    }
}
