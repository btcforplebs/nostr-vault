package com.nostrvault.ui.screens.profile

import com.nostrvault.util.SecretKeyLeak
import kotlinx.serialization.json.JsonObject

/**
 * An Edit Profile save starts from the newest kind 0 on the relays, which can
 * hold a secret key in a field this form doesn't show (set by another app) or
 * in a tag. Such a field or tag is left out of the save, so the edit still
 * goes out and the key does not; the user is told which one. The key itself
 * is never shown. Twin of Apple `ProfileSecretKeyStrip.swift`.
 */
object ProfileSecretKeyStrip {

    data class Result(
        val content: JsonObject,
        val tags: List<List<String>>,
        /** Field names, and tags as "tag <name>", that were left out. */
        val removed: List<String>,
    )

    fun strip(content: JsonObject, tags: List<List<String>>): Result {
        val removed = mutableListOf<String>()
        val kept = LinkedHashMap<String, kotlinx.serialization.json.JsonElement>()
        for ((key, value) in content) {
            // The whole value as JSON text: a key in a nested object or array counts too.
            if (SecretKeyLeak.containsSecretKey(key) || SecretKeyLeak.containsSecretKey(value.toString())) {
                removed += if (SecretKeyLeak.containsSecretKey(key)) "a field" else key
            } else {
                kept[key] = value
            }
        }
        val keptTags = tags.filter { tag ->
            val leaks = tag.any { SecretKeyLeak.containsSecretKey(it) }
            if (leaks) removed += tag.firstOrNull()?.takeIf { !SecretKeyLeak.containsSecretKey(it) }?.let { "tag $it" } ?: "a tag"
            !leaks
        }
        return Result(JsonObject(kept), keptTags, removed.distinct())
    }

    /** "Removed a secret key from about." / "… from about, tag i." */
    fun message(removed: List<String>): String = "Removed a secret key from ${removed.joinToString(", ")}."
}
