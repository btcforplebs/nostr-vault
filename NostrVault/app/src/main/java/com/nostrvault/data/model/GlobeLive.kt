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
 * Whether notes fly across the WOT globe as they reach the relay (iOS
 * `LiveArcsSetting`, same keys). The bar's antenna is the only switch: every
 * feed and every sort flies. Kept across launches; a switch is only stored once
 * someone flips it, so everyone who never touched it gets the default.
 */
object LiveArcsSetting {
    const val PREFS = "wot_live_arcs"
    const val KEY = "wotLiveArcs"
    /** Live arrivals start on (Logen, 10/15). */
    const val DEFAULT_ON = true

    /** A cut feed switch's key, kept so [retireCutSwitches] can remove it. */
    fun key(ring: GlobeArcs.Ring) = "wotLiveArcs." + ring.name.lowercase()

    /** A cut sort switch's key, kept so [retireCutSwitches] can remove it. */
    fun key(sort: GlobeArcs.Sort) = "wotLiveArcs.sort." + sort.name.lowercase()

    fun isOn(prefs: SharedPreferences) = prefs.getBoolean(KEY, DEFAULT_ON)

    /**
     * The feed and sort switches My Web had until 11/12, when Logen had them
     * cut: everything flies now. A value someone stored would have no switch
     * left to undo it, so it goes. The antenna ([KEY]) keeps what it was set to.
     */
    val RETIRED_KEYS: List<String> =
        GlobeArcs.Ring.entries.map { key(it) } + GlobeArcs.Sort.entries.map { key(it) }

    fun retireCutSwitches(prefs: SharedPreferences) {
        if (RETIRED_KEYS.none(prefs::contains)) return
        prefs.edit().apply { RETIRED_KEYS.forEach(::remove) }.apply()
    }
}
