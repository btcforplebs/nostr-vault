package com.nostrvault.service

/**
 * Old versions of the person's lists, read from the vault's /lists relay, and
 * what the apps do with them: spot a wipe, compare, restore. Twin of iOS
 * `ListHistory.swift` (RESEARCH/NV_LIST_PROTECTION_PLAN.md).
 */
object ListHistory {
    /** One list: a kind, and the `d` of an addressable one. */
    data class Key(val kind: Int, val d: String) : Comparable<Key> {
        override fun compareTo(other: Key): Int = compareValuesBy(this, other, Key::kind, Key::d)
    }

    /** A wipe the person should hear about: [after] replaced [before]. */
    data class Wipe(val before: ListVersion, val after: ListVersion)

    val newerFirst: Comparator<ListVersion> = compareByDescending<ListVersion> { it.createdAt }.thenBy { it.id }

    /** The versions grouped per list, newest first, one per id, protected kinds by [author] only. */
    fun group(versions: List<ListVersion>, author: String): Map<Key, List<ListVersion>> =
        versions.asSequence()
            .filter { it.pubkey == author && ListShrinkRule.isProtected(it.kind) }
            .distinctBy { it.id }
            .groupBy { Key(it.kind, it.d) }
            .mapValues { (_, v) -> v.sortedWith(newerFirst) }

    /**
     * The wipe the newest version made, if it made one: it shrank the version
     * just before it. The version offered back is the largest one since the
     * wipe before that the newest shrank (a late, older copy may sit in
     * between, as haven-go listHistoryToDrop).
     */
    fun latestWipe(newestFirst: List<ListVersion>): Wipe? {
        if (newestFirst.size < 2 || !ListShrinkRule.shrank(newestFirst[1], newestFirst[0])) return null
        val after = newestFirst[0]
        // This wipe's span ends at the wipe before it (not included).
        var end = newestFirst.size
        for (w in 1 until newestFirst.size - 1) {
            if (ListShrinkRule.shrank(newestFirst[w + 1], newestFirst[w])) {
                end = w
                break
            }
        }
        var best = newestFirst[1]
        for (i in 2 until end) {
            val v = newestFirst[i]
            if (ListShrinkRule.shrank(v, after) && ListShrinkRule.itemCount(v) > ListShrinkRule.itemCount(best)) best = v
        }
        return Wipe(best, after)
    }

    /** The smallest list a banner is shown for: emptying a list of one or two items is an ordinary edit (Tron, PR 1568). */
    const val BANNER_MIN_ITEMS = 3

    /** Whether a wipe is worth the dashboard banner: at least [BANNER_MIN_ITEMS] items before, or a long private part. */
    fun worthABanner(wipe: Wipe): Boolean =
        ListShrinkRule.itemCount(wipe.before) >= BANNER_MIN_ITEMS ||
            (wipe.before.kind in ListShrinkRule.encryptedKinds && wipe.before.content.length >= ListShrinkRule.MIN_CONTENT)

    /** Whether a restore of [old] replaces the encrypted private part: the diff only sees public items. */
    fun replacesPrivatePart(old: ListVersion, current: ListVersion?): Boolean =
        old.kind in ListShrinkRule.encryptedKinds && old.content != (current?.content ?: "")

    /** What restoring [old] over [current] changes, as item keys: what comes back and what goes. */
    fun diff(old: ListVersion, current: ListVersion?): Pair<Set<String>, Set<String>> {
        val was = ListShrinkRule.items(old)
        val now = current?.let(ListShrinkRule::items).orEmpty()
        return (was - now) to (now - was)
    }

    /**
     * The list a restore signs: [old]'s tags. Kind 3 keeps the current content
     * (an old relay list may be stored there, PR875 N1); every other kind takes
     * the old content, its encrypted private part included (encrypted to the
     * same account, so it still opens).
     */
    fun restored(old: ListVersion, current: ListVersion?): Pair<List<List<String>>, String> {
        val content = if (old.kind == 3) current?.content ?: old.content else old.content
        return old.tags to content
    }

    /** How an item key reads on screen: its value, or a profile's field and value. */
    fun label(key: String): String {
        val parts = key.split('\u0000', limit = 2)
        return if (parts.size == 2) "${parts[0]}: ${parts[1]}" else key
    }
}
