package com.nostrvault.ui.navigation

import androidx.compose.runtime.*
import androidx.navigation.NavHostController
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.model.FeedNote
import com.nostrvault.service.FeedService

/** Acts on [PendingDeepLink], lifted from [NostrVaultNavHost]. */
@Composable
internal fun PendingDeepLinkEffect(
    isSetupComplete: Boolean,
    configStore: ConfigStore,
    feedService: FeedService,
    navController: NavHostController,
) {
    // A tap from outside the app — widget, notification, nostr: link — lands in
    // PendingDeepLink; this is the only place that can act on it. Setup has to
    // be finished first: navigating away from the wizard would strand a
    // half-configured install with no way back.
    val pendingLink by PendingDeepLink.target.collectAsState()
    LaunchedEffect(pendingLink, isSetupComplete) {
        if (pendingLink == null || !isSetupComplete) return@LaunchedEffect
        val target = PendingDeepLink.consume() ?: return@LaunchedEffect
        // Notifications carry the account they arrived for. Switch first, so a
        // mention of a second identity does not open under the first.
        target.accountNpub
            ?.takeIf { it != configStore.config.value.activeOrOwnerNpub() }
            ?.let { configStore.switchActiveAccount(it) }
        if (target.mediaPaste) PendingMediaPaste.request()
        // The Vault tab opens on the half the link names: Media for the
        // gallery and Magic Paste, the relay's lists for a post. A tap naming
        // no list (a widget's Relay) keeps the list the tab had, "Vault" or
        // another.
        if (target.route == Screen.Dashboard.route) {
            if (target.vaultMedia || target.relayFocus != null) VaultSection.show(media = target.vaultMedia)
            else VaultSection.leaveMedia()
        }
        // A notification's post goes in the note cache first, so the note
        // screen finds it there and shows it at once instead of fetching.
        target.seedNote?.let {
            feedService.cacheNote(FeedNote.fromEvent(it.id, it.pubkey, it.content, it.tags, it.createdAt, it.kind))
        }
        val focus = target.relayFocus
        if (focus == null && target.route == Screen.Dashboard.route) {
            // A widget's Media or Relay tap: switch to the Vault tab as the
            // bottom bar does, so its view models and connection are reused
            // rather than a second copy pushed on top.
            navController.navigate(Screen.Dashboard.route) {
                popUpTo(Screen.Feed.route) { saveState = true }
                launchSingleTop = true
                restoreState = true
            }
            navController.popBackStack(Screen.Dashboard.route, inclusive = false)
            return@LaunchedEffect
        }
        if (focus == null) {
            // A notification switches tab first, as iOS does: a post opens over
            // the Feed tab, a follower over the Vault's Followers list.
            target.overTab?.let { tab ->
                target.behindFocus?.let {
                    VaultSection.show(media = false)
                    RelayFocus.request(it)
                }
                navController.navigate(tab) {
                    popUpTo(Screen.Feed.route) { saveState = true }
                    launchSingleTop = true
                    restoreState = true
                }
                navController.popBackStack(tab, inclusive = false)
            }
            navController.navigate(target.route) { launchSingleTop = true }
            return@LaunchedEffect
        }
        // A notification about a post: park the target for the Vault tab's relay half, then
        // switch to that tab as the bottom bar does — the same instance, so its
        // loaded events are reused — and drop anything stacked on it (an open
        // thread), so the list the tab scrolls is the one on screen.
        RelayFocus.request(focus)
        navController.navigate(Screen.Dashboard.route) {
            popUpTo(Screen.Feed.route) { saveState = true }
            launchSingleTop = true
            restoreState = true
        }
        navController.popBackStack(Screen.Dashboard.route, inclusive = false)
    }
}
