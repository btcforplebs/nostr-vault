package com.nostrvault.service

/**
 * When a new version of one of the person's lists looks like another app
 * clobbered it (docs/LIST_WIPE_ALARM.md): emptied, swapped for other entries
 * at the same size, or drained in steps. Pure. Twin of iOS
 * `ListWipeAlarmRule.swift` and web `net/list-wipe-alarm.js`, tested against
 * the same `Fixtures/ListAlarm/alarm-cases.json`.
 */
object ListWipeAlarmRule {
    /** A list this size or larger is clobbered when it keeps fewer than half its entries. */
    const val MIN_ITEMS = 10
    /** The same for an encrypted part, in characters of content. */
    const val MIN_CONTENT = 1000
    /** Versions before the new one it is measured against (haven-go shrinkLookback). */
    const val LOOKBACK = 5
    /** The smallest list an alarm is raised for: emptying one or two entries is an edit. */
    const val ALARM_MIN_ITEMS = 3
    /** A client name is cut to this. */
    const val CLIENT_MAX = 60

    enum class How(val wire: String) { EMPTIED("emptied"), DRAINED("drained"), SWAPPED("swapped"), SHRANK("shrank") }

    /** [after] (the newest version) clobbered [before], the version offered back. */
    data class Alarm(
        val before: ListVersion,
        val after: ListVersion,
        val how: How,
        val from: Int,
        val to: Int,
        val lost: Int,
        /** The app [after] names in its `client` tag, if any. */
        val client: String?,
    )

    /** Whether [b], a version after [a], is a clobber of it, by which entries survive. */
    fun clobbered(a: ListVersion, b: ListVersion): Boolean {
        val ia = ListShrinkRule.items(a)
        val ib = ListShrinkRule.items(b)
        val n = ia.size
        val kept = ia.count { it in ib }
        if (n > 0 && ib.isEmpty()) return true
        if (n >= MIN_ITEMS && kept * 2 < n) return true
        if (a.kind in ListShrinkRule.encryptedKinds) {
            val la = a.content.length
            val lb = b.content.length
            if (la > 0 && lb == 0) return true
            if (la >= MIN_CONTENT && lb * 2 < la) return true
        }
        return false
    }

    /**
     * The alarm for the newest of [newestFirst] (one list's versions), or null.
     * [own]: ids of list events this app signed; [dismissed]: alarms closed
     * with "Keep the new list".
     */
    fun alarm(newestFirst: List<ListVersion>, own: Set<String>, dismissed: Set<String>): Alarm? {
        if (newestFirst.size < 2) return null
        val v0 = newestFirst[0]
        if (v0.id in own || v0.id in dismissed) return null
        val top = minOf(LOOKBACK, newestFirst.size - 1)
        var trigger = -1
        for (i in 1..top) {
            if (!clobbered(newestFirst[i], v0)) continue
            if ((1 until i).any { j -> clobbered(newestFirst[i], newestFirst[j]) }) continue
            trigger = i
            break
        }
        if (trigger < 0) return null
        // Nothing older than the newest version this app signed: that one was the owner's choice.
        var stop = top
        for (k in 1..top) if (newestFirst[k].id in own) { stop = k; break }
        var best: ListVersion? = null
        for (k in 1..stop) {
            val v = newestFirst[k]
            if (!clobbered(v, v0)) continue
            val b = best
            val n = ListShrinkRule.items(v).size
            if (b == null || n > ListShrinkRule.items(b).size ||
                (n == ListShrinkRule.items(b).size && v.content.length > b.content.length)
            ) best = v
        }
        val before = best ?: return null
        val ib = ListShrinkRule.items(before)
        val i0 = ListShrinkRule.items(v0)
        val encrypted = before.kind in ListShrinkRule.encryptedKinds
        val worth = ib.size >= ALARM_MIN_ITEMS || (encrypted && before.content.length >= MIN_CONTENT)
        if (!worth) return null
        val kept = ib.count { it in i0 }
        val how = when {
            i0.isEmpty() && (!encrypted || v0.content.isEmpty()) -> How.EMPTIED
            trigger > 1 -> How.DRAINED
            ib.size >= MIN_ITEMS && kept * 2 < ib.size && i0.size * 2 >= ib.size -> How.SWAPPED
            else -> How.SHRANK
        }
        val client = v0.tags.firstOrNull { it.size >= 2 && it[0] == "client" && it[1].isNotBlank() }
            ?.get(1)?.trim()?.take(CLIENT_MAX)
        return Alarm(before, v0, how, ib.size, i0.size, ib.count { it !in i0 }, client)
    }

    /** The alarm per list of [groups], newest first. */
    fun alarms(
        groups: Map<ListHistory.Key, List<ListVersion>>,
        own: Set<String>,
        dismissed: Set<String>,
    ): List<Pair<ListHistory.Key, Alarm>> =
        groups.mapNotNull { (key, versions) -> alarm(versions, own, dismissed)?.let { key to it } }
            .sortedByDescending { it.second.after.createdAt }
}
