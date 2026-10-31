package com.nostrvault.ui.navigation

import com.nostrvault.ui.components.ZapFlightStage
import com.nostrvault.ui.components.ScrollChrome
import com.nostrvault.ui.components.chromeFold
import com.nostrvault.ui.components.FoldBlocked
import com.nostrvault.ui.components.rememberScrollChromeConnection
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.animation.*
import androidx.compose.animation.core.FiniteAnimationSpec
import androidx.compose.foundation.layout.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.dp
import androidx.navigation.NavBackStackEntry
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import com.nostrvault.ui.theme.Motion
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.relay.RelayForegroundService
import com.nostrvault.service.FeedService
import com.nostrvault.service.NostrService
import com.nostrvault.ui.components.AccountInfo
import com.nostrvault.ui.components.buildAccountInfos
import com.nostrvault.ui.components.AccountSwitcherSheet
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.NostrVaultIcons
import com.nostrvault.relay.LogStore
import com.nostrvault.ui.screens.*
import kotlinx.coroutines.flow.StateFlow

/**
 * Page transitions take the shared motion vocabulary: a lateral tab switch is a
 * `toggle` (the same token the gallery's grid/list switch uses, so switching
 * tabs and switching modes feel like the same gesture), and a hierarchical push
 * is a `fade`.
 */
internal fun <T> tabMotion(): FiniteAnimationSpec<T> = Motion.toggle()
internal fun <T> pushMotion(): FiniteAnimationSpec<T> = Motion.fade()

/** The five bottom-nav destinations. Navigating between any two of these is a
 *  lateral "tab switch" (fade-through) rather than a hierarchical push. */
private val TOP_LEVEL_ROUTES = setOf(
    Screen.Feed.route,
    Screen.Search.route,
    PROFILE_TAB_ROUTE,
    Screen.Dashboard.route,
    Screen.WOT.route,
)

/**
 * Where the bottom bar shows: the tabs, and the screens iOS pushes inside a
 * tab (a note, a profile, an article, a follow list), so a tab is one tap
 * away from a thread as on the iPhone. Sheets on iOS (compose, settings,
 * messages, a hashtag) cover it. A pushed profile also lets the Profile tab
 * take you back to your own from someone else's.
 */
private val BOTTOM_BAR_ROUTES = TOP_LEVEL_ROUTES + setOf(
    Screen.Profile.route,
    Screen.NoteDetail.route,
    Screen.ArticleReader.route,
    Screen.AddressLink.route,
    Screen.FollowList.route,
)

internal fun showsBottomBar(route: String?): Boolean = route in BOTTOM_BAR_ROUTES

/** The mini player sits over every screen except compose, where it covered
 *  the text box and its toolbar. iOS compose is a sheet above the player. */
internal fun showsMiniPlayer(route: String?): Boolean = route != Screen.ComposeNote.route

/** Tabs whose pushed screens count as inside them, as an iOS tab's own
 *  NavigationStack: over a note opened from the Feed or the Vault that tab
 *  stays lit, and tapping it goes back to it (then to the top). */
private val STACK_TABS = setOf(Screen.Feed.route, Screen.Dashboard.route)

/** The route the bottom bar lights for a back stack, bottom to top: the tab
 *  on screen, or the Feed or Vault tab a pushed screen was opened from. */
internal fun selectedTabRoute(stack: List<String?>): String? {
    val top = stack.lastOrNull()
    if (top in TOP_LEVEL_ROUTES) return top
    val owner = stack.lastOrNull { it in TOP_LEVEL_ROUTES }
    return if (owner in STACK_TABS) owner else top
}

/** True when a tap on [tab] goes back to it: it is lit, but a screen opened
 *  from it is on top. */
internal fun tabTapGoesBack(tab: String, stack: List<String?>): Boolean =
    tab in STACK_TABS && stack.lastOrNull() != tab && selectedTabRoute(stack) == tab

/** True when both ends of the transition are top-level tabs. */
internal fun AnimatedContentTransitionScope<NavBackStackEntry>.isTabSwitch(): Boolean {
    val from = initialState.destination.route
    val to = targetState.destination.route
    return from in TOP_LEVEL_ROUTES && to in TOP_LEVEL_ROUTES
}

/**
 * Root composable that manages navigation state and the floating bottom nav pill.
 * Uses a Box overlay so the pill floats over content.
 */
@Composable
fun NostrVaultNavHost(
    isSetupComplete: Boolean,
    modifier: Modifier = Modifier,
    configStore: ConfigStore,
    feedService: FeedService,
    nostrService: NostrService,
    logStore: LogStore,
    dmUnreadCount: StateFlow<Int>,
    hasNewRelayActivity: StateFlow<Boolean>,
    accountUnread: StateFlow<com.nostrvault.data.model.AccountUnread>,
) {
    val navController = rememberNavController()
    val scope = rememberCoroutineScope()
    val backStackEntry by navController.currentBackStackEntryAsState()
    val currentRoute = backStackEntry?.destination?.route
    val backStack by navController.currentBackStack.collectAsState()
    val selectedTab = selectedTabRoute(backStack.map { it.destination.route })

    val showBottomBar = showsBottomBar(currentRoute)

    // Fixed at first composition, never the live flag (see setupStartRoute).
    val startDestination = remember { setupStartRoute(isSetupComplete) }
    // So a config reset mid-run opens the wizard itself.
    var setupWasComplete by remember { mutableStateOf(isSetupComplete) }
    LaunchedEffect(isSetupComplete) {
        openSetupWizardIfReset(navController, setupWasComplete, isSetupComplete)
        setupWasComplete = isSetupComplete
    }

    // Account switcher state
    var showAccountSwitcher by remember { mutableStateOf(false) }
    val configState = configStore.config.collectAsState()
    val config by configState
    val activeHexState = configStore.activeAccountHexPubkey.collectAsState()
    val activeHex by activeHexState
    val profiles by nostrService.profiles.collectAsState()
    val unread by accountUnread.collectAsState()
    val activeProfile = profiles[activeHex]
    val isOwner = config.activeAccountNpub.isNullOrBlank()
    val unreadDMsState = dmUnreadCount.collectAsState()
    val unreadDMs by unreadDMsState
    val relayActivity by hasNewRelayActivity.collectAsState()
    // Zaps Only hides Likes: a like then lights no Vault list.
    LaunchedEffect(config.zapsOnlyMode) { RelayForegroundService.setZapsOnlyMode(config.zapsOnlyMode) }

    // A tutorial whose cards are on another page goes there: a last card's
    // "Next", or Replay in Settings. WoT is the WoT tab, Your Vault and Vault
    // in Your Pocket the Vault tab (which opens its dashboard for Vault in
    // Your Pocket, over either half), Wallet Connect the wallet. A page starting its own tutorial is
    // already on it.
    val activeTutorial by com.nostrvault.tutorials.TutorialCenter.active.collectAsState()
    LaunchedEffect(activeTutorial) {
        val route = activeTutorial?.let(::tutorialRoute) ?: return@LaunchedEffect
        if (route == Screen.Feed.route || navController.currentDestination?.route == route) return@LaunchedEffect
        navigateToTutorialRoute(navController, route)
    }

    PendingDeepLinkEffect(isSetupComplete, configStore, feedService, navController)
    WotOpenEffect(navController)

    // The bars fold with the scroll, following the finger, where the iPhone
    // folds them (see [foldsChromeOnScroll]); "disable tab bar animation"
    // keeps them shown.
    val chromeFolds = foldsChromeOnScroll(currentRoute)
    val chromeConnection = rememberScrollChromeConnection(
        enabled = chromeFolds && !config.disableTabBarAnimation,
    )

    // An artist or album opened from the full player off the Feed tab: go
    // back to the Feed tab, which switches to Music and shows the page.
    val musicReveal by com.nostrvault.ui.screens.music.MusicFeedState.revealRequested.collectAsState()
    LaunchedEffect(musicReveal) {
        if (musicReveal && currentRoute != Screen.Feed.route) {
            navController.popBackStack(Screen.Feed.route, inclusive = false)
        }
    }

    // A tapped #hashtag anywhere under the nav host opens that hashtag's feed
    // (iOS `.hashtagLinks()`). The same tag already on top is left alone.
    val openHashtag: (String) -> Unit = remember(navController) {
        { raw ->
            HashtagLink.normalize(raw)?.let { tag ->
                val top = navController.currentBackStackEntry
                val onTop = top?.destination?.route == Screen.HashtagFeed.route &&
                    top.arguments?.getString("tag") == tag
                if (!onTop) navController.navigate(Screen.HashtagFeed.createRoute(tag))
            }
        }
    }

    Box(modifier = modifier.fillMaxSize()) {
        CompositionLocalProvider(LocalOpenHashtag provides openHashtag) {
            NavHost(
                navController = navController,
                startDestination = startDestination,
                modifier = Modifier.fillMaxSize().nestedScroll(chromeConnection),
                // Motion matched to the navigation type: lateral tab switches use a
                // Material "fade-through" (fade + subtle scale), hierarchical pushes use
                // "shared-axis Z" (zoom into/out of depth). See navMotion() below.
                enterTransition = {
                    if (isTabSwitch()) fadeIn(tabMotion()) + scaleIn(initialScale = 0.92f, animationSpec = tabMotion())
                    else fadeIn(pushMotion()) + scaleIn(initialScale = 0.80f, animationSpec = pushMotion())
                },
                exitTransition = {
                    if (isTabSwitch()) fadeOut(tabMotion())
                    else fadeOut(pushMotion()) + scaleOut(targetScale = 1.10f, animationSpec = pushMotion())
                },
                popEnterTransition = {
                    if (isTabSwitch()) fadeIn(tabMotion()) + scaleIn(initialScale = 0.92f, animationSpec = tabMotion())
                    else fadeIn(pushMotion()) + scaleIn(initialScale = 1.10f, animationSpec = pushMotion())
                },
                popExitTransition = {
                    if (isTabSwitch()) fadeOut(tabMotion())
                    else fadeOut(pushMotion()) + scaleOut(targetScale = 0.80f, animationSpec = pushMotion())
                },
            ) {
                tabRoutes(navController, activeHexState)
                detailRoutes(navController, feedService)
                walletRoutes(navController)
                settingsRoutes(navController, nostrService)
                vaultRoutes(navController, logStore, feedService, unreadDMsState)
                mediaRoutes(navController, configState)
            }
        }

        // Shared by the mini player and the folded bar's now-playing disc.
        val musicActions = remember(navController) {
            com.nostrvault.ui.screens.music.MusicActions(
                onShare = { navController.navigate(Screen.ComposeNote.createRoute(text = it)) },
                onOpenProfile = { navController.navigate(Screen.Profile.createRoute(it)) },
                npubToHex = nostrService::npubToHex,
            )
        }

        // Floating bottom nav pill overlay
        if (showBottomBar) {
            // The bar reads the fold progress in layout and draw only, so a drag
            // never recomposes it or the tab content under it.
            val condenseTab = chromeFolds

            // Contextual condensed action (icon + tint + click), matching iOS:
            // compose, or on the Vault tab (either half) the Vault Dashboard,
            // tinted by live relay status.
            val colors = LocalNostrVaultColors.current
            val relayStatus by RelayForegroundService.relayStatus.collectAsState()
            val opensVaultDashboard = currentRoute == Screen.Dashboard.route
            val condensedActionIcon = if (opensVaultDashboard) NostrVaultIcons.TabVault else NostrVaultIcons.Compose
            val condensedActionTint = if (opensVaultDashboard) relayStatusColor(relayStatus) else colors.primary
            // A read-only sign-in can't sign a post: no compose action.
            val canSign = com.nostrvault.ui.components.rememberCanSign()
            val onCondensedAction: (() -> Unit)? = if (opensVaultDashboard) {
                { feedService.requestRelayDashboard() }
            } else if (canSign) {
                { navController.navigate(Screen.ComposeNote.createRoute()) }
            } else {
                null
            }

            val density = LocalDensity.current
            DisposableEffect(Unit) {
                onDispose { FloatingNavBarInset.height.value = 0.dp }
            }
            Box(
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .onSizeChanged { size ->
                        FloatingNavBarInset.height.value = with(density) { size.height.toDp() }
                    },
            ) {
                BottomNavBar(
                    currentRoute = selectedTab,
                    activeAccountPubkey = activeHex,
                    activeAvatarUrl = activeProfile?.pictureURL,
                    activeDisplayName = activeProfile?.bestName,
                    isOwner = isOwner,
                    foldProgress = { if (condenseTab) ScrollChrome.progress else 0f },
                    hasUnreadDMs = unreadDMs > 0,
                    hasNewRelayActivity = relayActivity,
                    // The rows the switcher sheet lists, the active one aside.
                    otherAccountHasNews = unread.othersHaveUnread(
                        accounts = buildAccountInfos(config, profiles, includeWhitelisted = true).map { it.hexPubkey },
                        active = activeHex,
                    ),
                    onNavigate = { screen ->
                        // The dot goes to where the news is, not to the list
                        // you left. The list clears once it is on screen.
                        if (screen == Screen.Dashboard && relayActivity) {
                            VaultSection.requestOpenNewActivity()
                        }
                        val route = if (screen == Screen.Profile) {
                            PROFILE_TAB_ROUTE
                        } else {
                            screen.route
                        }
                        navController.navigate(route) {
                            popUpTo(Screen.Feed.route) { saveState = true }
                            launchSingleTop = true
                            restoreState = true
                        }
                    },
                    onReselect = { screen ->
                        // Over a note opened from the Feed or the Vault: back
                        // to the tab (iOS clears its path). The next tap goes
                        // to the top, so a double tap is back and up. Read
                        // live, so a fast second tap sees the first one's pop.
                        val stack = navController.currentBackStack.value.map { it.destination.route }
                        if (tabTapGoesBack(screen.route, stack)) {
                            navController.popBackStack(screen.route, inclusive = false)
                            return@BottomNavBar
                        }
                        when (screen) {
                            Screen.Feed -> feedService.requestScrollToTop()
                            // The Vault tab's half on screen scrolls to the top;
                            // the WOT globe goes back to you; the Profile and
                            // Search tabs scroll to the top (iOS SearchScrollToTop).
                            Screen.Dashboard, Screen.WOT, Screen.Profile, Screen.Search -> {
                                TabReselect.request(screen)
                            }
                            else -> {
                                // Other tabs: pop back to root if deep, otherwise no-op for now
                                navController.popBackStack(screen.route, inclusive = false)
                            }
                        }
                    },
                    // As iOS: holding the avatar does nothing with one account.
                    onAccountSwitcher = {
                        if (buildAccountInfos(config, profiles, includeWhitelisted = true).size > 1) {
                            showAccountSwitcher = true
                        }
                    },
                    condensedActionIcon = condensedActionIcon,
                    condensedActionLabel = if (opensVaultDashboard) "Vault Dashboard" else "Compose new post",
                    condensedActionTint = condensedActionTint,
                    onCondensedAction = onCondensedAction,
                    onExpand = { ScrollChrome.expand(scope) },
                    nowPlaying = { com.nostrvault.ui.screens.music.CollapsedNowPlayingButton(musicActions) },
                    onPickFeedMode = { mode ->
                        // The feed applies it (its ViewModel owns the mode),
                        // now or as soon as it is back on screen.
                        FeedTabPicker.request.value = mode
                        if (currentRoute != Screen.Feed.route) {
                            navController.navigate(Screen.Feed.route) {
                                popUpTo(Screen.Feed.route) { saveState = true }
                                launchSingleTop = true
                                restoreState = true
                            }
                        }
                    },
                )
            }
        }

        // Music mini player: above the bottom bar on every tab while a song or
        // a live stream is loaded. On tabs with a floating button (Post,
        // Blossom, Relay) it stops short of it so the two share the row.
        // Folds away with the bar and the floating button; the folded bar
        // carries a small now-playing disc instead (iOS ChromeFold). The fold
        // is read in FoldBlocked, so its flip never recomposes this host.
        if (showsMiniPlayer(currentRoute)) FoldBlocked(
            whenFolded = true,
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .padding(
                    bottom = if (showBottomBar) FloatingButtonRow.rowBottom else 16.dp,
                    // Stops short of the screen's floating button, which
                    // sits level with it (FloatingButtonRow); the bar's own
                    // 12dp side inset already counts toward the gap.
                    end = (FloatingButtonRow.reservedWidth - 12.dp).coerceAtLeast(0.dp),
                )
                .chromeFold(),
        ) { com.nostrvault.ui.screens.music.MiniPlayerBar(actions = musicActions) }

        // The live player, over everything above (tab bar and mini player
        // included) rather than on a nav route: it needs the LiveStream object
        // it was opened with, and a route argument would mean re-resolving a
        // replaceable event that may already be gone.
        com.nostrvault.ui.components.LiveStreamHost()

        // Hold-the-Feed-tab list: over everything, the bar included.
        if (showBottomBar) {
            FeedTabPickerOverlay(
                onPick = { mode ->
                    FeedTabPicker.request.value = mode
                    if (currentRoute != Screen.Feed.route) {
                        navController.navigate(Screen.Feed.route) {
                            popUpTo(Screen.Feed.route) { saveState = true }
                            launchSingleTop = true
                            restoreState = true
                        }
                    }
                },
            )
        }

        // Zap flights cross the whole window, so they're drawn above it all.
        ZapFlightStage()
    }

    // Account switcher bottom sheet
    if (showAccountSwitcher) {
        val accounts = buildAccountInfos(config, profiles, includeWhitelisted = true, unread = unread)

        AccountSwitcherSheet(
            accounts = accounts,
            onSelectAccount = { npub ->
                // The Profile tab follows the switch on its own. A pushed profile is
                // pinned to a pubkey nav arg, so if it is our OWN, re-navigate it to
                // the newly active account. Leave it untouched when viewing someone
                // else's profile.
                val previousHex = activeHex
                val viewingOwnProfile = currentRoute == Screen.Profile.route &&
                    backStackEntry?.arguments?.getString("pubkey") == previousHex
                val newHex = accounts.firstOrNull { it.npub == npub }?.hexPubkey
                scope.launch {
                    configStore.switchActiveAccount(npub)
                    if (viewingOwnProfile && newHex != null) {
                        navController.navigate(Screen.Profile.createRoute(newHex)) {
                            popUpTo(Screen.Profile.route) { inclusive = true }
                            launchSingleTop = true
                        }
                    }
                }
            },
            onDismiss = { showAccountSwitcher = false },
        )
    }
}

/** The page a tutorial's cards are on. Your Vault's are on the Vault tab's relay half;
 *  WoT's on the WoT tab's globe (iOS 993f42e1: replay and "Next" open it). */
internal fun tutorialRoute(id: com.nostrvault.tutorials.TutorialID): String = when (id) {
    com.nostrvault.tutorials.TutorialID.WOT -> Screen.WOT.route
    com.nostrvault.tutorials.TutorialID.VAULT,
    com.nostrvault.tutorials.TutorialID.POCKET_RELAY -> Screen.Dashboard.route
    com.nostrvault.tutorials.TutorialID.WALLET_CONNECT -> Screen.Wallet.route
    // Listed, not `else`: a new tutorial must pick its tab or this fails to
    // compile. WOT once fell through to Feed and drew its cards arrowless.
    com.nostrvault.tutorials.TutorialID.FILL_YOUR_VAULT,
    com.nostrvault.tutorials.TutorialID.FEEDS,
    com.nostrvault.tutorials.TutorialID.IMPORT_TOUR -> Screen.Feed.route
}

/** Tabs open as the bottom bar opens them, then drop anything their saved
 *  stack brings back (a thread, or the wallet an earlier card opened), so
 *  the tab itself is on screen for its cards. The wallet goes on top. */
internal fun navigateToTutorialRoute(navController: androidx.navigation.NavHostController, route: String) {
    if (route == Screen.Wallet.route) {
        navController.navigate(route) { launchSingleTop = true }
        return
    }
    navController.navigate(route) {
        popUpTo(Screen.Feed.route) { saveState = true }
        launchSingleTop = true
        restoreState = true
    }
    navController.popBackStack(route, inclusive = false)
}

/**
 * Screens whose scrolling folds the bottom bar, as on iPhone
 * (`scrollDirectionTracking`): Feed, both halves of Vault (Media included),
 * Search, a profile (yours or pushed) and the article reader. The WoT globe
 * and the rest keep the bar shown.
 */
internal fun foldsChromeOnScroll(route: String?): Boolean = route in FOLDING_ROUTES

private val FOLDING_ROUTES = setOf(
    Screen.Feed.route,
    Screen.Dashboard.route,
    Screen.Search.route,
    PROFILE_TAB_ROUTE,
    Screen.Profile.route,
    Screen.ArticleReader.route,
)
