package com.nostrvault.ui.navigation

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/**
 * Which part of the Vault tab is showing: the "Vault" list (everything new,
 * in one list), the relay's lists (Notes, Articles, Highlights, Likes, Zaps,
 * Followers) or the Blossom media gallery. Outside the tab so a deep link, a
 * notification or a tutorial can pick before the tab exists. A fresh launch
 * opens on "Vault", as iOS's Vault tab does (#506).
 *
 * The tab saves its part in its instance state, so when Android kills the
 * app (say behind the photo picker opened from Media) it comes back where it
 * was and the picked files reach the gallery. An explicit pick (a
 * notification, a link, a tutorial, the pill) always wins over that saved
 * copy, whether it came before the restore or after.
 */
object VaultSection {
    private val _showsMedia = MutableStateFlow(false)
    val showsMedia: StateFlow<Boolean> = _showsMedia

    private val _showsActivity = MutableStateFlow(true)
    /** The "Vault" list is showing (when Media is not). */
    val showsActivity: StateFlow<Boolean> = _showsActivity

    private val _opensNewActivity = MutableStateFlow(false)
    /**
     * Set when you tap into the Vault tab while its red dot shows: the tab
     * then opens the list the dot is for, instead of whichever one you left
     * it on (iOS VaultSection.opensNewActivity, #476).
     */
    val opensNewActivity: StateFlow<Boolean> = _opensNewActivity

    fun requestOpenNewActivity() { _opensNewActivity.value = true }

    fun openedNewActivity() { _opensNewActivity.value = false }

    /**
     * The Vault Dashboard opened a page (a setting, Relay activity), so back
     * from it reopens the dashboard over the part of the tab it sat on.
     * Null when the dashboard sent you nowhere, or you have since moved on.
     */
    data class DashboardTrip(
        /** The part the tab showed under the dashboard, put back on return. */
        val media: Boolean,
        val activity: Boolean,
    )

    private val _dashboardTrip = MutableStateFlow<DashboardTrip?>(null)
    val dashboardTrip: StateFlow<DashboardTrip?> = _dashboardTrip

    /** The dashboard is about to open a page; back from it reopens the dashboard. */
    fun leaveDashboardForPage() {
        _dashboardTrip.value = DashboardTrip(media = _showsMedia.value, activity = _showsActivity.value)
    }

    /**
     * Back reached the dashboard's trip: the tab is on its old part again and
     * the trip is over. False when there was none, so back does what it would.
     */
    fun returnToDashboard(): Boolean {
        val trip = _dashboardTrip.value ?: return false
        _dashboardTrip.value = null
        chosen = true
        _showsMedia.value = trip.media
        _showsActivity.value = trip.activity && !trip.media
        return true
    }

    /** Something chose a part in this process; a restored copy is older than it. */
    @Volatile private var chosen = false

    /** Media, or the relay's lists (leaving "Vault"). */
    fun show(media: Boolean) {
        chosen = true
        _dashboardTrip.value = null
        _showsActivity.value = false
        _showsMedia.value = media
    }

    /** The "Vault" list. */
    fun showActivity() {
        chosen = true
        _dashboardTrip.value = null
        _showsMedia.value = false
        _showsActivity.value = true
    }

    /**
     * Off Media, back to whichever list the tab had: "Vault" or the relay
     * list it was on. For a tap that names the tab but no list.
     */
    fun leaveMedia() {
        chosen = true
        _dashboardTrip.value = null
        _showsMedia.value = false
    }

    /**
     * The part saved before the process was killed. Ignored once anything in
     * this process chose one; a choice made after it simply replaces it.
     */
    fun restore(media: Boolean, activity: Boolean = false) {
        if (chosen) return
        chosen = true
        _showsMedia.value = media
        _showsActivity.value = activity && !media
    }

    /** Tests only: a fresh process. */
    internal fun resetForTest() {
        chosen = false
        _showsMedia.value = false
        _showsActivity.value = true
        _opensNewActivity.value = false
        _dashboardTrip.value = null
    }
}
