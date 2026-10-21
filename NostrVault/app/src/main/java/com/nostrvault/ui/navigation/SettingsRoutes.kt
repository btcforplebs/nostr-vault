package com.nostrvault.ui.navigation

import androidx.navigation.NavGraphBuilder
import androidx.navigation.NavHostController
import androidx.navigation.compose.composable
import com.nostrvault.service.NostrService
import com.nostrvault.ui.screens.settings.AccountSettingsScreen
import com.nostrvault.ui.screens.settings.AdvancedSettingsScreen
import com.nostrvault.ui.screens.settings.AppearanceSettingsScreen
import com.nostrvault.ui.screens.settings.FeedSettingsScreen
import com.nostrvault.ui.screens.settings.BackupSettingsScreen
import com.nostrvault.ui.screens.settings.BlockedSettingsScreen
import com.nostrvault.ui.screens.settings.RecentlyDeletedSettingsScreen
import com.nostrvault.ui.screens.settings.BlossomSettingsScreen
import com.nostrvault.ui.screens.settings.FollowingBackupScreen
import com.nostrvault.ui.screens.settings.ImportSettingsScreen
import com.nostrvault.ui.screens.settings.MediaSettingsScreen
import com.nostrvault.ui.screens.settings.RelayAccessSettingsScreen
import com.nostrvault.ui.screens.settings.NotificationSettingsScreen
import com.nostrvault.ui.screens.settings.PowSettingsScreen
import com.nostrvault.ui.screens.settings.HavenRelaySettingsScreen
import com.nostrvault.ui.screens.settings.RelayMatrixScreen
import com.nostrvault.ui.screens.settings.MeshSettingsScreen
import com.nostrvault.ui.screens.settings.SettingsScreen

/** Settings and its pages, lifted from [NostrVaultNavHost]. */
internal fun NavGraphBuilder.settingsRoutes(
    navController: NavHostController,
    nostrService: NostrService,
) {
    // ── Settings ──────────────────────────────────────────
    composable(Screen.Settings.route) {
        SettingsScreen(
            onNavigate = { screen -> navController.navigate(screen.route) },
            onBack = { navController.popBackStack() },
        )
    }

    composable(Screen.TutorialsSettings.route) {
        com.nostrvault.tutorials.TutorialsSettingsScreen(
            account = nostrService.activeHexPubkey,
            onBack = { navController.popBackStack() },
            // To the tutorial's page, where the replayed card waits.
            onReplay = { id -> navigateToTutorialRoute(navController, tutorialRoute(id)) },
        )
    }

    composable(Screen.AppearanceSettings.route) {
        AppearanceSettingsScreen(
            onBack = { navController.popBackStack() },
        )
    }

    composable(Screen.FeedSettings.route) {
        FeedSettingsScreen(
            onBack = { navController.popBackStack() },
            onOpenRelays = { navController.navigate(Screen.Relays.route) },
        )
    }

    composable(Screen.AccountSettings.route) {
        AccountSettingsScreen(
            onBack = { navController.popBackStack() },
        )
    }

    composable(Screen.BlockedSettings.route) {
        BlockedSettingsScreen(
            onBack = { navController.popBackStack() },
        )
    }

    composable(Screen.RecentlyDeletedSettings.route) {
        RecentlyDeletedSettingsScreen(
            onBack = { navController.popBackStack() },
        )
    }

    composable(Screen.AdvancedSettings.route) {
        AdvancedSettingsScreen(
            onBack = { navController.popBackStack() },
        )
    }

    composable(Screen.MediaSettings.route) {
        MediaSettingsScreen(
            onBack = { navController.popBackStack() },
        )
    }

    composable(Screen.RelayAccessSettings.route) {
        RelayAccessSettingsScreen(
            onBack = { navController.popBackStack() },
        )
    }

    composable(Screen.ImportSettings.route) {
        ImportSettingsScreen(
            onBack = { navController.popBackStack() },
        )
    }

    composable(Screen.BackupSettings.route) {
        BackupSettingsScreen(
            onBack = { navController.popBackStack() },
        )
    }

    composable(Screen.Relays.route) {
        RelayMatrixScreen(
            onBack = { navController.popBackStack() },
            onOpenMediaServers = { navController.navigate(Screen.BlossomSettings.route) },
        )
    }

    composable(Screen.BlossomSettings.route) {
        BlossomSettingsScreen(
            onBack = { navController.popBackStack() },
        )
    }

    composable(Screen.PowSettings.route) {
        PowSettingsScreen(
            onBack = { navController.popBackStack() },
        )
    }

    composable(Screen.FollowingBackup.route) {
        FollowingBackupScreen(
            onBack = { navController.popBackStack() },
        )
    }

    composable(Screen.NotificationSettings.route) {
        NotificationSettingsScreen(
            onBack = { navController.popBackStack() },
        )
    }

    composable(Screen.HavenRelaySettings.route) {
        HavenRelaySettingsScreen(
            onBack = { navController.popBackStack() },
        )
    }

    composable(Screen.MeshSettings.route) {
        MeshSettingsScreen(
            onBack = { navController.popBackStack() },
        )
    }
}
