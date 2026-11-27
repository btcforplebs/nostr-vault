package com.nostrvault.ui.screens.dm

import com.nostrvault.data.model.FeedProfile
import com.nostrvault.data.model.PeopleSearchRank
import com.nostrvault.relay.HavenBridge

/**
 * Who New Message's "To:" field names (B2, NV_MESSAGES_UX_CHECK 2026-11-18):
 * an npub, an nprofile or a 64-character hex key, with or without `nostr:`,
 * even when that person's profile isn't loaded; otherwise a name search
 * over the profiles this device has. Blocked people never show (B3).
 */
internal object DMRecipientInput {
    /** Most name matches listed. */
    const val MAX_RESULTS = 10

    /** The note under the field when nothing matched. */
    const val NO_MATCH = "No one by that name here yet. Paste their npub, nprofile or hex key."

    /** The hex key [input] names directly, or null when it is a name to search for. */
    fun key(input: String): String? {
        val s = input.trim().removePrefix("nostr:")
        val lower = s.lowercase()
        return when {
            lower.startsWith("npub1") -> HavenBridge.decodeNpub(lower)
            lower.startsWith("nprofile1") -> HavenBridge.decodeNprofilePubkey(lower)
            lower.length == 64 && lower.all { it in '0'..'9' || it in 'a'..'f' } -> lower
            else -> null
        }
    }

    /**
     * The people to offer for [query], blocked people left out, in the shared
     * people order ([PeopleSearchRank]: follows, your web, then the best name
     * match). [circle] null ranks by name match alone.
     */
    fun results(
        query: String,
        profiles: Map<String, FeedProfile>,
        blocked: Set<String>,
        circle: PeopleSearchRank.Circle? = null,
    ): List<String> {
        val q = query.trim()
        if (q.length < 2) return emptyList()
        key(q)?.let { return if (it in blocked) emptyList() else listOf(it) }
        return PeopleSearchRank.rank(
            profiles.values, q, circle ?: PeopleSearchRank.Circle(emptySet(), emptySet(), emptySet()),
            blocked = blocked, limit = MAX_RESULTS, person = PeopleSearchRank::person,
        ).map { it.pubkey }
    }

    /** True when the field should say [NO_MATCH]. */
    fun showsNoMatch(query: String, results: List<String>): Boolean = query.trim().length >= 2 && results.isEmpty()
}
