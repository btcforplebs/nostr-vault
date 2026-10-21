package com.nostrvault.ui.screens.profile

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.merge
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.joinAll
import kotlinx.coroutines.launch
import kotlinx.coroutines.plus

/**
 * Which section tabs a profile shows, as the loaders finish
 * ([ProfileLateTabs] decides). Owned by [ProfileViewModel].
 *
 * The extras loader runs its fetches in [extrasScope], so the end of a load
 * is the end of that scope's children: [ProfileExtrasLoader] itself says
 * nothing about when it is done.
 */
internal class ProfileTabReveal(private val scope: CoroutineScope) {
    private val extrasJobs = SupervisorJob(scope.coroutineContext[Job])
    /** Where [ProfileExtrasLoader] launches its fetches. */
    val extrasScope: CoroutineScope = scope + extrasJobs
    private val extrasLoading = MutableStateFlow(false)
    private var extrasToken = 0

    /** The Profile tab, not a profile opened from a note or a list (iOS MyProfileView). */
    val opensAsTab = MutableStateFlow(false)
    private val revealed = MutableStateFlow<Set<ProfileSection>>(emptySet())

    /** The section tabs on show, in order. */
    val visible: StateFlow<List<ProfileSection>> =
        combine(revealed, opensAsTab, ProfileLateTabs::visible)
            .stateIn(scope, SharingStarted.Eagerly, ProfileLateTabs.visible(emptySet(), false))

    private lateinit var loaded: () -> ProfileLateTabs.Loaded
    private lateinit var selected: MutableStateFlow<ProfileSection>

    /** Watches the loaders and moves [selected] off a tab that goes; call once, after they exist. */
    fun bind(
        selected: MutableStateFlow<ProfileSection>,
        articles: StateFlow<List<*>>,
        reels: StateFlow<List<*>>,
        tracks: StateFlow<List<*>>,
        shopLoading: StateFlow<Boolean>,
        listings: StateFlow<List<*>>,
    ) {
        this.selected = selected
        loaded = {
            ProfileLateTabs.Loaded(
                extrasLoading = extrasLoading.value,
                hasArticles = articles.value.isNotEmpty(),
                hasReels = reels.value.isNotEmpty(),
                hasTracks = tracks.value.isNotEmpty(),
                shopLoading = shopLoading.value,
                hasListings = listings.value.isNotEmpty(),
            )
        }
        scope.launch {
            merge(extrasLoading, articles, reels, tracks, shopLoading, listings, opensAsTab).collect { update() }
        }
    }

    /** Call just before the extras loader's `load`. */
    fun extrasLoadStarting() {
        extrasLoading.value = true
    }

    /** Call just after the extras loader's `load`: done once what it started is. */
    fun extrasLoadStarted() {
        val running = extrasJobs.children.toList()
        val token = ++extrasToken
        scope.launch {
            running.joinAll()
            if (token == extrasToken) extrasLoading.value = false
        }
    }

    /** Another person: none of the last one's tabs. Call after their loads have started. */
    fun reset() {
        revealed.value = emptySet()
        if (::loaded.isInitialized) update()
    }

    private fun update() {
        val next = ProfileLateTabs.reveal(revealed.value, loaded())
        revealed.value = next
        selected.value = ProfileLateTabs.selection(selected.value, ProfileLateTabs.visible(next, opensAsTab.value))
    }
}
