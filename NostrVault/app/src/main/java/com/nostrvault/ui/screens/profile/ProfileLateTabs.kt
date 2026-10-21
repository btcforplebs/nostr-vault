package com.nostrvault.ui.screens.profile

/**
 * The profile tabs that only show when there is something in them: Articles,
 * diVines and Music (from [ProfileExtrasLoader]) and Shop. Port of iOS
 * `ProfileContent.revealLateSections` / `visibleSections`
 * (ProfileContent+Sections.swift).
 *
 * The late tabs come in together, once their loader has finished, rather
 * than one by one as each answer lands; a tab already on show stays while a
 * refresh runs. If the tab you are on goes away, you are put back on Notes.
 */
internal object ProfileLateTabs {
    /** The tabs [ProfileExtrasLoader] fills. */
    val EXTRAS: Set<ProfileSection> = setOf(ProfileSection.ARTICLES, ProfileSection.DIVINES, ProfileSection.MUSIC)

    /** What the loaders hold right now. */
    data class Loaded(
        val extrasLoading: Boolean,
        val hasArticles: Boolean,
        val hasReels: Boolean,
        val hasTracks: Boolean,
        val shopLoading: Boolean,
        val hasListings: Boolean,
    )

    /** The late tabs to show after [loaded], starting from those on show now. */
    fun reveal(current: Set<ProfileSection>, loaded: Loaded): Set<ProfileSection> {
        val next = current.toMutableSet()
        if (!loaded.extrasLoading) {
            next.removeAll(EXTRAS)
            if (loaded.hasArticles) next += ProfileSection.ARTICLES
            if (loaded.hasReels) next += ProfileSection.DIVINES
            if (loaded.hasTracks) next += ProfileSection.MUSIC
        }
        if (!loaded.shopLoading) {
            if (loaded.hasListings) next += ProfileSection.SHOP else next -= ProfileSection.SHOP
        }
        return next
    }

    /**
     * The tabs in order. Shop is always there on the Profile tab, where it
     * holds the Sell button (iOS `shopAlwaysVisible`), and otherwise only
     * once revealed, like the other late tabs.
     */
    fun visible(revealed: Set<ProfileSection>, shopAlwaysVisible: Boolean): List<ProfileSection> =
        ProfileSection.entries.filter { section ->
            when (section) {
                ProfileSection.SHOP -> shopAlwaysVisible || section in revealed
                in EXTRAS -> section in revealed
                else -> true
            }
        }

    /** [selected], or Notes when it is no longer among [visible]. */
    fun selection(selected: ProfileSection, visible: List<ProfileSection>): ProfileSection =
        if (selected in visible) selected else ProfileSection.NOTES
}
