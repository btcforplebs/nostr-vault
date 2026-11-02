package com.nostrvault.ui.screens.settings.listbackup

import com.nostrvault.service.ListHistory
import com.nostrvault.service.ListShrinkRule
import com.nostrvault.service.ListVersion
import com.nostrvault.service.ListVersionMerge

/**
 * The words on the list versions, restore and merge screens (Logen 2026-11-02: who saved each version, people
 * by name, "Will follow again" rather than "Comes back", merge explained). Screen text only: no rule lives here.
 * Same strings as the iOS/Mac and web list version screens.
 */
internal object ListVersionText {
    const val UNKNOWN_APP = "An unknown app"

    /** The app that saved a version: its first non-blank `client` tag (NIP-89), else "An unknown app". */
    fun appName(tags: List<List<String>>): String =
        tags.firstOrNull { it.size >= 2 && it[0] == "client" && it[1].isNotBlank() }?.get(1)?.trim() ?: UNKNOWN_APP

    /** The same mid-sentence: "Primal", "an unknown app". */
    fun appInSentence(tags: List<List<String>>): String = appName(tags).let { if (it == UNKNOWN_APP) "an unknown app" else it }

    /** A version's first line: "Primal, 2 Nov 2026, 10:38". */
    fun title(v: ListVersion): String = "${appName(v.tags)}, ${ListBackupFormat.date(v.createdAt)}"

    /** How many entries, in the list's own word: "300 follows", "12 muted", "4 relays". */
    fun count(v: ListVersion): String {
        val n = ListShrinkRule.itemCount(v)
        val base = when (v.kind) {
            3 -> if (n == 1) "1 follow" else "$n follows"
            10000 -> "$n muted"
            else -> ListVersionMerge.mergeKind(v.kind)?.noun?.let { "$n ${plural(n, it)}" }
        } ?: return ListBackupFormat.count(v)
        return if (v.kind in ListShrinkRule.encryptedKinds && v.content.isNotEmpty()) "$base + private" else base
    }

    /** What a version changed against the one just older than it: "+3, −709", "no change", or null for the oldest. */
    fun change(v: ListVersion, older: ListVersion?): String? {
        older ?: return null
        val (added, removed) = ListHistory.diff(v, older)
        val parts = buildList {
            if (added.isNotEmpty()) add("+${added.size}")
            if (removed.isNotEmpty()) add("−${removed.size}")
        }
        return if (parts.isEmpty()) "no change" else parts.joinToString(", ")
    }

    /** A version's second line: "300 follows, −709". */
    fun detail(v: ListVersion, older: ListVersion?): String = listOfNotNull(count(v), change(v, older)).joinToString(", ")

    const val WIPED = "This one wiped your list"

    /** The section of entries a restore or merge brings back. */
    fun willAdd(kind: Int): String = when (kind) {
        3 -> "Will follow again"
        10000 -> "Will mute again"
        else -> "Will add back"
    }

    /** The section of entries a restore takes out. */
    fun willRemove(kind: Int): String = when (kind) {
        3 -> "Will unfollow"
        10000 -> "Will unmute"
        else -> "Will remove"
    }

    /** Merge review: the entries of the list now. */
    fun stillIn(kind: Int): String = when (kind) {
        3 -> "Still following"
        10000 -> "Still muted"
        else -> "Already in your list"
    }

    const val RESTORE_LINE = "Restore: tap a version below. Your list becomes exactly that version."

    /** The merge entry's line: what merge does, against restore. */
    fun mergeBlurb(kind: Int): String =
        if (kind == 3) "Keeps everyone you follow now and adds back people older versions had."
        else "Keeps everything in your list now and adds back what older versions had."

    /** The merge confirm's first line for follows; null for other lists (they keep the generic line). */
    fun followConfirm(kind: Int, added: Int, removed: Int): String? {
        if (kind != 3) return null
        val off = if (removed > 0) ", $removed unfollowed" else ""
        return "Saves your follows: you follow $added again$off."
    }

    /** The person an entry key ("p\u0000<hex>") or tag (["p", hex]) names, lowercased hex, or null. */
    fun personKey(key: String): String? {
        val parts = key.split('\u0000', limit = 2)
        return parts.takeIf { it.size == 2 && it[0] == "p" }?.get(1)?.lowercase()?.takeIf(::isHex)
    }

    fun personTag(tag: List<String>): String? =
        tag.takeIf { it.size >= 2 && it[0] == "p" }?.get(1)?.lowercase()?.takeIf(::isHex)

    private fun isHex(s: String) = s.length == 64 && s.all { it in '0'..'9' || it in 'a'..'f' }

    private fun plural(n: Int, noun: String) = when {
        n == 1 -> noun
        noun.endsWith("y") && noun.length > 1 && noun[noun.length - 2] !in "aeiou" -> noun.dropLast(1) + "ies"
        else -> noun + "s"
    }
}
