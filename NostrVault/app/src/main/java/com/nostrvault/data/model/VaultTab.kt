package com.nostrvault.data.model

/**
 * The Vault tab: what used to be the Media and Relay tabs, in one, with a
 * dropdown pill to switch between its lists. Pure logic, kept free of Android
 * types so unit tests can pin it. Port of iOS VaultTabView.swift and
 * Models/VaultNoteScope.swift (#443).
 */

/**
 * Which kind of post the Notes list shows. The relay keeps every kind you
 * publish; the Relay tab used to list articles and highlights mixed into
 * Notes. In the Vault tab each gets its own entry in the mode menu.
 */
enum class VaultNoteScope {
    /** Notes, reposts, comments and polls: everything but the two below. */
    NOTES,
    /** Long-form posts (kind 30023). Recipes are articles with a cooking tag. */
    ARTICLES,
    /** NIP-84 highlights (kind 9802). */
    HIGHLIGHTS;

    /** The kinds this scope lists, out of [all] (the relay tab's note kinds). */
    fun kinds(all: Set<Int>): Set<Int> = when (this) {
        NOTES -> all - ARTICLE_KIND - HIGHLIGHT_KIND
        ARTICLES -> setOf(ARTICLE_KIND)
        HIGHLIGHTS -> setOf(HIGHLIGHT_KIND)
    }

    /**
     * Articles and Highlights are a few rows among many notes. Their list's
     * end is always on screen, so loading older pages on sight would walk the
     * whole relay; they page with a "Load older" button instead.
     */
    val pagesByButton: Boolean get() = this != NOTES

    companion object {
        const val ARTICLE_KIND = 30023
        const val HIGHLIGHT_KIND = 9802

        /** The `t` tags that make an article a recipe (zap.cooking and friends). */
        val RECIPE_TOPICS = setOf("zapcooking", "nostrcooking")

        /** Whether an article's tags mark it as a recipe. */
        fun isRecipe(tags: List<List<String>>): Boolean =
            tags.any { it.size >= 2 && it[0] == "t" && it[1].lowercase() in RECIPE_TOPICS }

        /** The list that holds a post of [kind]: a notification tap lands there. */
        fun forKind(kind: Int?): VaultNoteScope = when (kind) {
            ARTICLE_KIND -> ARTICLES
            HIGHLIGHT_KIND -> HIGHLIGHTS
            else -> NOTES
        }
    }
}

/** The Vault tab's modes, in menu order. */
enum class VaultMode(val displayName: String) {
    NOTES("Notes"),
    ARTICLES("Articles"),
    HIGHLIGHTS("Highlights"),
    MEDIA("Media"),
    LIKES("Likes"),
    ZAPS("Zaps"),
    FOLLOWERS("Followers");

    /** The note scope this mode shows; null for modes that aren't a notes list. */
    val noteScope: VaultNoteScope?
        get() = when (this) {
            NOTES -> VaultNoteScope.NOTES
            ARTICLES -> VaultNoteScope.ARTICLES
            HIGHLIGHTS -> VaultNoteScope.HIGHLIGHTS
            else -> null
        }

    /** The relay half's list this mode shows; null for Media. */
    val viewMode: VaultViewMode?
        get() = when (this) {
            NOTES, ARTICLES, HIGHLIGHTS -> VaultViewMode.NOTES
            LIKES -> VaultViewMode.LIKES
            ZAPS -> VaultViewMode.ZAPS
            FOLLOWERS -> VaultViewMode.FOLLOWERS
            MEDIA -> null
        }

    companion object {
        /** The menu's modes. Zaps Only hides Likes, as it hides the Likes list. */
        fun menu(zapsOnly: Boolean): List<VaultMode> = entries.filter { !(zapsOnly && it == LIKES) }

        /** The menu entry for what the tab is showing. */
        fun of(showsMedia: Boolean, viewMode: VaultViewMode, scope: VaultNoteScope): VaultMode = when {
            showsMedia -> MEDIA
            viewMode == VaultViewMode.LIKES -> LIKES
            viewMode == VaultViewMode.ZAPS -> ZAPS
            viewMode == VaultViewMode.FOLLOWERS -> FOLLOWERS
            else -> when (scope) {
                VaultNoteScope.NOTES -> NOTES
                VaultNoteScope.ARTICLES -> ARTICLES
                VaultNoteScope.HIGHLIGHTS -> HIGHLIGHTS
            }
        }
    }
}

/** The pill's red dot: something new in a list you aren't looking at. */
object VaultDots {
    /**
     * The list in sight, for the new-activity dots. Null while the Vault tab
     * shows Media, Articles or Highlights: none of the dotted lists is on
     * screen then, so nothing may be marked seen.
     */
    fun watchedMode(showsMedia: Boolean, viewMode: VaultViewMode, scope: VaultNoteScope): VaultViewMode? = when {
        showsMedia -> null
        viewMode == VaultViewMode.NOTES && scope != VaultNoteScope.NOTES -> null
        else -> viewMode
    }

    /** Something new in a mode other than [current]: the pill's dot, on either half. */
    fun hasNewElsewhere(newModes: Set<VaultMode>, current: VaultMode): Boolean = (newModes - current).isNotEmpty()

    /**
     * What the pill shows as new: the lit event lists, plus Followers. Likes
     * never shows in Zaps Only mode, which hides it, even if it lit before
     * the mode came on.
     */
    fun shown(lit: Set<VaultViewMode>, newFollowers: Boolean, zapsOnly: Boolean): Set<VaultMode> =
        lit.filterNot { zapsOnly && it == VaultViewMode.LIKES }
            .mapTo(HashSet()) { VaultMode.of(false, it, VaultNoteScope.NOTES) }
            .apply { if (newFollowers) add(VaultMode.FOLLOWERS) }

    /** The lists whose dot comes from their events. Followers' comes from the relay's ledger. */
    val eventLists = listOf(VaultViewMode.NOTES, VaultViewMode.LIKES, VaultViewMode.ZAPS)

    /**
     * The kinds each dotted list holds: Notes' kinds less articles and
     * highlights (they get no dot), likes, zap receipts.
     */
    fun kinds(list: VaultViewMode, noteKinds: Set<Int>): Set<Int> = when (list) {
        VaultViewMode.NOTES -> VaultNoteScope.NOTES.kinds(noteKinds)
        VaultViewMode.LIKES -> setOf(7)
        VaultViewMode.ZAPS -> setOf(9735)
        VaultViewMode.FOLLOWERS -> emptySet()
    }

    /**
     * The newest created_at in each dotted list, out of (kind, created_at)
     * pairs; 0 for an empty list. Future-dated events are left out, or one
     * would hold a list's dot dark until its date.
     *
     * iOS compares event counts. Android keeps a watermark instead: the store
     * here is trimmed at a cap, so a new event can leave the count unchanged,
     * and an older page loading would read as news.
     */
    fun newest(events: Iterable<Pair<Int, Long>>, noteKinds: Set<Int>, nowSecs: Long): Map<VaultViewMode, Long> {
        val listByKind = HashMap<Int, VaultViewMode>()
        for (list in eventLists) for (kind in kinds(list, noteKinds)) listByKind[kind] = list
        val newest = eventLists.associateWithTo(HashMap()) { 0L }
        for ((kind, createdAt) in events) {
            val list = listByKind[kind] ?: continue
            if (createdAt > nowSecs + 60) continue
            if (createdAt > newest.getValue(list)) newest[list] = createdAt
        }
        return newest
    }

    /**
     * The lists holding something newer than when you last looked. Nothing
     * lights before the first load has settled ([seenAt] empty), the list in
     * sight never does, and Likes stays dark in Zaps Only mode, which hides it.
     */
    fun lit(
        newest: Map<VaultViewMode, Long>,
        seenAt: Map<VaultViewMode, Long>,
        watched: VaultViewMode?,
        zapsOnly: Boolean,
    ): Set<VaultViewMode> = eventLists.filterTo(HashSet()) { list ->
        val seen = seenAt[list] ?: return@filterTo false
        list != watched && !(zapsOnly && list == VaultViewMode.LIKES) && (newest[list] ?: 0L) > seen
    }
}

/**
 * Where an Articles or Highlights "Load older" page starts. These lists page
 * on their own, apart from Notes, with one cursor per query (your posts from
 * the outbox, posts tagging you from the inbox), so a dense query can't make
 * a sparse one skip what lies between.
 *
 * [until] is the `until` of the next request, in seconds; [done] means the
 * last page came back empty: there is nothing older to load.
 */
data class VaultPageCursor(val until: Long, val done: Boolean = false) {
    /**
     * After a page came back holding events created at [returned]. An empty
     * page ends paging. The cursor only ever moves back in time, so a relay
     * returning something newer than asked can't send it round again.
     */
    fun after(returned: List<Long>): VaultPageCursor {
        val oldest = returned.minOrNull() ?: return copy(done = true)
        return VaultPageCursor(until = minOf(until, oldest - 1))
    }

    companion object {
        /**
         * The first page: just older than the oldest of the kind already
         * loaded ([loaded], seconds), or from [nowSeconds] when none is.
         */
        fun start(loaded: List<Long>, nowSeconds: Long): VaultPageCursor =
            VaultPageCursor(until = (loaded.minOrNull()?.minus(1)) ?: nowSeconds)
    }
}
