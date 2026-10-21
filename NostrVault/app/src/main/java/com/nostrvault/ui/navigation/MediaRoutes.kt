package com.nostrvault.ui.navigation

import androidx.compose.runtime.*
import androidx.navigation.NavGraphBuilder
import androidx.navigation.NavHostController
import androidx.navigation.NavType
import androidx.navigation.compose.composable
import androidx.navigation.navArgument
import com.nostrvault.relay.HavenConfig
import com.nostrvault.ui.screens.*

/** The full-screen media viewer, lifted from [NostrVaultNavHost]. */
internal fun NavGraphBuilder.mediaRoutes(
    navController: NavHostController,
    configState: State<HavenConfig>,
) {
    val config by configState

    // ── Media viewer ──────────────────────────────────────
    composable(
        route = Screen.MediaViewer.route,
        arguments = listOf(navArgument("index") { type = NavType.IntType }),
    ) { entry ->
        val index = entry.arguments?.getInt("index") ?: 0
        MediaViewerScreen(
            initialIndex = index,
            onBack = { navController.popBackStack() },
            // As iOS: View Note closes the viewer, then opens the note.
            onNoteClick = { noteId ->
                navController.popBackStack()
                navController.navigate(Screen.NoteDetail.createRoute(noteId))
            },
            autoplayVideos = config.autoplayVideos,
        )
    }
}
