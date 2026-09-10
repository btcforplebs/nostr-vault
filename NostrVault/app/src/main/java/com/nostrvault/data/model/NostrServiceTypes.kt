package com.nostrvault.data.model

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import java.util.Date
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/**
 * Port of NostrServiceTypes.swift -- types for Nostr service layer.
 */

// ---------------------------------------------------------------------------
// Search results
// ---------------------------------------------------------------------------

data class GlobalSearchResults(
    val profiles: List<FeedProfile> = emptyList(),
    val notes: List<FeedNote> = emptyList(),
)

// ---------------------------------------------------------------------------
// Profile update signal (for efficient UI re-renders)
// ---------------------------------------------------------------------------

data class ProfileUpdateSignal(
    val generation: Int = 0,
    val pubkeys: Set<String> = emptySet(),
)

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/** Default public NIP-50 search-capable relays. Used as the fallback when the
 *  user has not configured their own search relays (config.searchRelays). */
val NIP50_SEARCH_RELAYS = listOf(
    "wss://relay.nostr.band",
    "wss://relay.noswhere.com",
    "wss://search.nos.today",
)

// ---------------------------------------------------------------------------
// Global search collector (thread-safe)
// ---------------------------------------------------------------------------

/**
 * Thread-safe accumulator for NIP-50 global search results.
 * EVENT messages from multiple relays are deduplicated by id (notes) / pubkey (profiles).
 */
class GlobalSearchCollector {
    private val lock = ReentrantLock()
    private val notes = mutableMapOf<String, FeedNote>()
    private val profiles = mutableMapOf<String, FeedProfile>()

    private val json = Json { ignoreUnknownKeys = true }

    /**
     * Ingest a raw relay message. Parses EVENT messages matching [subId]
     * and deduplicates into notes (kind 1) or profiles (kind 0).
     */
    fun ingest(message: String, subId: String) {
        try {
            val arr = json.parseToJsonElement(message).jsonArray
            if (arr.size < 3) return
            val type = arr[0].jsonPrimitive.contentOrNull ?: return
            if (type != "EVENT") return
            val sid = arr[1].jsonPrimitive.contentOrNull ?: return
            if (sid != subId) return

            val ev = arr[2].jsonObject
            val id = ev["id"]?.jsonPrimitive?.contentOrNull ?: return
            val pubkey = ev["pubkey"]?.jsonPrimitive?.contentOrNull ?: return
            val kind = ev["kind"]?.jsonPrimitive?.intOrNull ?: return
            val content = ev["content"]?.jsonPrimitive?.contentOrNull ?: return
            val createdAt = ev["created_at"]?.jsonPrimitive?.longOrNull ?: 0L
            val tags: List<List<String>> = try {
                ev["tags"]?.jsonArray?.map { tagArr ->
                    tagArr.jsonArray.map { it.jsonPrimitive.content }
                } ?: emptyList()
            } catch (_: Exception) {
                emptyList()
            }

            lock.withLock {
                when (kind) {
                    1 -> {
                        if (id !in notes) {
                            notes[id] = FeedNote(
                                id = id,
                                pubkey = pubkey,
                                content = content,
                                createdAt = Date(createdAt * 1000),
                                tags = tags,
                                kind = kind,
                            )
                        }
                    }
                    0 -> {
                        try {
                            val metadata = json.parseToJsonElement(content).jsonObject
                            profiles[pubkey] = FeedProfile(
                                pubkey = pubkey,
                                name = metadata["name"]?.jsonPrimitive?.contentOrNull,
                                displayName = metadata["display_name"]?.jsonPrimitive?.contentOrNull,
                                pictureURL = metadata["picture"]?.jsonPrimitive?.contentOrNull,
                                nip05 = metadata["nip05"]?.jsonPrimitive?.contentOrNull,
                                about = metadata["about"]?.jsonPrimitive?.contentOrNull,
                                lud16 = metadata["lud16"]?.jsonPrimitive?.contentOrNull,
                                lud06 = metadata["lud06"]?.jsonPrimitive?.contentOrNull,
                                website = metadata["website"]?.jsonPrimitive?.contentOrNull,
                            )
                        } catch (_: Exception) { }
                    }
                }
            }
        } catch (_: Exception) { }
    }

    /** Read-only snapshot of accumulated results. */
    fun snapshot(): GlobalSearchResults = lock.withLock {
        GlobalSearchResults(
            notes = notes.values.sortedByDescending { it.createdAt },
            profiles = profiles.values.toList(),
        )
    }
}
