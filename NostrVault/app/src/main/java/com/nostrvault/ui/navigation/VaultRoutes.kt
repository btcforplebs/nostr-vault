package com.nostrvault.ui.navigation

import androidx.activity.compose.BackHandler
import androidx.compose.runtime.*
import androidx.navigation.NavGraphBuilder
import androidx.navigation.NavHostController
import androidx.navigation.compose.composable
import com.nostrvault.relay.LogStore
import com.nostrvault.service.FeedService
import com.nostrvault.ui.screens.*
import com.nostrvault.ui.screens.dashboard.LogViewerScreen
import com.nostrvault.ui.screens.dashboard.RelayActivityScreen

/** The Vault tab and its relay logs, lifted from [NostrVaultNavHost]. */
internal fun NavGraphBuilder.vaultRoutes(
    navController: NavHostController,
    logStore: LogStore,
    feedService: FeedService,
    unreadDMsState: State<Int>,
) {
    val unreadDMs by unreadDMsState

    // ── Vault ─────────────────────────────────────────────
    composable(Screen.Dashboard.route) {
        VaultBack(feedService)
        VaultTabScreen(
            onNavigate = { screen -> navController.navigate(screen.route) },
            onNoteClick = { noteId ->
                navController.navigate(Screen.NoteDetail.createRoute(noteId))
            },
            onArticleClick = { noteId ->
                navController.navigate(Screen.ArticleReader.createRoute(noteId))
            },
            onProfileClick = { pubkey ->
                navController.navigate(Screen.Profile.createRoute(pubkey))
            },
            onMediaClick = { index ->
                navController.navigate(Screen.MediaViewer.createRoute(index))
            },
            logStore = logStore,
            feedService = feedService,
            unreadDMs = unreadDMs,
        )
    }

    composable(Screen.RelayActivity.route) {
        val currentLogs by logStore.logs.collectAsState()
        RelayActivityScreen(
            logs = currentLogs,
            onBack = { navController.popBackStack() },
            onOpenFullLogs = { navController.navigate(Screen.LogViewer.route) },
        )
    }

    composable(Screen.LogViewer.route) {
        val currentLogs by logStore.logs.collectAsState()
        LogViewerScreen(
            logs = currentLogs,
            onBack = { navController.popBackStack() },
        )
    }
}

/**
 * Back on the Vault tab comes home to the Vault Dashboard, then the tab's
 * "Vault" list, before it leaves the tab:
 * - back from a page the dashboard opened (this route coming back on
 *   screen) reopens the dashboard over the part it sat on;
 * - back from any other list (Notes, Media, …) goes to the "Vault" list.
 * Composed before the tab, so the tab's own back handlers (a selection, a
 * search) still go first.
 */
@Composable
private fun VaultBack(feedService: FeedService) {
    val showsActivity by VaultSection.showsActivity.collectAsState()
    var reopen by remember { mutableIntStateOf(0) }

    // Entering composition is the pop back from a pushed page.
    LaunchedEffect(Unit) {
        if (VaultSection.returnToDashboard()) reopen++
    }
    LaunchedEffect(reopen) {
        if (reopen == 0) return@LaunchedEffect
        // The tab starts listening in the same frame; a request sent before
        // it does is dropped, so send it on the next one.
        withFrameNanos { }
        feedService.requestRelayDashboard()
    }

    BackHandler(enabled = !showsActivity) { VaultSection.showActivity() }
}
