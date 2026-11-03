package com.nostrvault.ui.navigation

import androidx.navigation.NavGraphBuilder
import androidx.navigation.NavHostController
import androidx.navigation.compose.composable
import com.nostrvault.ui.screens.shareportal.SharePortalReviewScreen

/** The share portal's review card (`nostrvault://shareportal`). */
internal fun NavGraphBuilder.sharePortalRoutes(
    navController: NavHostController,
) {
    composable(Screen.SharePortalReview.route) {
        SharePortalReviewScreen(
            onBack = { navController.popBackStack() },
            // The composer replaces the review card, so Back from it leaves both.
            onOpenEditor = { kind, draftId ->
                navController.navigate(Screen.ModeCompose.createRoute(kind, draftId)) {
                    popUpTo(Screen.SharePortalReview.route) { inclusive = true }
                }
            },
        )
    }
}
