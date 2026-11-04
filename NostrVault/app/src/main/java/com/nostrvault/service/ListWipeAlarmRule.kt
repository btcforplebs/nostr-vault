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
        /** The app [after] names in its `client` tag, if any ([cleanClient]). */
        val client: String?,
        /** [client] calls itself Nostr Vault, yet this device didn't sign it. */
        val claimsNostrVault: Boolean = false,
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

    /** Versions searched back from the newest for a clobber nobody undid (haven-go listHistoryKeep). */
    const val HISTORY = 20

    /**
     * The alarm for one list's versions ([newestFirst]), or null: the newest
     * clobber among the newest [HISTORY] versions, skipping versions this app
     * signed ([own]), that no newer version undid by holding the list from
     * before again, and that wasn't dismissed. A later save by the same app,
     * or an own edit, does not hide it (Tron, PR 1635).
     */
    fun alarm(newestFirst: List<ListVersion>, own: Set<String>, dismissed: Set<String>): Alarm? {
        for (k in 0 until minOf(HISTORY, newestFirst.size)) {
            val vk = newestFirst[k]
            if (vk.id in own) continue
            val a = judge(newestFirst, k, own) ?: continue
            if (vk.id in dismissed) return null
            if ((0 until k).any { j -> ListShrinkRule.holds(newestFirst[j], a.before) }) return null
            return a
        }
        return null
    }

    /** The alarm [newestFirst]`[k]` raises against the versions older than it, or null. */
    internal fun judge(newestFirst: List<ListVersion>, k: Int, own: Set<String>): Alarm? {
        val vk = newestFirst[k]
        val top = minOf(k + LOOKBACK, newestFirst.size - 1)
        var trigger = -1
        for (i in k + 1..top) {
            if (!clobbered(newestFirst[i], vk)) continue
            if ((k + 1 until i).any { j -> clobbered(newestFirst[i], newestFirst[j]) }) continue
            trigger = i
            break
        }
        if (trigger < 0) return null
        // Nothing older than the newest version this app signed: that one was the owner's choice.
        var stop = top
        for (m in k + 1..top) if (newestFirst[m].id in own) { stop = m; break }
        var best: ListVersion? = null
        for (m in k + 1..stop) {
            val v = newestFirst[m]
            if (!clobbered(v, vk)) continue
            val b = best
            val n = ListShrinkRule.items(v).size
            if (b == null || n > ListShrinkRule.items(b).size ||
                (n == ListShrinkRule.items(b).size && v.content.length > b.content.length)
            ) best = v
        }
        val before = best ?: return null
        val ib = ListShrinkRule.items(before)
        val i0 = ListShrinkRule.items(vk)
        val encrypted = before.kind in ListShrinkRule.encryptedKinds
        val worth = ib.size >= ALARM_MIN_ITEMS || (encrypted && before.content.length >= MIN_CONTENT)
        if (!worth) return null
        val kept = ib.count { it in i0 }
        val how = when {
            i0.isEmpty() && (!encrypted || vk.content.isEmpty()) -> How.EMPTIED
            trigger > k + 1 -> How.DRAINED
            ib.size >= MIN_ITEMS && kept * 2 < ib.size && i0.size * 2 >= ib.size -> How.SWAPPED
            else -> How.SHRANK
        }
        val client = vk.tags.asSequence()
            .filter { it.size >= 2 && it[0] == "client" }
            .mapNotNull { cleanClient(it[1]) }
            .firstOrNull()
        val claims = client != null && "nostr vault" in client.lowercase()
        return Alarm(before, vk, how, ib.size, i0.size, ib.count { it !in i0 }, client, claims)
    }

    /**
     * A `client` tag's name as shown: control and format characters (Cc, Cf:
     * bidi overrides, zero-width joiners) removed, trimmed, cut to
     * [CLIENT_MAX] code points; null when nothing is left.
     */
    fun cleanClient(raw: String): String? {
        val sb = StringBuilder()
        var i = 0
        while (i < raw.length) {
            val cp = raw.codePointAt(i)
            val type = Character.getType(cp)
            if (type != Character.CONTROL.toInt() && type != Character.FORMAT.toInt()) sb.appendCodePoint(cp)
            i += Character.charCount(cp)
        }
        val t = sb.toString().trim()
        if (t.isEmpty()) return null
        val cut = t.codePointCount(0, t.length).coerceAtMost(CLIENT_MAX)
        return t.substring(0, t.offsetByCodePoints(0, cut))
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
