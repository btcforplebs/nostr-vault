package com.nostrvault.ui.navigation

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/**
 * Which half of the Vault tab is showing: the relay's lists (Notes, Articles,
 * Highlights, Likes, Zaps, Followers) or the Blossom media gallery. Outside
 * the tab so a deep link, a notification or a tutorial can pick the half
 * before the tab exists. A fresh launch opens on the relay half, as iOS's
 * VaultSection does.
 *
 * The tab saves its half in its instance state, so when Android kills the
 * app (say behind the photo picker opened from Media) it comes back on the
 * half it was on and the picked files reach the gallery. An explicit pick
 * (a notification, a link, a tutorial, the pill) always wins over that
 * saved copy, whether it came before the restore or after.
 */
object VaultSection {
    private val _showsMedia = MutableStateFlow(false)
    val showsMedia: StateFlow<Boolean> = _showsMedia

    private val _opensNewActivity = MutableStateFlow(false)
    /**
     * Set when you tap into the Vault tab while its red dot shows: the tab
     * then opens the list the dot is for, instead of whichever one you left
     * it on (iOS VaultSection.opensNewActivity, #476).
     */
    val opensNewActivity: StateFlow<Boolean> = _opensNewActivity

    fun requestOpenNewActivity() { _opensNewActivity.value = true }

    fun openedNewActivity() { _opensNewActivity.value = false }

    /** Something chose a half in this process; a restored copy is older than it. */
    @Volatile private var chosen = false

    fun show(media: Boolean) {
        chosen = true
        _showsMedia.value = media
    }

    /**
     * The half saved before the process was killed. Ignored once anything in
     * this process chose a half; a choice made after it simply replaces it.
     */
    fun restore(media: Boolean) {
        if (chosen) return
        chosen = true
        _showsMedia.value = media
    }

    /** Tests only: a fresh process. */
    internal fun resetForTest() {
        chosen = false
        _showsMedia.value = false
        _opensNewActivity.value = false
    }
}
