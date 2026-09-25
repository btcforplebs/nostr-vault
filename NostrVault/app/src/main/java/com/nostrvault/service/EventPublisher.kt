package com.nostrvault.service

import android.util.Log
import com.nostrvault.relay.HavenBridge
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/**
 * Port of EventPublisher.swift -- event construction and signing helpers.
 * Platform-specific signing via Go JNI bridge (HavenBridge).
 */
object EventPublisher {

    private const val TAG = "EventPublisher"
    private val json = Json { ignoreUnknownKeys = true }

    /**
     * Build an unsigned Nostr event JSON string (NIP-01 structure).
     */
    fun buildUnsignedEvent(
        pubkey: String,
        kind: Int,
        content: String,
        tags: List<List<String>>,
    ): String {
        // NIP-17/NIP-59: the seal (kind 13) and gift wrap (kind 1059) SHOULD randomize
        // created_at up to two days into the past, so the real send time isn't leaked
        // to anyone who sees the event on relays (matches iOS's NIP17Service jitter).
        val createdAt = if (kind == 13 || kind == 1059) {
            System.currentTimeMillis() / 1000 - (0..172_800L).random()
        } else {
            System.currentTimeMillis() / 1000
        }
        val event = buildJsonObject {
            put("pubkey", pubkey)
            put("created_at", createdAt)
            put("kind", kind)
            put("content", content)
            put("tags", buildJsonArray {
                for (tag in tags) {
                    add(buildJsonArray { tag.forEach { add(kotlinx.serialization.json.JsonPrimitive(it)) } })
                }
            })
        }
        return event.toString()
    }

    /**
     * Serialize a signed event for the wire with a real JSON encoder.
     * Hand-built strings escaped only `"` and newline, so a backslash, tab, CR or
     * control character — or a quote inside a tag — reached the relay as invalid
     * JSON or as content that no longer matched the signed id, and was dropped.
     */
    fun serializeSignedEvent(event: NostrEvent): String = buildJsonObject {
        put("id", event.id)
        put("pubkey", event.pubkey)
        put("created_at", event.createdAt)
        put("kind", event.kind)
        put("tags", buildJsonArray {
            for (tag in event.tags) {
                add(buildJsonArray { tag.forEach { add(kotlinx.serialization.json.JsonPrimitive(it)) } })
            }
        })
        put("content", event.content)
        put("sig", event.sig)
    }.toString()

    /**
     * Append the client identification tag for kind-1 notes.
     */
    fun appendClientTag(tags: List<List<String>>, kind: Int): List<List<String>> {
        if (kind != 1) return tags
        if (tags.any { it.firstOrNull() == "client" }) return tags
        return tags + listOf(listOf("client", "Nostr Vault on Android"))
    }

    /**
     * Sign an event via the Go backend (HavenBridge.signEvent).
     * Returns the signed event JSON string, or null on failure.
     */
    fun signWithGoBackend(eventJSON: String, secretKey: String): String? {
        if (!HavenBridge.isLoaded) {
            Log.e(TAG, "Cannot sign: libhaven.so not loaded")
            return null
        }
        return try {
            HavenBridge.signEvent(eventJSON, secretKey)
        } catch (e: Exception) {
            Log.e(TAG, "signEvent failed: ${e.message}")
            null
        }
    }

    /**
     * Sign an event with NIP-13 Proof of Work mining via the Go backend.
     */
    fun mineAndSignWithGoBackend(
        eventJSON: String,
        secretKey: String,
        difficulty: Int,
        maxAttempts: Int = 10_000_000,
    ): String? {
        if (!HavenBridge.isLoaded) {
            Log.e(TAG, "Cannot mine: libhaven.so not loaded")
            return null
        }
        return try {
            HavenBridge.mineAndSignEvent(eventJSON, secretKey, difficulty, maxAttempts)
        } catch (e: Exception) {
            Log.e(TAG, "mineAndSignEvent failed: ${e.message}")
            null
        }
    }

    /**
     * Determine media type from MIME string, with extension fallback.
     */
    fun mediaTypeFromMime(mime: String?, url: String): MediaType {
        if (mime != null) {
            val lower = mime.lowercase()
            if (lower.startsWith("video/")) return MediaType.VIDEO
            if (lower.startsWith("audio/")) return MediaType.AUDIO
            if (lower.startsWith("image/")) return MediaType.IMAGE
            if (lower != "application/octet-stream") return MediaType.UNKNOWN
        }
        val lower = url.lowercase()
        if (VIDEO_EXTENSIONS.any { lower.endsWith(it) }) return MediaType.VIDEO
        if (AUDIO_EXTENSIONS.any { lower.endsWith(it) }) return MediaType.AUDIO
        return MediaType.IMAGE
    }

    enum class MediaType { IMAGE, VIDEO, AUDIO, UNKNOWN }

    private val VIDEO_EXTENSIONS = listOf(".mp4", ".mov", ".webm", ".avi", ".mkv", ".m4v")
    private val AUDIO_EXTENSIONS = listOf(".mp3", ".m4a", ".wav", ".ogg", ".aac", ".flac", ".opus")
}
