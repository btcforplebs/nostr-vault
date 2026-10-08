package com.nostrvault.ui.screens.profile

import java.util.Locale

/** The two lists a profile's Following / Followers counts open. */
enum class FollowListTab(val title: String) {
    FOLLOWING("Following"),
    FOLLOWERS("Followers"),
}

/** Order inside each group. The groups themselves never mix. */
enum class FollowListSort(val title: String) {
    /** Followed by the most people you follow first. */
    TRUSTED("Most trusted"),
    /** Newest follow first. */
    RECENT("Recent"),
    NAME("Name A–Z"),
}

/** Where a person sits relative to the viewer, in display order. */
enum class FollowListGroup(val title: String) {
    FOLLOWS("People you follow"),
    WEB_OF_TRUST("Your web of trust"),
    OUTSIDE("Outside your web of trust"),
}

/** One person in a follow list. */
data class FollowListPerson(
    val pubkey: String,
    /** Shown name, used for Name A–Z and search. */
    val name: String,
    /** NIP-05, searched alongside the name. */
    val nip05: String = "",
    /**
     * Larger is newer. For followers: when their list naming this profile was
     * published. For following: position in the contact list, which grows as
     * people are added.
     */
    val recency: Long,
)

data class FollowListSection(
    val group: FollowListGroup,
    val people: List<FollowListPerson>,
)

/** Port of iOS `FollowListLogic` (FollowListLogic.swift). */
object FollowListLogic {

    /**
     * Splits [people] into the three groups and orders each.
     *
     * - follows: who the viewer follows.
     * - webOfTrust: the viewer's trust graph (the same set Global feed and
     *   search ranking use). Follows win over it.
     * - trustRank: position in the extended network, ranked by how many of
     *   the viewer's follows follow them; lower is more trusted.
     * - hidden: spam, dropped from every group.
     *
     * Empty groups are left out.
     */
    fun sections(
        people: List<FollowListPerson>,
        follows: Set<String>,
        webOfTrust: Set<String>,
        trustRank: Map<String, Int>,
        hidden: Set<String> = emptySet(),
        sort: FollowListSort,
        query: String = "",
    ): List<FollowListSection> {
        val seen = HashSet<String>()
        val buckets = HashMap<FollowListGroup, MutableList<FollowListPerson>>()
        for (person in people) {
            if (person.pubkey in hidden || !matches(person, query)) continue
            if (!seen.add(person.pubkey)) continue
            val group = when {
                person.pubkey in follows -> FollowListGroup.FOLLOWS
                person.pubkey in webOfTrust || trustRank.containsKey(person.pubkey) -> FollowListGroup.WEB_OF_TRUST
                else -> FollowListGroup.OUTSIDE
            }
            buckets.getOrPut(group) { mutableListOf() }.add(person)
        }
        return FollowListGroup.entries.mapNotNull { group ->
            val members = buckets[group]?.takeIf { it.isNotEmpty() } ?: return@mapNotNull null
            FollowListSection(group, ordered(members, sort, trustRank))
        }
    }

    fun ordered(people: List<FollowListPerson>, sort: FollowListSort, trustRank: Map<String, Int>): List<FollowListPerson> =
        when (sort) {
            FollowListSort.RECENT -> people.sortedWith(
                compareByDescending<FollowListPerson> { it.recency }.then(byName),
            )
            FollowListSort.NAME -> people.sortedWith(byName)
            // Ranked people first, best rank first; the unranked keep the
            // newest-first order so the tail is still meaningful.
            FollowListSort.TRUSTED -> people.sortedWith(
                compareBy<FollowListPerson> { trustRank[it.pubkey] ?: Int.MAX_VALUE }
                    .thenByDescending { it.recency }
                    .then(byName),
            )
        }

    fun matches(person: FollowListPerson, query: String): Boolean {
        val q = query.trim()
        if (q.isEmpty()) return true
        return person.name.contains(q, ignoreCase = true) || person.nip05.contains(q, ignoreCase = true)
    }

    /** A count that may be short of the real number reads "48+". */
    fun countText(count: Int, more: Boolean): String {
        val short = when {
            count >= 1_000_000 -> String.format(Locale.US, "%.1fM", count / 1_000_000.0)
            count >= 1_000 -> String.format(Locale.US, "%.1fk", count / 1_000.0)
            else -> count.toString()
        }
        if (!more) return short
        return if (count == 0) "—" else "$short+"
    }

    /** A bio on two lines: line breaks become spaces so the two lines carry words, not blank space. */
    fun bioLine(about: String?): String? {
        if (about == null) return null
        val flat = about.lines().map { it.trim() }.filter { it.isNotEmpty() }.joinToString(" ")
        return flat.ifEmpty { null }
    }

    private val byName: Comparator<FollowListPerson> = Comparator { a, b ->
        val order = a.name.compareTo(b.name, ignoreCase = true)
        if (order != 0) order else a.pubkey.compareTo(b.pubkey)
    }
}
