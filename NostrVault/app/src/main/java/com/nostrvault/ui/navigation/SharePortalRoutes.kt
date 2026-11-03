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
        SharePortalReviewScreen(onBack = { navController.popBackStack() })
    }
}
