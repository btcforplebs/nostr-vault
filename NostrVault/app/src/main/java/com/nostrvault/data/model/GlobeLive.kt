package com.nostrvault.data.model

import android.content.SharedPreferences

/**
 * What flies on the globe, by sort (iOS `GlobeLive.swift`): the live switches
 * beyond the three feeds.
 */
object GlobeLive {
    /** NIP-25 reactions (likes, emoji). */
    const val REACTION_KIND = 7

    /** Which sorts fly. All on unless switched off. */
    data class Show(
        val notes: Boolean = true,
        val replies: Boolean = true,
        val reposts: Boolean = true,
        val reactions: Boolean = true,
        val zaps: Boolean = true,
    ) {
        fun allows(sort: GlobeArcs.Sort): Boolean = when (sort) {
            GlobeArcs.Sort.NOTE -> notes
            GlobeArcs.Sort.REPLY -> replies
            GlobeArcs.Sort.REPOST -> reposts
            GlobeArcs.Sort.REACTION -> reactions
            GlobeArcs.Sort.ZAP -> zaps
        }

        /** The kinds to ask relays for by author or for you: notes and replies are both kind 1 (and 1111). */
        val noteKinds: List<Int>
            get() = (if (notes || replies) GlobeArcs.KINDS else emptyList()) + (if (reactions) listOf(REACTION_KIND) else emptyList())

        /** The wide REQ's kinds: the notes' and, with Reposts on, reposts. */
        val wideKinds: List<Int>
            get() = noteKinds + (if (reposts) GlobeArcs.REPOST_KINDS else emptyList())
    }

    /**
     * A reaction flies from the reactor to the person reacted to: NIP-25's last
     * `p` tag, beside the `e` of the note it reacts to. One without that person
     * (or reacting to themself) doesn't fly, so it never lands on you by default.
     */
    fun reaction(id: String, author: String, tags: List<List<String>>): GlobeArcs.Arrival? {
        if (tags.none { it.size >= 2 && it[0] == "e" }) return null
        val to = tags.lastOrNull { it.size >= 2 && it[0] == "p" }?.get(1)?.lowercase() ?: return null
        if (!GlobeArcs.isKey(to) || to == author) return null
        return GlobeArcs.Arrival(id, author, listOf(to), sort = GlobeArcs.Sort.REACTION)
    }
}

/**
 * Whether notes fly across the WOT globe as they reach the relay, and from which
 * feeds and of which sorts (iOS `LiveArcsSetting`, same keys). The bar's
 * antenna is the main switch. Kept across launches; a switch is only stored once
 * someone flips it, so everyone who never touched it gets the default.
 */
object LiveArcsSetting {
    const val PREFS = "wot_live_arcs"
    const val KEY = "wotLiveArcs"
    /** Live arrivals start on (Logen, 10/15). */
    const val DEFAULT_ON = true

    /** Each feed's own switch. All three start on. */
    fun key(ring: GlobeArcs.Ring) = "wotLiveArcs." + ring.name.lowercase()

    /** Each sort's own switch. All on. */
    fun key(sort: GlobeArcs.Sort) = "wotLiveArcs.sort." + sort.name.lowercase()

    fun isOn(prefs: SharedPreferences) = prefs.getBoolean(KEY, DEFAULT_ON)

    fun rings(prefs: SharedPreferences): Set<GlobeArcs.Ring> =
        GlobeArcs.Ring.entries.filterTo(HashSet()) { prefs.getBoolean(key(it), true) }

    fun show(prefs: SharedPreferences) = GlobeLive.Show(
        notes = prefs.getBoolean(key(GlobeArcs.Sort.NOTE), true),
        replies = prefs.getBoolean(key(GlobeArcs.Sort.REPLY), true),
        reposts = prefs.getBoolean(key(GlobeArcs.Sort.REPOST), true),
        reactions = prefs.getBoolean(key(GlobeArcs.Sort.REACTION), true),
        zaps = prefs.getBoolean(key(GlobeArcs.Sort.ZAP), true),
    )
}
