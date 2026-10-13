package com.nostrvault.ui.navigation

import androidx.navigation.NavController

/**
 * The nav host's start route, read once when the host is first composed: the
 * setup wizard on first run, the Feed otherwise. It must not follow the live
 * `hasCompletedSetup` flag: a graph with a different start destination is a
 * different graph to `NavController.setGraph`, which pops the whole back stack
 * and starts over, so finishing the wizard from Settings would land on the Feed.
 */
internal fun setupStartRoute(setupComplete: Boolean): String =
    if (setupComplete) Screen.Feed.route else Screen.SetupWizard.route

/**
 * A finished wizard goes back to the screen it was opened over (Settings'
 * "Setup Incomplete" banner, or wherever a config reset found the user), as
 * iOS dismisses its wizard sheet. On first run it is the start of the app,
 * with nothing behind it, and the Feed replaces it.
 */
internal fun finishSetupWizard(navController: NavController) {
    if (navController.previousBackStackEntry != null) {
        navController.popBackStack()
    } else {
        navController.navigate(Screen.Feed.route) {
            popUpTo(Screen.SetupWizard.route) { inclusive = true }
        }
    }
}

/**
 * Setup going back to unfinished mid-run (a config reset) opens the wizard over
 * where the user is. Only that change does: first run already starts there.
 */
internal fun openSetupWizardIfReset(navController: NavController, wasComplete: Boolean, isComplete: Boolean) {
    if (!wasComplete || isComplete) return
    if (navController.currentDestination?.route == Screen.SetupWizard.route) return
    navController.navigate(Screen.SetupWizard.route)
}
