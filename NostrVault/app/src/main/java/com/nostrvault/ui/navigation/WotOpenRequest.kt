package com.nostrvault.ui.navigation

import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.navigation.NavHostController
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/**
 * The person "Open in WoT" asked for, from a profile's or a post's globe,
 * kept until the WOT tab's globe takes them: the tab may not be built yet
 * when the request is made. iOS `WOTOpenRequest`.
 */
object WotOpenRequest {
    private val _pending = MutableStateFlow<String?>(null)
    val pending: StateFlow<String?> = _pending

    /** Shows the WOT tab, you in the middle, with [pubkey] picked out and your paths to them lit. */
    fun open(pubkey: String) { _pending.value = pubkey }

    /** The person asked for, once: a recomposition does not pick them out twice. */
    fun take(): String? = _pending.value.also { _pending.value = null }
}

/**
 * Switches to the WOT tab when "Open in WoT" asks, as the bottom bar does,
 * dropping anything stacked on the tab it came from (a profile, a thread).
 * The globe itself closes as it asks.
 */
@Composable
internal fun WotOpenEffect(navController: NavHostController) {
    val pending by WotOpenRequest.pending.collectAsState()
    LaunchedEffect(pending) {
        if (pending == null) return@LaunchedEffect
        navController.navigate(Screen.WOT.route) {
            popUpTo(Screen.Feed.route) { saveState = true }
            launchSingleTop = true
            restoreState = true
        }
        navController.popBackStack(Screen.WOT.route, inclusive = false)
    }
}
