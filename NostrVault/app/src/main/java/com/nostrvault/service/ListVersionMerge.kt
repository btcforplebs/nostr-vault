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
     * 2026-10-31) and not the addressable sets (one list per `d`).
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

    /** Kinds whose content is never a private part: kind 3 keeps relay hints there. */
    private val noPrivate = setOf(3)
    private val urlTags = mapOf(10050 to "relay", 10006 to "relay", 10007 to "relay", 10063 to "server")
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

    enum class Status { CURRENT, LOST, REMOVED, BACK }

    /** One merged entry with its tick. [at]: when it was lost or removed, else 0. [from]: the versions holding it. */
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
     * The merge: every entry of [current] and of each version in [picked], each
     * once. [all] is every version found (opened), for what happened to an entry
     * after the newest version that held it:
     * - CURRENT: in the list now, ticked;
     * - LOST: the next version was a wipe ([ListShrinkRule.shrank]), ticked, `at` = when;
     * - REMOVED: the next version was an ordinary edit, so the person took it out: unticked, `at` = when;
     * - BACK: no later version is known, ticked.
     * A row is private when any version ever held it privately, or (not in the list
     * now) a newer version whose private part wasn't read may: hiding a public
     * entry loses nothing, publishing a hidden one can't be undone. Its tag is the
     * current version's, else the newest picked one's. Order: the current list's,
     * then what comes back, newest version first.
     */
    fun buildMerge(current: Opened?, picked: List<Opened>, all: List<Opened>): List<Row> {
        val sources = listOfNotNull(current) + picked.filter { it.v.id != current?.v?.id }.sortedWith(newestFirst)
        val timeline = all.sortedWith(newestFirst)
        class Acc(val key: String, val tag: List<String>, var private: Boolean, val from: MutableList<String>)
        val rows = LinkedHashMap<String, Acc>()
        for (src in sources) for ((key, e) in src.entries) {
            val row = rows[key]
            if (row != null) { row.private = row.private || e.private; row.from += src.v.id; continue }
            rows[key] = Acc(key, e.tag, e.private, mutableListOf(src.v.id))
        }
        for (row in rows.values) {
            if (all.any { it.entries[row.key]?.private == true }) { row.private = true; continue }
            if (current?.entries?.containsKey(row.key) == true) continue
            val i = timeline.indexOfFirst { it.entries.containsKey(row.key) }
            val newer = timeline.subList(0, if (i < 0) timeline.size else i)
            if (newer.any { it.v.kind !in noPrivate && it.unread }) row.private = true
        }
        return rows.values.map { row ->
            fun out(status: Status, at: Long, ticked: Boolean) = Row(row.key, row.tag, row.private, status, at, ticked, row.from)
            if (current?.entries?.containsKey(row.key) == true) return@map out(Status.CURRENT, 0, true)
            // The newest version holding it, then the one that replaced that.
            val i = timeline.indexOfFirst { it.entries.containsKey(row.key) }
            val next = if (i > 0) timeline[i - 1] else null
            when {
                next == null -> out(Status.BACK, 0, true)
                ListShrinkRule.shrank(timeline[i].v, next.v) -> out(Status.LOST, next.v.createdAt, true)
                // The next version's private part unread: whether it still held the entry isn't known.
                next.unread && row.private -> out(Status.BACK, 0, true)
                else -> out(Status.REMOVED, next.v.createdAt, false)
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

    data class Summary(val total: Int, val added: Int, val removed: Int, val remutes: Int)

    /** What Save would add and remove, and how many people a mute list would mute again (said before Save). */
    fun mergeSummary(kind: Int, rows: List<Row>): Summary {
        val ticked = rows.filter { it.ticked }
        val added = ticked.filter { it.status != Status.CURRENT }
        return Summary(
            total = ticked.size,
            added = added.size,
            removed = rows.count { it.status == Status.CURRENT && !it.ticked },
            remutes = if (kind == 10000) added.count { it.tag.firstOrNull() == "p" } else 0,
        )
    }

    private fun plural(n: Int, noun: String) = when {
        n == 1 -> noun
        noun.endsWith("y") -> noun.dropLast(1) + "ies"
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
