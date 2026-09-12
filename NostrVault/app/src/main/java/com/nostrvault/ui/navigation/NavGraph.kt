package com.nostrvault.ui.navigation

import androidx.compose.animation.*
import androidx.compose.animation.core.FiniteAnimationSpec
import androidx.compose.foundation.layout.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.navigation.NavBackStackEntry
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
import com.nostrvault.ui.theme.Motion
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.relay.RelayForegroundService
import com.nostrvault.service.FeedService
import com.nostrvault.service.NostrService
import com.nostrvault.ui.components.AccountInfo
import com.nostrvault.ui.components.buildAccountInfos
import com.nostrvault.ui.notification.NotificationManager
import com.nostrvault.service.PendingPostManager
import com.nostrvault.ui.components.PendingPostBanner
import com.nostrvault.ui.notification.NotificationOverlay
import com.nostrvault.ui.components.AccountSwitcherSheet
import com.nostrvault.ui.theme.ErrorRed
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.NostrVaultIcons
import com.nostrvault.ui.theme.SuccessGreen
import com.nostrvault.ui.theme.ZapOrange
import com.nostrvault.relay.LogStore
import com.nostrvault.ui.screens.ArticleReaderScreen
import com.nostrvault.ui.screens.*
import com.nostrvault.ui.screens.dashboard.LogViewerScreen
import com.nostrvault.ui.screens.dm.DMInboxScreen
import com.nostrvault.ui.screens.dm.DMThreadScreen
import com.nostrvault.ui.screens.dm.NewMessageScreen
import com.nostrvault.ui.screens.feed.FeedScreen
import com.nostrvault.ui.screens.groups.GroupBrowserScreen
import com.nostrvault.ui.screens.groups.GroupChatScreen
import com.nostrvault.ui.screens.groups.GroupInfoScreen
import com.nostrvault.ui.screens.groups.GroupListScreen
import com.nostrvault.ui.screens.profile.ProfileEditScreen
import com.nostrvault.ui.screens.profile.ProfileScreen
import com.nostrvault.ui.screens.settings.AccountSettingsScreen
import com.nostrvault.ui.screens.settings.AdvancedSettingsScreen
import com.nostrvault.ui.screens.settings.AppearanceSettingsScreen
import com.nostrvault.ui.screens.settings.BackupSettingsScreen
import com.nostrvault.ui.screens.settings.BlastrSettingsScreen
import com.nostrvault.ui.screens.settings.BlockedSettingsScreen
import com.nostrvault.ui.screens.settings.BlossomSettingsScreen
import com.nostrvault.ui.screens.settings.FollowingBackupScreen
import com.nostrvault.ui.screens.settings.ImportSettingsScreen
import com.nostrvault.ui.screens.settings.NotificationSettingsScreen
import com.nostrvault.ui.screens.settings.PowSettingsScreen
import com.nostrvault.ui.screens.settings.HavenRelaySettingsScreen
import com.nostrvault.ui.screens.settings.MeshSettingsScreen
import com.nostrvault.ui.screens.settings.RelayListEditorScreen
import com.nostrvault.ui.screens.settings.SettingsScreen
import kotlinx.coroutines.flow.StateFlow
import java.net.URLDecoder
import java.net.URLEncoder

/**
 * Page transitions take the shared motion vocabulary: a lateral tab switch is a
 * `toggle` (the same token the gallery's grid/list switch uses, so switching
 * tabs and switching modes feel like the same gesture), and a hierarchical push
 * is a `fade`.
 */
private fun <T> tabMotion(): FiniteAnimationSpec<T> = Motion.toggle()
private fun <T> pushMotion(): FiniteAnimationSpec<T> = Motion.fade()

/** The five bottom-nav destinations. Navigating between any two of these is a
 *  lateral "tab switch" (fade-through) rather than a hierarchical push. */
private val TOP_LEVEL_ROUTES = setOf(
    Screen.Feed.route,
    Screen.Search.route,
    Screen.Profile.route,
    Screen.MediaGallery.route,
    Screen.Dashboard.route,
)

/** True when both ends of the transition are top-level tabs. */
private fun AnimatedContentTransitionScope<NavBackStackEntry>.isTabSwitch(): Boolean {
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
    notificationManager: NotificationManager,
    pendingPostManager: PendingPostManager,
) {
    val navController = rememberNavController()
    val scope = rememberCoroutineScope()
    val backStackEntry by navController.currentBackStackEntryAsState()
    val currentRoute = backStackEntry?.destination?.route

    // Bottom bar visible only on top-level tab screens
    val showBottomBar = currentRoute in listOf(
        Screen.Feed.route,
        Screen.Search.route,
        Screen.MediaGallery.route,
        Screen.Dashboard.route,
        Screen.Profile.route,
    )

    val startDestination = if (isSetupComplete) Screen.Feed.route else Screen.SetupWizard.route

    // Account switcher state
    var showAccountSwitcher by remember { mutableStateOf(false) }
    val config by configStore.config.collectAsState()
    val activeHex by configStore.activeAccountHexPubkey.collectAsState()
    val profiles by nostrService.profiles.collectAsState()
    val activeProfile = profiles[activeHex]
    val isOwner = config.activeAccountNpub.isNullOrBlank()
    val unreadDMs by dmUnreadCount.collectAsState()
    val relayActivity by hasNewRelayActivity.collectAsState()

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
        navController.navigate(target.route) { launchSingleTop = true }
    }

    Box(modifier = modifier.fillMaxSize()) {
        NavHost(
            navController = navController,
            startDestination = startDestination,
            modifier = Modifier.fillMaxSize(),
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
                    onCompose = {
                        navController.navigate(Screen.ComposeNote.createRoute())
                    },
                    onReply = { noteId ->
                        navController.navigate(Screen.ComposeNote.createRoute(replyToNoteId = noteId))
                    },
                    onQuote = { noteId ->
                        navController.navigate(Screen.ComposeNote.createRoute(quoteToNoteId = noteId))
                    },
                    onNavigateToSettings = {
                        navController.navigate(Screen.Settings.route)
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
                )
            }

            composable(Screen.MediaGallery.route) {
                MediaGalleryScreen(
                    feedService = feedService,
                    onMediaClick = { index ->
                        navController.navigate(Screen.MediaViewer.createRoute(index))
                    },
                    onNoteClick = { noteId ->
                        navController.navigate(Screen.NoteDetail.createRoute(noteId))
                    },
                    onBlossomClick = {
                        navController.navigate(Screen.BlossomDashboard.route)
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
                    onGroups = {
                        navController.navigate(Screen.GroupList.route)
                    },
                )
            }

            composable(
                route = Screen.Profile.route,
                arguments = listOf(navArgument("pubkey") { type = NavType.StringType }),
            ) { entry ->
                val pubkey = entry.arguments?.getString("pubkey") ?: return@composable
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
                    onEditProfile = {
                        navController.navigate(Screen.ProfileEdit.route)
                    },
                    onCompose = {
                        navController.navigate(Screen.ComposeNote.createRoute())
                    },
                    onReply = { noteId ->
                        navController.navigate(Screen.ComposeNote.createRoute(replyToNoteId = noteId))
                    },
                    onQuote = { noteId ->
                        navController.navigate(Screen.ComposeNote.createRoute(quoteToNoteId = noteId))
                    },
                    onNavigateToDMs = {
                        navController.navigate(Screen.DMInbox.route)
                    },
                    onNavigateToSettings = {
                        navController.navigate(Screen.Settings.route)
                    },
                    onNavigateToDMThread = { pk ->
                        navController.navigate(Screen.DMThread.createRoute(pk))
                    },
                    onBack = { navController.popBackStack() },
                )
            }

            // ── Detail screens ────────────────────────────────────
            composable(
                route = Screen.ArticleReader.route,
                arguments = listOf(navArgument("noteId") { type = NavType.StringType }),
            ) {
                ArticleReaderScreen(
                    onBack = { navController.popBackStack() },
                    onProfileClick = { pubkey ->
                        navController.navigate(Screen.Profile.createRoute(pubkey))
                    },
                )
            }

            composable(
                route = Screen.NoteDetail.route,
                arguments = listOf(navArgument("noteId") { type = NavType.StringType }),
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
                route = Screen.DMThread.route,
                arguments = listOf(navArgument("pubkey") { type = NavType.StringType }),
            ) { entry ->
                val pubkey = entry.arguments?.getString("pubkey") ?: return@composable
                DMThreadScreen(
                    counterpartyPubkey = pubkey,
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
                ),
            ) { entry ->
                ComposeNoteScreen(
                    onPublished = { navController.popBackStack() },
                    onBack = { navController.popBackStack() },
                    onResumeDraft = { draftId, replyToId, quoteToId ->
                        // Replace the current composer with one bound to the chosen draft
                        // (matches iOS, which loads the draft into the open composer).
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
                )
            }

            composable(Screen.Drafts.route) {
                DraftsScreen(
                    onResumeDraft = { draftId, _, replyToId, quoteToId ->
                        navController.navigate(
                            Screen.ComposeNote.createRoute(
                                replyToNoteId = replyToId,
                                quoteToNoteId = quoteToId,
                                draftId = draftId,
                            )
                        )
                    },
                    onBack = { navController.popBackStack() },
                )
            }

            composable(Screen.ProfileEdit.route) {
                ProfileEditScreen(
                    onSaved = { navController.popBackStack() },
                    onBack = { navController.popBackStack() },
                )
            }

            // ── Groups ────────────────────────────────────────────
            composable(Screen.GroupList.route) {
                GroupListScreen(
                    onGroupClick = { groupId, relayUrl ->
                        val encoded = URLEncoder.encode(relayUrl, "UTF-8")
                        navController.navigate(Screen.GroupChat.createRoute(groupId, encoded))
                    },
                    onBrowse = {
                        navController.navigate(Screen.GroupBrowser.route)
                    },
                    onCreate = {
                        navController.navigate(Screen.GroupCreate.route)
                    },
                    onBack = { navController.popBackStack() },
                )
            }

            composable(
                route = Screen.GroupChat.route,
                arguments = listOf(
                    navArgument("groupId") { type = NavType.StringType },
                    navArgument("relayUrl") { type = NavType.StringType },
                ),
            ) { entry ->
                val groupId = entry.arguments?.getString("groupId") ?: return@composable
                val relayUrl = URLDecoder.decode(
                    entry.arguments?.getString("relayUrl") ?: return@composable, "UTF-8"
                )
                GroupChatScreen(
                    groupId = groupId,
                    relayUrl = relayUrl,
                    onInfo = {
                        val encoded = URLEncoder.encode(relayUrl, "UTF-8")
                        navController.navigate(Screen.GroupInfo.createRoute(groupId, encoded))
                    },
                    onProfileClick = { pubkey ->
                        navController.navigate(Screen.Profile.createRoute(pubkey))
                    },
                    onBack = { navController.popBackStack() },
                )
            }

            composable(
                route = Screen.GroupInfo.route,
                arguments = listOf(
                    navArgument("groupId") { type = NavType.StringType },
                    navArgument("relayUrl") { type = NavType.StringType },
                ),
            ) { entry ->
                val groupId = entry.arguments?.getString("groupId") ?: return@composable
                val relayUrl = URLDecoder.decode(
                    entry.arguments?.getString("relayUrl") ?: return@composable, "UTF-8"
                )
                GroupInfoScreen(
                    groupId = groupId,
                    relayUrl = relayUrl,
                    onProfileClick = { pubkey ->
                        navController.navigate(Screen.Profile.createRoute(pubkey))
                    },
                    onBack = { navController.popBackStack() },
                )
            }

            composable(Screen.GroupBrowser.route) {
                GroupBrowserScreen(
                    onGroupClick = { groupId, relayUrl ->
                        val encoded = URLEncoder.encode(relayUrl, "UTF-8")
                        navController.navigate(Screen.GroupChat.createRoute(groupId, encoded))
                    },
                    onBack = { navController.popBackStack() },
                )
            }

            composable(Screen.GroupCreate.route) {
                GroupCreateScreen(
                    onCreated = { navController.popBackStack() },
                    onBack = { navController.popBackStack() },
                )
            }

            // ── Wallet ────────────────────────────────────────────
            composable(Screen.Wallet.route) {
                WalletScreen(
                    onBack = { navController.popBackStack() },
                    onSweep = { navController.navigate(Screen.BitcoinSweep.route) },
                )
            }

            composable(Screen.BitcoinSweep.route) {
                BitcoinSweepScreen(
                    onBack = { navController.popBackStack() },
                )
            }

            // ── Settings ──────────────────────────────────────────
            composable(Screen.Settings.route) {
                SettingsScreen(
                    onNavigate = { screen -> navController.navigate(screen.route) },
                    onBack = { navController.popBackStack() },
                )
            }

            composable(Screen.AppearanceSettings.route) {
                AppearanceSettingsScreen(
                    onBack = { navController.popBackStack() },
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

            composable(Screen.AdvancedSettings.route) {
                AdvancedSettingsScreen(
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

            composable(Screen.RelayListEditor.route) {
                RelayListEditorScreen(
                    onBack = { navController.popBackStack() },
                )
            }

            composable(Screen.BlastrSettings.route) {
                BlastrSettingsScreen(
                    onBack = { navController.popBackStack() },
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

            // ── Dashboard ─────────────────────────────────────────
            composable(Screen.Dashboard.route) {
                DashboardScreen(
                    onNavigate = { screen -> navController.navigate(screen.route) },
                    onNoteClick = { noteId ->
                        navController.navigate(Screen.NoteDetail.createRoute(noteId))
                    },
                    onArticleClick = { noteId ->
                        navController.navigate(Screen.ArticleReader.createRoute(noteId))
                    },
                    onProfileClick = { pubkey ->
                        navController.navigate(Screen.Profile.createRoute(pubkey))
                    },
                    logStore = logStore,
                    feedService = feedService,
                )
            }

            composable(Screen.BlossomDashboard.route) {
                BlossomDashboardScreen(
                    onBack = { navController.popBackStack() },
                )
            }

            composable(Screen.LogViewer.route) {
                val currentLogs by logStore.logs.collectAsState()
                LogViewerScreen(
                    logs = currentLogs,
                    onBack = { navController.popBackStack() },
                )
            }

            // ── Media viewer ──────────────────────────────────────
            composable(
                route = Screen.MediaViewer.route,
                arguments = listOf(navArgument("index") { type = NavType.IntType }),
            ) { entry ->
                val index = entry.arguments?.getInt("index") ?: 0
                MediaViewerScreen(
                    initialIndex = index,
                    onBack = { navController.popBackStack() },
                    autoplayVideos = config.autoplayVideos,
                )
            }
        }

        // Floating bottom nav pill overlay
        if (showBottomBar) {
            // Reading the flag here scopes recomposition to the overlay — the
            // tab content (inside the NavHost) never re-renders on a flip. The
            // bar condenses on the scrollable list tabs (Feed/Media/Relay), so
            // tabs without scroll wiring stay expanded.
            val feedScrollingDown by feedService.feedScrollingDown.collectAsState()
            val condenseTab = currentRoute == Screen.Feed.route ||
                currentRoute == Screen.MediaGallery.route ||
                currentRoute == Screen.Dashboard.route
            val condensed = feedScrollingDown && condenseTab

            // Contextual condensed action (icon + tint + click), matching iOS:
            // compose on Feed, Blossom upload on Media, relay dashboard on Relay
            // (antenna tinted by live relay status).
            val colors = LocalNostrVaultColors.current
            val relayStatus by RelayForegroundService.relayStatus.collectAsState()
            val relayColor = when (relayStatus) {
                RelayForegroundService.RelayStatus.RUNNING -> SuccessGreen
                RelayForegroundService.RelayStatus.BOOTING,
                RelayForegroundService.RelayStatus.IMPORTING -> ZapOrange
                RelayForegroundService.RelayStatus.OFFLINE -> ErrorRed
            }
            val condensedActionIcon = when (currentRoute) {
                Screen.MediaGallery.route -> NostrVaultIcons.Blossom
                Screen.Dashboard.route -> NostrVaultIcons.Relay
                else -> NostrVaultIcons.Create
            }
            val condensedActionTint = if (currentRoute == Screen.Dashboard.route) relayColor else colors.primary
            val onCondensedAction: () -> Unit = when (currentRoute) {
                Screen.MediaGallery.route -> { { navController.navigate(Screen.BlossomDashboard.route) } }
                Screen.Dashboard.route -> { { feedService.requestRelayDashboard() } }
                else -> { { navController.navigate(Screen.ComposeNote.createRoute()) } }
            }

            Box(modifier = Modifier.align(Alignment.BottomCenter)) {
                BottomNavBar(
                    currentRoute = currentRoute,
                    activeAccountPubkey = activeHex,
                    activeAvatarUrl = activeProfile?.pictureURL,
                    activeDisplayName = activeProfile?.bestName,
                    isOwner = isOwner,
                    condensed = condensed,
                    hasUnreadDMs = unreadDMs > 0,
                    hasNewRelayActivity = relayActivity,
                    onNavigate = { screen ->
                        if (screen == Screen.Dashboard) {
                            RelayForegroundService.markRelayViewed()
                        }
                        val route = if (screen == Screen.Profile) {
                            Screen.Profile.createRoute(activeHex)
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
                        when (screen) {
                            Screen.Feed -> feedService.requestScrollToTop()
                            else -> {
                                // Other tabs: pop back to root if deep, otherwise no-op for now
                                navController.popBackStack(screen.route, inclusive = false)
                            }
                        }
                    },
                    onAccountSwitcher = { showAccountSwitcher = true },
                    condensedActionIcon = condensedActionIcon,
                    condensedActionTint = condensedActionTint,
                    onCondensedAction = onCondensedAction,
                    onExpand = { feedService.setFeedScrollingDown(false) },
                )
            }
        }

        // Pending post countdown banner
        PendingPostBanner(
            pendingPostManager = pendingPostManager,
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .padding(bottom = if (showBottomBar) 80.dp else 0.dp),
        )

        // Notification pill overlay at top
        NotificationOverlay(
            notificationManager = notificationManager,
            modifier = Modifier.align(Alignment.TopCenter),
        )
    }

    // Account switcher bottom sheet
    if (showAccountSwitcher) {
        val accounts = buildAccountInfos(config, profiles, includeWhitelisted = true)

        AccountSwitcherSheet(
            accounts = accounts,
            onSelectAccount = { npub ->
                // The open Profile screen is pinned to a pubkey nav arg, so unlike the
                // other tabs (which observe the active account reactively) it won't
                // follow an account switch on its own. If we're viewing our OWN profile,
                // re-navigate it to the newly active account. Leave it untouched when
                // viewing someone else's profile.
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
