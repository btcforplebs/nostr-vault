package com.nostrvault.ui.navigation

import androidx.navigation.NavGraphBuilder
import androidx.navigation.NavHostController
import androidx.navigation.compose.composable
import com.nostrvault.ui.screens.*

/** The wallet and its sweep, lifted from [NostrVaultNavHost]. */
internal fun NavGraphBuilder.walletRoutes(
    navController: NavHostController,
) {
    // ── Wallet ────────────────────────────────────────────
    composable(Screen.Wallet.route) {
        WalletScreen(
            onBack = { navController.popBackStack() },
            onSweep = { navController.navigate(Screen.BitcoinSweep.route) },
            onNoteClick = { noteId ->
                navController.navigate(Screen.NoteDetail.createRoute(noteId))
            },
        )
    }

    composable(Screen.BitcoinSweep.route) {
        BitcoinSweepScreen(
            onBack = { navController.popBackStack() },
        )
    }
}
