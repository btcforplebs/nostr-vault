package com.nostrvault.data.local

import android.content.Context
import com.nostrvault.data.model.NoteStats
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.File

/**
 * Port of EngagementTracker.swift -- per-account like/zap state persistence
 * and engagement count merging. Pure logic, no UI dependencies.
 */
object EngagementTracker {

    private val json = Json { ignoreUnknownKeys = true }
    private lateinit var dataDir: File

    fun init(context: Context) {
        dataDir = File(context.filesDir, "nostrvault_data")
        dataDir.mkdirs()
    }

    // ---- Persistence model ----

    @Serializable
    data class InteractionState(
        val likedEventIds: Set<String>,
        val zappedEventIds: Map<String, Int>,
    )

    // ---- File paths ----

    private fun interactionStateFile(key: String): File {
        val safeKey = key.ifEmpty { "owner" }.replace("/", "_")
        return File(dataDir, "interaction_state_$safeKey.json")
    }

    private val legacyFile get() = File(dataDir, "interaction_state.json")

    // ---- Load / Save ----

    /**
     * Load interaction state from disk for the given account key.
     * Falls back to the legacy global file when no per-account file exists.
     */
    fun loadInteractionState(forKey: String, fallbackToLegacy: Boolean = true): Pair<Set<String>, Map<String, Int>> {
        val file = interactionStateFile(forKey)

        // Try per-account file
        val state = loadFromFile(file) ?: if (fallbackToLegacy) loadFromFile(legacyFile) else null
        return if (state != null) {
            state.likedEventIds to state.zappedEventIds
        } else {
            emptySet<String>() to emptyMap()
        }
    }

    /**
     * Persist interaction state to disk on a background thread.
     */
    suspend fun saveInteractionState(
        likedEventIds: Set<String>,
        zappedEventIds: Map<String, Int>,
        forKey: String,
    ) = withContext(Dispatchers.IO) {
        val state = InteractionState(likedEventIds, zappedEventIds)
        val file = interactionStateFile(forKey)
        try {
            dataDir.mkdirs()
            file.writeText(json.encodeToString(state))
        } catch (_: Exception) { }
    }

    // ---- Self-like detection ----

    /**
     * Identify reactions authored by the owner in a batch of reaction events.
     * Returns the note IDs that the owner has liked.
     */
    fun detectSelfLikes(
        reactions: List<Pair<String, String>>, // (targetId, pubkey)
        ownerHex: String,
    ): List<String> {
        if (ownerHex.isEmpty()) return emptyList()
        return reactions.filter { it.second == ownerHex }.map { it.first }
    }

    // ---- Engagement count merging ----

    /**
     * Merge a batch of reaction events and repost targets into the running
     * per-note stats dictionary. Returns the updated dictionary.
     */
    fun mergeEngagementCounts(
        reactions: List<Pair<String, String>>, // (targetId, pubkey)
        repostTargets: List<String>,
        currentStats: Map<String, NoteStats>,
    ): Map<String, NoteStats> {
        val updated = currentStats.toMutableMap()

        for ((targetId, _) in reactions) {
            val stats = updated.getOrPut(targetId) { NoteStats() }
            stats.reactionCount++
            updated[targetId] = stats
        }
        for (targetId in repostTargets) {
            val stats = updated.getOrPut(targetId) { NoteStats() }
            stats.repostCount++
            updated[targetId] = stats
        }

        return updated
    }

    // ---- Private ----

    private fun loadFromFile(file: File): InteractionState? = try {
        if (file.exists()) json.decodeFromString(file.readText()) else null
    } catch (_: Exception) {
        null
    }
}
