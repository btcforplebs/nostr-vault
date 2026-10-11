package com.nostrvault.ui.navigation

import androidx.compose.animation.*
import androidx.compose.ui.graphics.TransformOrigin
import androidx.navigation.NavGraphBuilder
import androidx.navigation.NavHostController
import androidx.navigation.NavType
import androidx.navigation.compose.composable
import androidx.navigation.navArgument
import com.nostrvault.service.FeedService
import com.nostrvault.ui.components.ThreadZoomOrigin
import com.nostrvault.ui.screens.ArticleReaderScreen
import com.nostrvault.ui.screens.*
import com.nostrvault.ui.screens.dm.DMThreadScreen
import com.nostrvault.ui.screens.dm.NewMessageScreen

/** Notes, articles, DMs and the composer, lifted from [NostrVaultNavHost]. */
internal fun NavGraphBuilder.detailRoutes(
    navController: NavHostController,
    feedService: FeedService,
) {
    // ── Detail screens ────────────────────────────────────
    composable(
        route = Screen.AddressLink.route,
        arguments = listOf(navArgument("naddr") { type = NavType.StringType }),
    ) { entry ->
        val naddr = entry.arguments?.getString("naddr") ?: return@composable
        com.nostrvault.ui.screens.AddressLinkScreen(
            naddr = naddr,
            feedService = feedService,
            onResolved = { route ->
                navController.navigate(route) {
                    popUpTo(Screen.AddressLink.route) { inclusive = true }
                }
            },
            onBack = { navController.popBackStack() },
        )
    }

    composable(
        route = Screen.ArticleReader.route,
        arguments = listOf(navArgument("noteId") { type = NavType.StringType }),
    ) {
        ArticleReaderScreen(
            onBack = { navController.popBackStack() },
            onProfileClick = { pubkey ->
                navController.navigate(Screen.Profile.createRoute(pubkey))
            },
            onComment = { id ->
                navController.navigate(Screen.ComposeNote.createRoute(replyToNoteId = id))
            },
            onNoteClick = { id ->
                navController.navigate(Screen.NoteDetail.createRoute(id))
            },
        )
    }

    composable(
        route = Screen.NoteDetail.route,
        arguments = listOf(navArgument("noteId") { type = NavType.StringType }),
        // Zooms open out of the tapped post and closes back into
        // it (iOS #306); from the middle when no post was tapped.
        enterTransition = {
            val origin = ThreadZoomOrigin.take(targetState.id) ?: TransformOrigin.Center
            fadeIn(pushMotion()) + scaleIn(initialScale = 0.80f, transformOrigin = origin, animationSpec = pushMotion())
        },
        // Coming back to a thread is the host's return, not the
        // open-zoom: composable() would otherwise reuse enterTransition.
        popEnterTransition = {
            if (isTabSwitch()) fadeIn(tabMotion()) + scaleIn(initialScale = 0.92f, animationSpec = tabMotion())
            else fadeIn(pushMotion()) + scaleIn(initialScale = 1.10f, animationSpec = pushMotion())
        },
        popExitTransition = {
            val origin = ThreadZoomOrigin.closing(initialState.id) ?: TransformOrigin.Center
            fadeOut(pushMotion()) + scaleOut(targetScale = 0.80f, transformOrigin = origin, animationSpec = pushMotion())
        },
    ) { entry ->
        val noteId = entry.arguments?.getString("noteId") ?: return@composable
        NoteDetailScreen(
            noteId = noteId,
            onProfileClick = { pubkey ->
                navController.navigate(Screen.Profile.createRoute(pubkey))
            },
            onNoteClick = { id ->
                navController.navigate(Screen.NoteDetail.createRoute(id))
            },
            onArticleClick = { id ->
                navController.navigate(Screen.ArticleReader.createRoute(id))
            },
            onReply = { id ->
                navController.navigate(Screen.ComposeNote.createRoute(replyToNoteId = id))
            },
            onQuote = { id ->
                navController.navigate(Screen.ComposeNote.createRoute(quoteToNoteId = id))
            },
            onBack = { navController.popBackStack() },
        )
    }

    composable(
        route = Screen.HashtagFeed.route,
        arguments = listOf(navArgument("tag") { type = NavType.StringType }),
    ) {
        HashtagFeedScreen(
            onNoteClick = { id ->
                navController.navigate(Screen.NoteDetail.createRoute(id))
            },
            onArticleClick = { id ->
                navController.navigate(Screen.ArticleReader.createRoute(id))
            },
            onProfileClick = { pubkey ->
                navController.navigate(Screen.Profile.createRoute(pubkey))
            },
            onReply = { id ->
                navController.navigate(Screen.ComposeNote.createRoute(replyToNoteId = id))
            },
            onQuote = { id ->
                navController.navigate(Screen.ComposeNote.createRoute(quoteToNoteId = id))
            },
            onBack = { navController.popBackStack() },
        )
    }

    composable(
        route = Screen.DMThread.route,
        arguments = listOf(
            navArgument("pubkey") { type = NavType.StringType },
            navArgument("draft") { type = NavType.StringType; nullable = true; defaultValue = null },
        ),
    ) { entry ->
        val pubkey = entry.arguments?.getString("pubkey") ?: return@composable
        DMThreadScreen(
            counterpartyPubkey = pubkey,
            initialMessage = entry.arguments?.getString("draft"),
            onProfileClick = { pk ->
                navController.navigate(Screen.Profile.createRoute(pk))
            },
            onBack = { navController.popBackStack() },
        )
    }

    composable(
        route = Screen.NewMessage.route,
        arguments = listOf(
            navArgument("pubkey") { type = NavType.StringType; nullable = true; defaultValue = null },
        ),
    ) {
        NewMessageScreen(
            onMessageSent = { recipientHex ->
                navController.navigate(Screen.DMThread.createRoute(recipientHex)) {
                    popUpTo(Screen.NewMessage.route) { inclusive = true }
                }
            },
            onBack = { navController.popBackStack() },
        )
    }

    composable(
        route = Screen.ComposeNote.route,
        arguments = listOf(
            navArgument("replyTo") { type = NavType.StringType; nullable = true; defaultValue = null },
            navArgument("quoteTo") { type = NavType.StringType; nullable = true; defaultValue = null },
            navArgument("draftId") { type = NavType.StringType; nullable = true; defaultValue = null },
            navArgument("text") { type = NavType.StringType; nullable = true; defaultValue = null },
        ),
    ) { entry ->
        ComposeNoteScreen(
            onPublished = { navController.popBackStack() },
            onBack = { navController.popBackStack() },
            onOpenDrafts = { navController.navigate(Screen.Drafts.route) },
        )
    }

    composable(
        route = Screen.ModeCompose.route,
        arguments = listOf(navArgument("kind") { type = NavType.StringType }),
    ) {
        ModeComposeScreen(onDone = { navController.popBackStack() })
    }

    composable(Screen.Drafts.route) {
        DraftsScreen(
            onResumeDraft = { draftId, _, replyToId, quoteToId ->
                // Replace the composer this was opened from, rather than
                // stacking a second one behind it (matches iOS, which loads
                // the draft into the open composer). Popping Drafts as well
                // means Back from the resumed draft leaves the composer
                // entirely instead of landing on the list again.
                navController.navigate(
                    Screen.ComposeNote.createRoute(
                        replyToNoteId = replyToId,
                        quoteToNoteId = quoteToId,
                        draftId = draftId,
                    )
                ) {
                    popUpTo(Screen.ComposeNote.route) { inclusive = true }
                }
            },
            onBack = { navController.popBackStack() },
        )
    }
}
