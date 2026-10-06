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

    /**
     * The reaction the signed-in account left on a note: its kind-7
     * `content`, and the event that carried it, so removing it can publish a
     * NIP-09 deletion. [eventId] is null while the reaction is being signed,
     * and for likes saved before the id was kept.
     */
    @Serializable
    data class MyReaction(val content: String, val eventId: String? = null)

    /** One kind-7 event seen on a relay. */
    data class ReactionEvent(
        val targetId: String,
        val pubkey: String,
        val eventId: String,
        val content: String,
    )

    @Serializable
    data class InteractionState(
        val likedEventIds: Set<String>,
        val zappedEventIds: Map<String, Int>,
        /** Which emoji each liked note got. Missing in older files; those show the plain heart. */
        val myReactions: Map<String, MyReaction> = emptyMap(),
        /**
         * Reactions this account removed. Relays may keep serving them after
         * the deletion, and seeing one again must not bring the like back or
         * count it.
         */
        val retractedReactionIds: Set<String> = emptySet(),
    )

    /** Tags of the NIP-09 deletion that retracts one of the account's reactions. */
    fun reactionDeletionTags(reactionId: String): List<List<String>> =
        listOf(listOf("e", reactionId), listOf("k", "7"))

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
    fun loadInteractionState(forKey: String, fallbackToLegacy: Boolean = true): InteractionState {
        val file = interactionStateFile(forKey)

        // Try per-account file
        val state = loadFromFile(file) ?: if (fallbackToLegacy) loadFromFile(legacyFile) else null
        return state ?: InteractionState(emptySet(), emptyMap())
    }

    /** An interaction-state file's contents, or null when it isn't one. */
    fun decodeInteractionState(text: String): InteractionState? = try {
        json.decodeFromString<InteractionState>(text)
    } catch (_: Exception) {
        null
    }

    fun encodeInteractionState(state: InteractionState): String = json.encodeToString(state)

    /**
     * Persist interaction state to disk on a background thread.
     */
    suspend fun saveInteractionState(
        state: InteractionState,
        forKey: String,
    ) = withContext(Dispatchers.IO) {
        val file = interactionStateFile(forKey)
        try {
            dataDir.mkdirs()
            file.writeText(encodeInteractionState(state))
        } catch (_: Exception) { }
    }

    // ---- Self-reaction detection ----

    /**
     * The owner's own reactions in a batch, keyed by the note they react to.
     * Reactions the owner has since removed are skipped.
     */
    fun detectSelfReactions(
        reactions: List<ReactionEvent>,
        ownerHex: String,
        retracted: Set<String>,
    ): Map<String, MyReaction> {
        if (ownerHex.isEmpty()) return emptyMap()
        val mine = LinkedHashMap<String, MyReaction>()
        for (rx in reactions) {
            if (rx.pubkey == ownerHex && rx.eventId !in retracted) {
                mine[rx.targetId] = MyReaction(rx.content, rx.eventId)
            }
        }
        return mine
    }

    // ---- Engagement count merging ----

    /**
     * Merge a batch of reaction events and repost targets into the running
     * per-note stats dictionary. Returns the updated dictionary.
     */
    fun mergeEngagementCounts(
        reactions: List<ReactionEvent>,
        repostTargets: List<String>,
        currentStats: Map<String, NoteStats>,
        retracted: Set<String> = emptySet(),
    ): Map<String, NoteStats> {
        val updated = currentStats.toMutableMap()

        for (rx in reactions) {
            if (rx.eventId in retracted) continue
            val stats = updated[rx.targetId] ?: NoteStats()
            updated[rx.targetId] = stats.copy(reactionCount = stats.reactionCount + 1)
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
