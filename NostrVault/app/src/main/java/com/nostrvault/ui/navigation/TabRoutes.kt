package com.nostrvault.ui.navigation

import androidx.compose.runtime.Composable
import androidx.compose.runtime.State
import androidx.navigation.NavGraphBuilder
import androidx.navigation.NavHostController
import androidx.navigation.NavType
import androidx.navigation.compose.composable
import androidx.navigation.navArgument
import com.nostrvault.ui.screens.*
import com.nostrvault.ui.screens.dm.DMInboxScreen
import com.nostrvault.ui.screens.feed.FeedScreen
import com.nostrvault.ui.screens.profile.ProfileScreen

/**
 * The Profile tab. It always shows the active account, so it has its own route:
 * [Screen.Profile] (`profile/{pubkey}`) is a profile pushed from somewhere,
 * yours included, and keeps a back button.
 */
internal const val PROFILE_TAB_ROUTE = "profile_tab"

/** Setup, the bottom-nav tabs and the profile pages, lifted from [NostrVaultNavHost]. */
internal fun NavGraphBuilder.tabRoutes(
    navController: NavHostController,
    activeHexState: State<String>,
) {
    // ── Setup ─────────────────────────────────────────────
    composable(Screen.SetupWizard.route) {
        SetupWizardScreen(
            onComplete = {
                navController.navigate(Screen.Feed.route) {
                    popUpTo(Screen.SetupWizard.route) { inclusive = true }
                }
            },
        )
    }

    // ── Bottom nav tabs ───────────────────────────────────
    composable(Screen.Feed.route) {
        FeedScreen(
            onNoteClick = { noteId ->
                navController.navigate(Screen.NoteDetail.createRoute(noteId))
            },
            onArticleClick = { noteId ->
                navController.navigate(Screen.ArticleReader.createRoute(noteId))
            },
            onProfileClick = { pubkey ->
                navController.navigate(Screen.Profile.createRoute(pubkey))
            },
            onMessageUser = { pubkey, draft ->
                navController.navigate(Screen.DMThread.createRoute(pubkey, draft))
            },
            onCompose = {
                navController.navigate(Screen.ComposeNote.createRoute())
            },
            onComposeMode = { kind ->
                navController.navigate(Screen.ModeCompose.createRoute(kind.route))
            },
            onComposeText = { text ->
                navController.navigate(Screen.ComposeNote.createRoute(text = text))
            },
            onReply = { noteId ->
                navController.navigate(Screen.ComposeNote.createRoute(replyToNoteId = noteId))
            },
            onQuote = { noteId ->
                navController.navigate(Screen.ComposeNote.createRoute(quoteToNoteId = noteId))
            },
            onOpenDashboard = { navController.navigate(Screen.FeedDashboard.route) },
        )
    }

    composable(Screen.FeedDashboard.route) {
        com.nostrvault.ui.screens.feed.FeedDashboardScreen(
            onBack = { navController.popBackStack() },
            onOpenFeed = { navController.popBackStack(Screen.Feed.route, inclusive = false) },
            onProfileClick = { navController.navigate(Screen.Profile.createRoute(it)) },
            onNoteClick = { navController.navigate(Screen.NoteDetail.createRoute(it)) },
            onHashtagClick = { navController.navigate(Screen.HashtagFeed.createRoute(it)) },
            onOpenVault = { target ->
                // As a notification tap does: park the list for the
                // Vault tab's relay half, then switch to that tab.
                if (target == com.nostrvault.ui.screens.feed.VaultTarget.VAULT) {
                    VaultSection.leaveMedia()
                } else {
                    VaultSection.show(media = false)
                }
                when (target) {
                    com.nostrvault.ui.screens.feed.VaultTarget.ZAPS ->
                        RelayFocus.request(RelayFocusRequest("zap", ""))
                    com.nostrvault.ui.screens.feed.VaultTarget.FOLLOWERS ->
                        RelayFocus.request(RelayFocusRequest(NotificationTarget.FOLLOWERS, ""))
                    com.nostrvault.ui.screens.feed.VaultTarget.VAULT -> Unit
                }
                navController.navigate(Screen.Dashboard.route) {
                    popUpTo(Screen.Feed.route) { saveState = true }
                    launchSingleTop = true
                    restoreState = true
                }
            },
        )
    }

    composable(Screen.Search.route) {
        SearchScreen(
            onNoteClick = { noteId ->
                navController.navigate(Screen.NoteDetail.createRoute(noteId))
            },
            onArticleClick = { noteId ->
                navController.navigate(Screen.ArticleReader.createRoute(noteId))
            },
            onProfileClick = { pubkey ->
                navController.navigate(Screen.Profile.createRoute(pubkey))
            },
            onReply = { noteId ->
                navController.navigate(Screen.ComposeNote.createRoute(replyToNoteId = noteId))
            },
            onQuote = { noteId ->
                navController.navigate(Screen.ComposeNote.createRoute(quoteToNoteId = noteId))
            },
            onCompose = {
                navController.navigate(Screen.ComposeNote.createRoute())
            },
        )
    }

    composable(Screen.WOT.route) {
        WOTTabScreen(
            onProfileClick = { pubkey ->
                navController.navigate(Screen.Profile.createRoute(pubkey))
            },
            onMessage = { pubkey ->
                navController.navigate(Screen.DMThread.createRoute(pubkey))
            },
        )
    }

    composable(Screen.DMInbox.route) {
        DMInboxScreen(
            onConversationClick = { pubkey ->
                navController.navigate(Screen.DMThread.createRoute(pubkey))
            },
            onNewMessage = {
                navController.navigate(Screen.NewMessage.createRoute())
            },
        )
    }

    // Follows an account switch on its own: the pubkey is read, not pinned.
    composable(PROFILE_TAB_ROUTE) {
        ProfileRoute(navController, pubkey = activeHexState.value, isTab = true)
    }

    composable(
        route = Screen.Profile.route,
        arguments = listOf(navArgument("pubkey") { type = NavType.StringType }),
    ) { entry ->
        val pubkey = entry.arguments?.getString("pubkey") ?: return@composable
        ProfileRoute(navController, pubkey = pubkey, isTab = false)
    }

    composable(
        route = Screen.FollowList.route,
        arguments = listOf(
            navArgument("pubkey") { type = NavType.StringType },
            navArgument("tab") { type = NavType.StringType; defaultValue = "FOLLOWING" },
            navArgument("total") { type = NavType.StringType; defaultValue = "-1" },
        ),
    ) {
        com.nostrvault.ui.screens.profile.FollowListScreen(
            onProfileClick = { pk -> navController.navigate(Screen.Profile.createRoute(pk)) },
            onBack = { navController.popBackStack() },
        )
    }
}

/** A profile page with the app's routes wired in: the tab or a pushed profile. */
@Composable
private fun ProfileRoute(navController: NavHostController, pubkey: String, isTab: Boolean) {
    ProfileScreen(
        pubkey = pubkey,
        onNoteClick = { noteId ->
            navController.navigate(Screen.NoteDetail.createRoute(noteId))
        },
        onArticleClick = { noteId ->
            navController.navigate(Screen.ArticleReader.createRoute(noteId))
        },
        onProfileClick = { pk ->
            navController.navigate(Screen.Profile.createRoute(pk))
        },
        onReply = { noteId ->
            navController.navigate(Screen.ComposeNote.createRoute(replyToNoteId = noteId))
        },
        onQuote = { noteId ->
            navController.navigate(Screen.ComposeNote.createRoute(quoteToNoteId = noteId))
        },
        onSell = {
            navController.navigate(Screen.ModeCompose.createRoute(com.nostrvault.ui.screens.ModeComposerKind.LISTING.route))
        },
        onComposeText = { text ->
            navController.navigate(Screen.ComposeNote.createRoute(text = text))
        },
        onNavigateToSettings = {
            navController.navigate(Screen.Settings.route)
        },
        onOpenLightning = {
            navController.navigate(Screen.Wallet.route)
        },
        onNavigateToDMThread = { pk ->
            navController.navigate(Screen.DMThread.createRoute(pk))
        },
        onMessageUser = { pk, draft ->
            navController.navigate(Screen.DMThread.createRoute(pk, draft))
        },
        onOpenFollowList = { tab, total ->
            navController.navigate(Screen.FollowList.createRoute(pubkey, tab.name, total))
        },
        onBack = { navController.popBackStack() },
        isTab = isTab,
    )
}
