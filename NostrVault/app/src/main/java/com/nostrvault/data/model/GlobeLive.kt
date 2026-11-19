package com.nostrvault.data.model

import android.content.SharedPreferences

/**
 * What flies on the globe (iOS `GlobeLive.swift`), past the bar's antenna:
 * My Web's two switches below "Live stars" (Logen 11/19).
 */
object GlobeLive {
    /** NIP-25 reactions (likes, emoji). */
    const val REACTION_KIND = 7

    /** What flies. Both on unless switched off. */
    data class Show(
        /** Hop 2's stars. Off: only you and your follows fly notes (zaps still fly with [extras]). */
        val friendsOfFriends: Boolean = true,
        /** Likes, reposts and zaps. Off: notes and replies only, so nothing from outside your web. */
        val extras: Boolean = true,
    ) {
        /**
         * Whether an arrival from [ring] flies: hop 1 and 2 fly everything,
         * anyone further out only zaps.
         */
        fun allows(sort: GlobeArcs.Sort, ring: GlobeArcs.Ring): Boolean {
            val extra = sort == GlobeArcs.Sort.REPOST || sort == GlobeArcs.Sort.REACTION || sort == GlobeArcs.Sort.ZAP
            if (extra && !extras) return false
            if (sort == GlobeArcs.Sort.ZAP) return true
            return when (ring) {
                GlobeArcs.Ring.FOLLOWS -> true
                GlobeArcs.Ring.WEB -> friendsOfFriends
                GlobeArcs.Ring.OUTSIDE -> false
            }
        }

        /** The kinds asked for by author: notes and replies, and with [extras] reposts and reactions. Zaps are asked for apart. */
        val authorKinds: List<Int>
            get() = GlobeArcs.KINDS + if (extras) GlobeArcs.REPOST_KINDS + REACTION_KIND else emptyList()
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
 * The globe's live-star switches, kept across launches with iOS's keys
 * (`LiveArcsSetting`): the bar's antenna and My Web's "Live stars" ([KEY]),
 * Friends of friends ([FRIENDS_KEY]) and Likes, reposts and zaps
 * ([EXTRAS_KEY]). A switch is only stored once someone flips it, so everyone
 * who never touched it gets the default: all on.
 */
object LiveArcsSetting {
    const val PREFS = "wot_live_arcs"
    const val KEY = "wotLiveArcs"
    const val FRIENDS_KEY = "wotLiveArcs.friendsOfFriends"
    const val EXTRAS_KEY = "wotLiveArcs.extras"
    /** Live arrivals start on (Logen, 10/15). */
    const val DEFAULT_ON = true

    fun isOn(prefs: SharedPreferences) = prefs.getBoolean(KEY, DEFAULT_ON)

    fun show(prefs: SharedPreferences) = GlobeLive.Show(
        friendsOfFriends = prefs.getBoolean(FRIENDS_KEY, true),
        extras = prefs.getBoolean(EXTRAS_KEY, true),
    )

    /**
     * The feed and sort switches My Web had until 11/12, when Logen had them
     * cut. A value someone stored would have no switch left to undo it, so it
     * goes. The three live switches keep what they were set to.
     */
    val RETIRED_KEYS: List<String> =
        listOf("following", "discover", "global").map { "wotLiveArcs.$it" } +
            listOf("note", "reply", "repost", "reaction", "zap").map { "wotLiveArcs.sort.$it" }

    fun retireCutSwitches(prefs: SharedPreferences) {
        if (RETIRED_KEYS.none(prefs::contains)) return
        prefs.edit().apply { RETIRED_KEYS.forEach(::remove) }.apply()
    }
}
