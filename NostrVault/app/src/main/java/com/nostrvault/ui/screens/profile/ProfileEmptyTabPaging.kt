package com.nostrvault.ui.screens.profile

/**
 * The opening load is the newest notes, so a tab can be empty while older
 * pages still hold some (replies, reposts, media). An empty tab pages back on
 * its own, up to [cap] pages, so a tab that is empty for good (someone who
 * never reposts) cannot walk the whole archive by itself; past the cap it
 * offers "Look further back". Port of iOS ProfileFeedLoader.autoPageEmptyTab.
 */
class ProfileEmptyTabPaging(private val cap: Int = AUTO_PAGE_CAP) {
    private val spent = mutableMapOf<ProfileSection, Int>()

    /**
     * True when [section] should page back now, and counts the page against
     * its cap. Asked again each time a page finishes, so a tab chosen while
     * another tab's page was loading still gets its turn.
     */
    @Synchronized
    fun claim(section: ProfileSection, isEmpty: Boolean, canPageOlder: Boolean, isLoadingOlder: Boolean): Boolean {
        if (!isEmpty || !canPageOlder || isLoadingOlder) return false
        val n = spent[section] ?: 0
        if (n >= cap) return false
        spent[section] = n + 1
        return true
    }

    /** A new profile, or a refresh: every tab gets its automatic pages again. */
    @Synchronized
    fun reset() = spent.clear()

    /** What an empty tab says. */
    enum class Status { LOADING, OLDER_LEFT, NONE }

    companion object {
        const val AUTO_PAGE_CAP = 8

        /**
         * "Loading…" while the opening load or a page runs; "None in the
         * latest posts" with "Look further back" while older pages are left;
         * "No replies yet" only once nothing older is left.
         */
        fun status(opening: Boolean, pagingNow: Boolean, canPageOlder: Boolean): Status = when {
            opening || pagingNow -> Status.LOADING
            canPageOlder -> Status.OLDER_LEFT
            else -> Status.NONE
        }
    }
}
