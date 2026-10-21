package com.nostrvault.ui.navigation

import androidx.navigation.NavGraphBuilder
import androidx.navigation.NavHostController
import androidx.navigation.compose.composable
import com.nostrvault.ui.screens.*

/**
 * The wallet, lifted from [NostrVaultNavHost], and the on-chain page with its
 * sweep, which only Settings > Advanced opens.
 */
internal fun NavGraphBuilder.walletRoutes(
    navController: NavHostController,
) {
    // ── Wallet ────────────────────────────────────────────
    composable(Screen.Wallet.route) {
        WalletScreen(
            onBack = { navController.popBackStack() },
            onNoteClick = { noteId ->
                navController.navigate(Screen.NoteDetail.createRoute(noteId))
            },
        )
    }

    composable(Screen.WalletSettings.route) {
        WalletScreen(onBack = { navController.popBackStack() }, settingsOnly = true)
    }

    composable(Screen.BitcoinWallet.route) {
        BitcoinWalletScreen(
            onBack = { navController.popBackStack() },
            onSweep = { navController.navigate(Screen.BitcoinSweep.route) },
        )
    }

    composable(Screen.BitcoinSweep.route) {
        BitcoinSweepScreen(
            onBack = { navController.popBackStack() },
        )
    }
}
