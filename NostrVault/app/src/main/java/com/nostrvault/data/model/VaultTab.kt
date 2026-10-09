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
