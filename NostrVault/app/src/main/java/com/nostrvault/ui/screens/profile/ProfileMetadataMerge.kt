package com.nostrvault.ui.screens.profile

import com.nostrvault.data.model.FeedProfile
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject

/**
 * Builds the kind-0 content an Edit Profile save publishes. A kind 0 replaces
 * the whole profile, so the new content starts from the newest one on the
 * relays and changes only the fields the user edited: lud06, bot and any key
 * this form does not show are kept.
 */
object ProfileMetadataMerge {
    /** The kind-0 keys the edit form shows. */
    const val DISPLAY_NAME = "display_name"
    const val NAME = "name"
    const val ABOUT = "about"
    const val PICTURE = "picture"
    const val BANNER = "banner"
    const val NIP05 = "nip05"
    const val LUD16 = "lud16"
    const val WEBSITE = "website"

    /**
     * The JSON object in a kind-0 [content]; empty when there is none or it is
     * not an object, since such content holds no keys to keep.
     */
    fun parseContent(content: String?): JsonObject =
        content?.let { runCatching { Json.parseToJsonElement(it).jsonObject }.getOrNull() }
            ?: JsonObject(emptyMap())

    /**
     * [base] with each form field the user changed applied: [initial] is what
     * the form showed when opened, [edited] what it holds now (both by kind-0
     * key). A changed field overwrites its key, or removes it when cleared. An
     * unchanged field leaves [base] alone, so a newer value on the relays than
     * the cached one the form showed is not reverted.
     */
    fun merge(base: JsonObject, initial: Map<String, String>, edited: Map<String, String>): JsonObject {
        val out = LinkedHashMap(base)
        for ((key, raw) in edited) {
            val value = raw.trim()
            if (value == initial[key].orEmpty().trim()) continue
            if (value.isEmpty()) out.remove(key) else out[key] = JsonPrimitive(value)
        }
        return JsonObject(out)
    }

    /**
     * True when a field differs from what the form showed, ignoring the
     * spaces and newlines a save trims anyway.
     */
    fun hasChanges(initial: Map<String, String>, edited: Map<String, String>): Boolean =
        edited.any { (key, value) -> value.trim() != initial[key].orEmpty().trim() }

    /** [existing] with the changed fields applied, for showing an edit before the relays have it. */
    fun preview(existing: FeedProfile, initial: Map<String, String>, edited: Map<String, String>): FeedProfile {
        val shown = JsonObject(initial.filterValues { it.isNotEmpty() }.mapValues { JsonPrimitive(it.value) })
        return profile(existing, merge(shown, initial, edited))
    }

    /** [existing] with the form's fields read from kind-0 [content]; a missing key clears its field. */
    fun profile(existing: FeedProfile, content: JsonObject): FeedProfile {
        fun string(key: String) = (content[key] as? JsonPrimitive)?.takeIf { it.isString }?.content
        return existing.copy(
            name = string(NAME),
            displayName = string(DISPLAY_NAME),
            about = string(ABOUT),
            pictureURL = string(PICTURE),
            bannerURL = string(BANNER),
            nip05 = string(NIP05),
            lud16 = string(LUD16),
            website = string(WEBSITE),
        )
    }
}
