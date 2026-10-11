package com.nostrvault.ui.navigation

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
