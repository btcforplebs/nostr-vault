package com.nostrvault.ui.navigation

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/**
 * Which half of the Vault tab is showing: the relay's lists (Notes, Articles,
 * Highlights, Likes, Zaps, Followers) or the Blossom media gallery. Outside
 * the tab so a deep link, a notification or a tutorial can pick the half
 * before the tab exists. Not saved: the tab opens on the relay half, as iOS's
 * VaultSection does.
 */
object VaultSection {
    private val _showsMedia = MutableStateFlow(false)
    val showsMedia: StateFlow<Boolean> = _showsMedia

    fun show(media: Boolean) { _showsMedia.value = media }
}
