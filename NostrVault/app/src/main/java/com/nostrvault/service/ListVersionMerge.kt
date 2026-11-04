package com.nostrvault.service

import kotlinx.coroutines.CancellationException
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonPrimitive

/**
 * Merging old versions of one list (List backups › a list › Merge,
 * RESEARCH/NV_LIST_MERGE_PLAN.md): the person ticks one or more versions the
 * vault kept, sees what each would bring back or drop against the list they
 * have now, and gets one list holding every entry of the ticked versions and
 * the current one, each entry once. Pure rules; nothing here reads the
 * network or signs ([ListMergeSave] and [ListVersionSave] do). Web twin:
 * web-vault/src/net/list-version-merge.js; the wipe rule is [ListShrinkRule.shrank].
 */
object ListVersionMerge {
    data class MergeKind(val kind: Int, val name: String, val noun: String)

    /**
     * The lists that can be merged. Not kind 0 (a profile is fields, not entries),
     * not the relay list (only Settings › Relays' Save sends a 10002, Logen
     * 2026-10-31; kept by Tod 2026-11-03) and not the addressable sets (one list
     * per `d`). Were 10002 added, [buildMerge] already keeps the list now's
     * read/write marker (its key is `r` + the address).
     */
    val mergeKinds: List<MergeKind> = listOf(
        MergeKind(3, "Follows", "follow"),
        MergeKind(10000, "Mutes", "muted entry"),
        MergeKind(10003, "Bookmarks", "bookmark"),
        MergeKind(10063, "Media servers", "server"),
        MergeKind(10050, "DM relays", "relay"),
        MergeKind(10006, "Blocked relays", "relay"),
        MergeKind(10007, "Search relays", "relay"),
        MergeKind(10015, "Interests", "interest"),
        MergeKind(10001, "Pinned notes", "pinned note"),
        MergeKind(10004, "Communities", "community"),
        MergeKind(10030, "Emoji", "emoji"),
    )

    fun mergeKind(kind: Int): MergeKind? = mergeKinds.firstOrNull { it.kind == kind }

    /**
     * Relay and server lists: whatever an old version held comes back ticked (Hal's
     * review: 3 relays down to 1 is never "deliberate" by count). Same five on web and iPhone.
     */
    val relayKinds: Set<Int> = setOf(10002, 10050, 10006, 10007, 10063)

    /** A list under this many entries brings everything back ticked: by count alone its edit and its wipe look the same. */
    const val SHORT = 10

    /**
     * The vault keeps every version among its newest this many of a list (haven-go
     * listHistoryKeep); older ones only around a wipe, so a step between two of them
     * may hide versions it let go.
     */
    const val VAULT_KEEP = 20

    /** Versions before a new one it is measured against, so a list emptied in steps is one wipe (haven-go shrinkLookback). */
    const val LOOKBACK = 5

    /** Kinds whose content is never a private part: kind 3 keeps relay hints there. */
    private val noPrivate = setOf(3)
    private val urlTags = mapOf(10002 to "r", 10050 to "relay", 10006 to "relay", 10007 to "relay", 10063 to "server")
    private val lower = setOf("p", "e", "t", "word")

    private fun isMeta(tag: List<String>) = tag.firstOrNull() in ListShrinkRule.metadataTags

    /** Whether [v] carries a private part to open: NIP-51 content, encrypted to the person. */
    fun hasPrivate(v: ListVersion?): Boolean = v != null && v.kind !in noPrivate && v.content.isNotBlank()

    /**
     * A relay or server address as Lazarus compares them: scheme and host
     * lowercased, default port dropped, repeated slashes collapsed, trailing
     * slash dropped. Not an address: the trimmed text without trailing slashes.
     */
    fun normUrl(raw: String): String {
        val s = raw.trim()
        val fallback = s.trimEnd('/')
        val uri = runCatching { java.net.URI(s) }.getOrNull() ?: return fallback
        val scheme = uri.scheme?.lowercase() ?: return fallback
        val host = uri.host?.lowercase() ?: return fallback
        val defaultPort = when (scheme) { "wss", "https" -> 443; "ws", "http" -> 80; else -> -1 }
        val port = if (uri.port != -1 && uri.port != defaultPort) ":${uri.port}" else ""
        val path = (uri.rawPath ?: "").replace(Regex("/{2,}"), "/").trimEnd('/')
        val query = uri.rawQuery?.takeIf { it.isNotEmpty() }?.let { "?$it" }.orEmpty()
        return "$scheme://$host$port$path$query"
    }

    /**
     * One entry's identity: `tag[0]` and `tag[1]` (a rewritten relay hint or
     * petname is the same entry), hex and words lowercased, relay and server
     * addresses normalized. Null for a tag that isn't an entry (no value, or
     * one naming the list).
     */
    fun itemKey(kind: Int, tag: List<String>): String? {
        val name = tag.firstOrNull() ?: return null
        if (isMeta(tag)) return null
        val v = tag.getOrNull(1)?.trim().orEmpty()
        if (v.isEmpty()) return null
        val value = when {
            urlTags[kind] == name -> normUrl(v)
            name in lower -> v.lowercase()
            else -> v
        }
        return "$name\u0000$value"
    }

    data class Entry(val tag: List<String>, val private: Boolean)

    /**
     * A version opened for merging: its entries, public and private, each once
     * (listed twice, or publicly and privately, is one entry, and private wins),
     * in order. [reason] says why the private part couldn't be opened ("" when it
     * could or there is none); [locked]: it is left for later.
     */
    data class Opened(val v: ListVersion, val entries: Map<String, Entry>, val reason: String, val locked: Boolean) {
        /** What it held privately is unknown: left for later, or couldn't be opened. */
        val unread: Boolean get() = reason.isNotEmpty() || locked

        /** No entries, and no unread private part (that may hold any number). Never offered. */
        val isEmpty: Boolean get() = entries.isEmpty() && !unread
    }

    /** How a version's private part is opened. */
    sealed interface Opener {
        /** Left for later: the version is locked (a signer isn't asked once per version just to look). */
        data object Later : Opener

        /** This sign-in can't open private entries. */
        data object None : Opener

        /** [open] decrypts the trimmed content to self; null when it couldn't. */
        class With(val open: suspend (String) -> String?) : Opener
    }

    suspend fun openVersion(v: ListVersion, opener: Opener): Opened {
        val entries = LinkedHashMap<String, Entry>()
        fun add(tag: List<String>, private: Boolean) {
            val key = itemKey(v.kind, tag) ?: return
            val had = entries[key]
            if (had == null) entries[key] = Entry(tag, private)
            else if (private && !had.private) entries[key] = had.copy(private = true)
        }
        v.tags.forEach { add(it, false) }
        if (!hasPrivate(v)) return Opened(v, entries, "", false)
        val reason = when (opener) {
            Opener.Later -> return Opened(v, entries, "", true)
            Opener.None -> "this sign-in can't open private entries"
            is Opener.With -> try {
                val plain = opener.open(v.content.trim()) ?: throw IllegalStateException("")
                val tags = privateTags(plain) ?: throw IllegalStateException("it isn't a list")
                tags.forEach { add(it, true) }
                ""
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                val why = e.message.orEmpty()
                if (why.isEmpty()) "its private part couldn't be opened" else "its private part couldn't be opened ($why)"
            }
        }
        return Opened(v, entries, reason, false)
    }

    /** A decrypted private part's tags; null when it is not a JSON array. Entries that aren't arrays are skipped. */
    fun privateTags(plaintext: String): List<List<String>>? {
        val array = runCatching { Json.parseToJsonElement(plaintext) as? JsonArray }.getOrNull() ?: return null
        return array.mapNotNull { item ->
            (item as? JsonArray)?.map { (it as? JsonPrimitive)?.content ?: it.toString() }
        }
    }

    /** Why a version can't be ticked, or "". */
    fun pickProblem(v: Opened): String = when {
        v.isEmpty -> "Empty: nothing to bring back."
        v.reason.isNotEmpty() -> "Can't be merged: ${v.reason}."
        else -> ""
    }

    data class Delta(val added: Int, val removed: Int)

    /** What one version would bring back (+) and drop (-) against the current list. */
    fun deltaOf(version: Opened, current: Opened?): Delta {
        val now = current?.entries.orEmpty()
        return Delta(version.entries.keys.count { it !in now }, now.keys.count { it !in version.entries })
    }

    /**
     * UNSURE: whether the person took it out can't be told (a gap in the vault's
     * history, or a newer version whose private part wasn't read); it stays out
     * unless ticked in Review (Logen 2026-11-03, as Lazarus).
     */
    enum class Status { CURRENT, LOST, REMOVED, BACK, UNSURE }

    /** One merged entry with its tick. [at]: when it was lost, removed or went unsure, else 0. [from]: the versions holding it. */
    data class Row(
        val key: String,
        val tag: List<String>,
        val private: Boolean,
        val status: Status,
        val at: Long,
        val ticked: Boolean,
        val from: List<String>,
    )

    private val newestFirst: Comparator<Opened> = compareBy(ListHistory.newerFirst) { it.v }

    /**
     * The ids of the versions with no hole between them: the vault's newest [VAULT_KEEP]
     * of [vault] (its kept versions; a current found only on relays isn't one). A step
     * between two of these is the whole story; any other may hide versions nobody kept.
     */
    fun unbroken(vault: List<ListVersion>): Set<String> =
        vault.sortedWith(ListHistory.newerFirst).take(VAULT_KEEP).mapTo(mutableSetOf()) { it.id }

    /**
     * Whether [next], a version after [prev], wiped it, judged by which entries went
     * rather than by size (a stale copy of the same size that swapped them out is a
     * wipe too): it empties [prev], or keeps under half of a list of [SHORT] or more.
     * Web `wipedBy`, iPhone `shrank`.
     */
    fun wipedBy(prev: Opened, next: Opened): Boolean {
        val a = prev.entries.size
        if (a == 0) return false
        if (next.entries.isEmpty()) return true
        if (a < SHORT) return false
        return prev.entries.keys.count { it in next.entries } * 2 < a
    }

    /**
     * Whether the entry [key], held by `timeline[i]` (newest first) and gone from
     * `timeline[i - 1]` on, went in a wipe: some version O at or up to [LOOKBACK]
     * before i that held it was wiped by some version W from i - 1 on, O and W at
     * most [LOOKBACK] apart, with no version between them already wiping O (that one
     * was the wipe; edits after it are the person's). A list drained 40 -> 20 -> 10 -> 5
     * loses P(30), P(15) and P(8). Only over [ok] versions: a gap or an unread part
     * stops the window. Web and iPhone `wipeOf`. -> the wipe, or null.
     */
    private fun wipeOf(timeline: List<Opened>, i: Int, key: String, ok: (Opened) -> Boolean, memo: MutableMap<Long, Boolean>): Opened? {
        fun wiped(o: Int, w: Int) = memo.getOrPut(o.toLong() * timeline.size + w) { wipedBy(timeline[o], timeline[w]) }
        var o = i
        while (o < timeline.size && o - i < LOOKBACK && ok(timeline[o])) {
            if (key in timeline[o].entries) {
                var w = i - 1
                while (w >= 0 && o - w <= LOOKBACK && ok(timeline[w])) {
                    if (wiped(o, w) && ((w + 1) until o).none { wiped(o, it) }) return timeline[w]
                    w--
                }
            }
            o++
        }
        return null
    }

    /**
     * Whether `timeline[j]` (newest first) wiped the list, for the version row's flag:
     * against any of the [LOOKBACK] versions before it that it wiped with no version
     * between already wiping that one, so a drain step counts. Unread either side:
     * [ListShrinkRule.shrank] by count and length. Web `wasWipe`.
     */
    fun wasWipe(timeline: List<Opened>, j: Int): Boolean {
        if (j + 1 >= timeline.size) return false
        val v = timeline[j]
        if (v.unread || timeline[j + 1].unread) return ListShrinkRule.shrank(timeline[j + 1].v, v.v)
        var o = j + 1
        while (o < timeline.size && o - j <= LOOKBACK && !timeline[o].unread) {
            if (wipedBy(timeline[o], v) && ((j + 1) until o).none { wipedBy(timeline[o], timeline[it]) }) return true
            o++
        }
        return false
    }

    /**
     * The merge: every entry of [current] and of each version in [picked], each
     * once. [all] is every version found (opened); [vault] the ids of the ones the
     * vault keeps with no hole between them ([unbroken]; null: all of them). For an
     * entry not in the list now, with H the newest version holding it (picked or
     * not) and N the one after:
     * - BACK: no N (nothing took it out): ticked, `at` = 0;
     * - REMOVED but ticked: a relay list, or H read and under [SHORT] (an edit and a
     *   wipe look the same by count), `at` = N so Review says when it went;
     * - UNSURE: H or any newer version with its private part unread (it may hold the
     *   entry privately): unticked, `at` = N;
     * - H or N outside [vault]: versions between them may be gone; LOST if N wiped H
     *   (the vault pins a wipe with the version before it), else UNSURE;
     * - LOST: a wipe took it ([wipeOf], step drains too), ticked, `at` = the wipe;
     * - REMOVED: an ordinary edit took it, so the person did: unticked, `at` = N.
     * A row is private when any version ever held it privately, or (not in the list
     * now) a newer version whose private part wasn't read may: hiding a public
     * entry loses nothing, publishing a hidden one can't be undone. Its tag is the
     * current version's, else the newest picked one's (so a 10002 keeps the list
     * now's marker). Order: the current list's, then what comes back, newest
     * version first. Web twin `buildMerge` (test/list-merge-gaps.test.mjs).
     */
    fun buildMerge(current: Opened?, picked: List<Opened>, all: List<Opened>, vault: Set<String>? = null): List<Row> {
        val sources = listOfNotNull(current) + picked.filter { it.v.id != current?.v?.id }.sortedWith(newestFirst)
        val timeline = all.sortedWith(newestFirst)
        val run = vault ?: timeline.mapTo(mutableSetOf()) { it.v.id }
        val ok: (Opened) -> Boolean = { it.v.id in run && !it.unread }
        val memo = HashMap<Long, Boolean>()
        class Acc(val key: String, val tag: List<String>, var private: Boolean, val from: MutableList<String>)
        val rows = LinkedHashMap<String, Acc>()
        for (src in sources) for ((key, e) in src.entries) {
            val row = rows[key]
            if (row != null) { row.private = row.private || e.private; row.from += src.v.id; continue }
            rows[key] = Acc(key, e.tag, e.private, mutableListOf(src.v.id))
        }
        return rows.values.map { row ->
            val i = timeline.indexOfFirst { it.entries.containsKey(row.key) }
            val newerUnread = timeline.subList(0, if (i < 0) timeline.size else i).any { it.v.kind !in noPrivate && it.unread }
            val inNow = current?.entries?.containsKey(row.key) == true
            val private = row.private || all.any { it.entries[row.key]?.private == true } || (!inNow && newerUnread)
            fun out(status: Status, at: Long, ticked: Boolean) = Row(row.key, row.tag, private, status, at, ticked, row.from)
            if (inNow) return@map out(Status.CURRENT, 0, true)
            val held = timeline.getOrNull(i)
            val next = if (i > 0) timeline[i - 1] else null
            when {
                held == null || next == null -> out(Status.BACK, 0, true)
                // Ticked all the same, but N took it out of a list that held it: say when (Tron, Logen 2026-11-03).
                held.v.kind in relayKinds || (held.entries.size < SHORT && !held.unread) -> out(Status.REMOVED, next.v.createdAt, true)
                newerUnread || held.unread -> out(Status.UNSURE, next.v.createdAt, false)
                held.v.id !in run || next.v.id !in run ->
                    if (wipedBy(held, next)) out(Status.LOST, next.v.createdAt, true) else out(Status.UNSURE, next.v.createdAt, false)
                else -> wipeOf(timeline, i, row.key, ok, memo)?.let { out(Status.LOST, it.v.createdAt, true) }
                    ?: out(Status.REMOVED, next.v.createdAt, false)
            }
        }
    }

    /**
     * Before a merge: open the private parts still locked in every version as new
     * as the oldest ticked one or newer. Those may have removed or hidden a ticked
     * entry, so without them "removed on purpose stays out" can't be told. Runs on
     * the Merge tap, so signer prompts only follow a tap.
     */
    suspend fun openForMerge(versions: List<Opened>, picked: List<Opened>, opener: Opener): List<Opened> {
        val oldest = picked.minOfOrNull { it.v.createdAt } ?: return versions
        return versions.map { if (it.locked && it.v.createdAt >= oldest) openVersion(it.v, opener) else it }
    }

    data class Tags(val tags: List<List<String>>, val privateTags: List<List<String>>)

    /** The new list: the current version's own tags (d, title, …) first, then each ticked public row; ticked private rows apart. */
    fun mergedTags(rows: List<Row>, current: Opened?): Tags {
        val tags = current?.v?.tags.orEmpty().filter { it.isNotEmpty() && isMeta(it) }.toMutableList()
        val privateTags = mutableListOf<List<String>>()
        for (row in rows) if (row.ticked) (if (row.private) privateTags else tags) += row.tag
        return Tags(tags, privateTags)
    }

    /** What a mute merge mutes again, by type (Hal's point 11: not only people). */
    data class Remutes(val people: Int = 0, val words: Int = 0, val hashtags: Int = 0, val threads: Int = 0) {
        val isEmpty: Boolean get() = people + words + hashtags + threads == 0
    }

    /**
     * [leftOut]: dropped in an ordinary edit and left unticked; [unsure]: can't be told
     * whether the person took them out, left unticked.
     */
    data class Summary(val total: Int, val added: Int, val removed: Int, val leftOut: Int, val unsure: Int, val remutes: Remutes) {
        /**
         * The Review link shows whenever there is something to look at: what Save changes, and
         * also what was left out unticked, since the summary's lines send those to Review to tick
         * ("Nothing to bring back" with 33 unsure had no way in; Logen 2026-11-04). iOS twin:
         * `ListVersionMerge.Summary.showsReview`.
         */
        val showsReview: Boolean get() = added > 0 || removed > 0 || leftOut + unsure > 0
    }

    /** What Save would add and remove, what stays out, and what a mute list would mute again (said before Save). */
    fun mergeSummary(kind: Int, rows: List<Row>): Summary {
        val ticked = rows.filter { it.ticked }
        val added = ticked.filter { it.status != Status.CURRENT }
        fun of(t: String) = if (kind == 10000) added.count { it.tag.firstOrNull() == t } else 0
        return Summary(
            total = ticked.size,
            added = added.size,
            removed = rows.count { it.status == Status.CURRENT && !it.ticked },
            leftOut = rows.count { it.status == Status.REMOVED && !it.ticked },
            unsure = rows.count { it.status == Status.UNSURE && !it.ticked },
            remutes = Remutes(of("p"), of("word"), of("t"), of("e")),
        )
    }

    private fun plural(n: Int, noun: String) = when {
        n == 1 -> noun
        Regex("[^aeiou]y$").containsMatchIn(noun) -> noun.dropLast(1) + "ies"
        else -> noun + "s"
    }

    /** A version's one-line summary against the list now: "+340 follows, −2", "Same as now". */
    fun deltaLine(kind: Int, delta: Delta): String {
        val (added, removed) = delta
        if (added == 0 && removed == 0) return "Same as now"
        val noun = mergeKind(kind)?.noun ?: "entry"
        val parts = mutableListOf<String>()
        if (added > 0) parts += "+$added ${plural(added, noun)}"
        if (removed > 0) parts += if (added > 0) "−$removed" else "−$removed ${plural(removed, noun)}"
        return parts.joinToString(", ")
    }
}
