package com.nostrvault.ui.screens.feed

import com.nostrvault.tutorials.tutorialAnchor
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.*
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.flow.first
import com.nostrvault.data.model.FeedLayoutMode
import com.nostrvault.data.model.FeedMenuSettings
import com.nostrvault.data.model.FeedMode
import com.nostrvault.data.model.PopularFilter
import com.nostrvault.ui.components.GlassPill
import com.nostrvault.ui.components.blockedWhen
import com.nostrvault.ui.components.chromeFold
import com.nostrvault.ui.components.chromeReveal
import com.nostrvault.ui.components.rememberChromeFolded
import com.nostrvault.ui.theme.*
import com.nostrvault.service.FeedLanguage

// ── Top bar ──────────────────────────────────────────────────────

@Composable
internal fun FeedTopBar(
    feedMode: FeedMode,
    /// Folded past halfway with the bottom bar (the pieces fold continuously
    /// with the finger, via chromeFold): only the feed icon and the
    /// layout button stay, like the iOS top bar. Folded pieces take no taps.
    collapsed: Boolean,
    connectionStatus: String,
    layoutMode: FeedLayoutMode,
    autoLoad: Boolean,
    showReposts: Boolean,
    showReplies: Boolean,
    popularFilter: PopularFilter,
    showEngagementStats: Boolean,
    globalShowsEveryone: Boolean,
    globalFeedLanguages: List<String>,
    onToggleTrustScope: () -> Unit,
    onSetGlobalLanguages: (List<String>) -> Unit,
    /** The current feed's Following / Global choice; false = Following. */
    scopeGlobal: Boolean,
    onScopeFollowing: () -> Unit,
    onScopeGlobal: () -> Unit,
    /** The Polls feed's Open / Closed / All filter. */
    pollStatus: com.nostrvault.data.model.PollStatusFilter,
    onSetPollStatus: (com.nostrvault.data.model.PollStatusFilter) -> Unit,
    onModeChange: (FeedMode) -> Unit,
    onCycleLayoutMode: () -> Unit,
    onToggleAutoLoad: () -> Unit,
    onToggleReposts: () -> Unit,
    onToggleReplies: () -> Unit,
    onSetPopularFilter: (PopularFilter) -> Unit,
    onToggleEngagementStats: () -> Unit,
    onEditFeeds: () -> Unit,
    onOpenDashboard: () -> Unit,
    /** Posts are waiting and the floating "New Posts" button is up. */
    newPostsCount: Int,
    onLoadNewPosts: () -> Unit,
) {
    val colors = LocalNostrVaultColors.current
    var feedModeExpanded by remember { mutableStateOf(false) }
    // The reader's order, less hidden feeds (Edit Feeds).
    val menuStored by FeedMenuSettings.stored.collectAsState()
    val menuModes = remember(menuStored) { FeedMenuSettings.menuModes(menuStored) }

    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .statusBarsPadding()
            .padding(horizontal = 12.dp, vertical = 8.dp)
            // The list's top padding is this bar's height; holding it while
            // the pills fold keeps the feed from jumping under your thumb.
            .heightIn(min = 48.dp),
    ) {
        // ── Leading pill: one tap target. The icon names the current feed;
        // tapping anywhere on the pill opens the feed list, with Dashboard at the bottom of it
        // (the old separate dot opened the dashboard, and sat so close to the
        // feed menu that it was easy to hit by mistake). Folded, only the
        // icon is left, and it opens the same list.
        // No arrangement spacing: each folding piece carries its own gap, so the
        // folded pill closes into a circle around what it keeps.
        Box {
            GlassPill(
                horizontalArrangement = Arrangement.Start,
                modifier = Modifier
                    .tutorialAnchor(com.nostrvault.tutorials.TutorialContent.FEED_PICKER)
                    .clip(CircleShape)
                    .clickable(onClickLabel = "Switch feeds") { feedModeExpanded = true }
                    .semantics { contentDescription = "Feed: ${feedMode.displayName}, $connectionStatus" },
            ) {
                Box(
                    modifier = Modifier.size(30.dp),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(
                        imageVector = feedMode.icon,
                        contentDescription = null,
                        tint = PrimaryText,
                        modifier = Modifier.size(18.dp),
                    )
                }

                Box(Modifier.chromeFold(leadingGap = 6.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            text = feedMode.displayName,
                            color = PrimaryText,
                            fontSize = 17.sp,
                            fontWeight = FontWeight.Bold,
                            maxLines = 1,
                        )
                        Spacer(Modifier.width(2.dp))
                        Icon(
                            imageVector = NostrVaultIcons.ChevronDown,
                            contentDescription = null,
                            tint = PrimaryText,
                            modifier = Modifier.size(16.dp),
                        )
                        Spacer(Modifier.width(6.dp))
                    }
                }
            }

            DropdownMenu(
                expanded = feedModeExpanded,
                onDismissRequest = { feedModeExpanded = false },
            ) {
                menuModes.forEach { mode ->
                    DropdownMenuItem(
                        text = {
                            Text(
                                text = mode.displayName,
                                fontWeight = if (mode == feedMode) FontWeight.SemiBold else FontWeight.Normal,
                            )
                        },
                        leadingIcon = { Icon(mode.icon, contentDescription = null, modifier = Modifier.size(18.dp)) },
                        trailingIcon = if (mode == feedMode) {
                            { Icon(NostrVaultIcons.Check, contentDescription = "Current feed", modifier = Modifier.size(16.dp)) }
                        } else null,
                        onClick = {
                            onModeChange(mode)
                            feedModeExpanded = false
                        },
                    )
                }
                HorizontalDivider()
                // Your network's day. Activity only; feed settings are in Settings > Feed.
                DropdownMenuItem(
                    text = { Text("Dashboard") },
                    leadingIcon = { Icon(NostrVaultIcons.GridLayout, contentDescription = null, modifier = Modifier.size(18.dp)) },
                    onClick = {
                        feedModeExpanded = false
                        onOpenDashboard()
                    },
                )
                // Last, at the bottom of the list it edits (iOS #303).
                DropdownMenuItem(
                    text = { Text("Edit Feeds") },
                    leadingIcon = { Icon(NostrVaultIcons.EditFeeds, contentDescription = null, modifier = Modifier.size(18.dp)) },
                    onClick = {
                        feedModeExpanded = false
                        onEditFeeds()
                    },
                )
            }
        }

        // Folded, the floating "New Posts" button becomes a small pill centred
        // in this row, between the two circles (iOS `foldedNewPostsPill`).
        Box(Modifier.weight(1f), contentAlignment = Alignment.Center) {
            if (newPostsCount > 0) {
                val folded by rememberChromeFolded()
                NewPostsPill(
                    count = newPostsCount,
                    compact = true,
                    onClick = onLoadNewPosts,
                    modifier = Modifier.chromeReveal().blockedWhen(!folded),
                )
            }
        }

        // ── Trailing pill: compact toggle + mode-dependent filters.
        // Feeds without a layout button leave nothing to show collapsed.
        val hasLayouts = feedMode.hasLayoutButton
        AnimatedVisibility(
            visible = !(collapsed && !hasLayouts),
            enter = fadeIn(Motion.chrome()),
            exit = fadeOut(Motion.chrome()),
        ) { GlassPill(
            horizontalArrangement = Arrangement.Start,
            modifier = Modifier.tutorialAnchor(com.nostrvault.tutorials.TutorialContent.FEED_TOOLBAR),
        ) {
            // Layout mode toggle: expanded -> condensed -> threaded -> expanded.
            if (hasLayouts) IconButton(onClick = onCycleLayoutMode, modifier = Modifier.size(40.dp)) {
                val icon = when (layoutMode) {
                    FeedLayoutMode.EXPANDED -> NostrVaultIcons.ExpandedView
                    FeedLayoutMode.CONDENSED -> NostrVaultIcons.CompactView
                    FeedLayoutMode.THREADED -> NostrVaultIcons.ThreadedView
                }
                Icon(
                    imageVector = icon,
                    contentDescription = layoutMode.displayName,
                    tint = if (layoutMode != FeedLayoutMode.EXPANDED) colors.primary else SecondaryText,
                    modifier = Modifier.size(25.dp),
                )
            }

            // Mode-dependent filter buttons. Articles and the other non-note
            // feeds get only Following / Global and the shield: reposts,
            // replies and auto-load are all about kind-1 traffic.
            Box(Modifier.chromeFold(leadingGap = 4.dp).blockedWhen(collapsed)) { Row(verticalAlignment = Alignment.CenterVertically) { when (feedMode) {
                FeedMode.MUSIC -> {
                    com.nostrvault.ui.screens.music.MusicToolbarButtons()
                    MusicScopeNoteObserver()
                }
                // The hashtag sheet's rule: follows, then your Web of Trust or everyone.
                FeedMode.HASHTAGS -> TrustScopeButton(everyone = globalShowsEveryone, onClick = onToggleTrustScope)
                // One rule for every feed with the choice: Following, Global
                // (your Web of Trust, no warning), and the shield for Everyone.
                FeedMode.ARTICLES, FeedMode.RECIPES, FeedMode.LIVE, FeedMode.MARKETPLACE, FeedMode.REELS -> {
                    ScopeButtons(scopeGlobal, onScopeFollowing, onScopeGlobal)
                    if (scopeGlobal) TrustScopeButton(everyone = globalShowsEveryone, onClick = onToggleTrustScope)
                }
                // Polls is a view of the note list, so auto-load applies (iOS
                // keeps it next to the Open / Closed / All filter).
                FeedMode.POLLS -> {
                    ScopeButtons(scopeGlobal, onScopeFollowing, onScopeGlobal)
                    if (scopeGlobal) TrustScopeButton(everyone = globalShowsEveryone, onClick = onToggleTrustScope)
                    PollStatusFilterButton(selected = pollStatus, onChange = onSetPollStatus)
                    IconButton(onClick = onToggleAutoLoad, modifier = Modifier.size(32.dp)) {
                        Icon(
                            imageVector = if (autoLoad) NostrVaultIcons.AutoLoad else NostrVaultIcons.AutoLoadOff,
                            contentDescription = "Auto-load",
                            tint = if (autoLoad) colors.primary else SecondaryText,
                            modifier = Modifier.size(18.dp),
                        )
                    }
                }
                FeedMode.FOLLOWING, FeedMode.DISCOVERY, FeedMode.GLOBAL -> {
                    if (feedMode == FeedMode.GLOBAL) {
                        // Who Global shows, and in which languages (iOS #128/#133).
                        TrustScopeButton(everyone = globalShowsEveryone, onClick = onToggleTrustScope)
                        LanguageFilterButton(selected = globalFeedLanguages, onChange = onSetGlobalLanguages)
                    }
                    // Auto-load posts
                    IconButton(onClick = onToggleAutoLoad, modifier = Modifier.size(32.dp)) {
                        Icon(
                            imageVector = if (autoLoad) NostrVaultIcons.AutoLoad else NostrVaultIcons.AutoLoadOff,
                            contentDescription = "Auto-load",
                            tint = if (autoLoad) colors.primary else SecondaryText,
                            modifier = Modifier.size(18.dp),
                        )
                    }
                    // Show reposts
                    IconButton(onClick = onToggleReposts, modifier = Modifier.size(32.dp)) {
                        Icon(
                            imageVector = NostrVaultIcons.Repost,
                            contentDescription = "Reposts",
                            tint = if (showReposts) colors.primary else SecondaryText,
                            modifier = Modifier.size(18.dp),
                        )
                    }
                    // Show replies. Not on Global, where iOS has no Replies
                    // button either (#230): Global is the top-level firehose.
                    if (feedMode != FeedMode.GLOBAL) {
                        IconButton(onClick = onToggleReplies, modifier = Modifier.size(32.dp)) {
                            Icon(
                                imageVector = NostrVaultIcons.Chat,
                                contentDescription = "Replies",
                                tint = if (showReplies) colors.primary else SecondaryText,
                                modifier = Modifier.size(18.dp),
                            )
                        }
                    }
                }
                FeedMode.MEDIA -> {
                    ScopeButtons(scopeGlobal, onScopeFollowing, onScopeGlobal)
                    if (scopeGlobal) TrustScopeButton(everyone = globalShowsEveryone, onClick = onToggleTrustScope)
                }
                FeedMode.POPULAR -> {
                    // Who it ranks: one menu, not two toggles that undo each other.
                    PopularAudienceButton(selected = popularFilter, onSelect = onSetPopularFilter)
                    // The rank line above each post
                    IconButton(
                        onClick = onToggleEngagementStats,
                        modifier = Modifier
                            .size(32.dp)
                            .semantics { stateDescription = if (showEngagementStats) "Shown" else "Hidden" },
                    ) {
                        Icon(
                            imageVector = if (showEngagementStats) NostrVaultIcons.Popular else NostrVaultIcons.PopularOutline,
                            contentDescription = "Ranks",
                            tint = if (showEngagementStats) colors.primary else SecondaryText,
                            modifier = Modifier.size(18.dp),
                        )
                    }
                }
            } } }
        } }
    }
}

/**
 * Whether the top bar shows the layout button. Grids, card lists and Reels
 * ignore expanded / condensed / threaded, so the button there would cycle an
 * icon and nothing else: Reels, Marketplace, Live, Music and Articles
 * (iOS `currentFeedHasLayouts`, FeedView+Layout.swift).
 */
internal val FeedMode.hasLayoutButton: Boolean
    get() = this !in setOf(FeedMode.REELS, FeedMode.MARKETPLACE, FeedMode.LIVE, FeedMode.MUSIC, FeedMode.ARTICLES)

/**
 * Who Global (and Media's Global) shows: the shield is your Web of Trust, the
 * crossed-out shield (in orange) is everyone: not a globe, which is Global's
 * own button. One button, so the pill keeps its width.
 */
@Composable
private fun TrustScopeButton(everyone: Boolean, onClick: () -> Unit) {
    val colors = LocalNostrVaultColors.current
    IconButton(
        onClick = onClick,
        modifier = Modifier
            .size(32.dp)
            .semantics {
                stateDescription = if (everyone) "Everyone" else "Web of Trust"
            },
    ) {
        Icon(
            imageVector = if (everyone) NostrVaultIcons.TrustOff else NostrVaultIcons.TrustShield,
            contentDescription = if (everyone) {
                "Everyone: unfiltered posts. Tap for your Web of Trust"
            } else {
                "Web of Trust: people you follow and the people they follow. Tap for everyone"
            },
            tint = if (everyone) ZapOrange else colors.primary,
            modifier = Modifier.size(18.dp),
        )
    }
}

/** Name in the Popular audience menu. iOS `PopularFilter.menuTitle`. */
internal val PopularFilter.menuTitle: String
    get() = when (this) {
        PopularFilter.ALL -> "Everyone"
        PopularFilter.FOLLOWS -> "People you follow"
        PopularFilter.NON_FOLLOWS -> "People you don't follow"
    }

private val PopularFilter.icon
    get() = when (this) {
        PopularFilter.ALL -> NostrVaultIcons.PeopleOutline
        PopularFilter.FOLLOWS -> NostrVaultIcons.People
        PopularFilter.NON_FOLLOWS -> NostrVaultIcons.Globe
    }

/**
 * Everyone / People you follow / People you don't follow, as one button in
 * the Popular toolbar. Tinted only while it narrows the feed. iOS PopularAudienceMenu.
 */
@Composable
private fun PopularAudienceButton(selected: PopularFilter, onSelect: (PopularFilter) -> Unit) {
    val colors = LocalNostrVaultColors.current
    var expanded by remember { mutableStateOf(false) }
    Box {
        IconButton(
            onClick = { expanded = true },
            modifier = Modifier
                .size(40.dp)
                .semantics { stateDescription = selected.menuTitle },
        ) {
            Icon(
                imageVector = selected.icon,
                contentDescription = "Popular from",
                tint = if (selected == PopularFilter.ALL) SecondaryText else colors.primary,
                modifier = Modifier.size(18.dp),
            )
        }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            PopularFilter.entries.forEach { filter ->
                DropdownMenuItem(
                    text = { Text(filter.menuTitle) },
                    leadingIcon = {
                        Icon(
                            imageVector = if (filter == selected) NostrVaultIcons.Check else filter.icon,
                            contentDescription = if (filter == selected) "Selected" else null,
                            modifier = Modifier.size(18.dp),
                        )
                    },
                    onClick = {
                        expanded = false
                        onSelect(filter)
                    },
                )
            }
        }
    }
}

/** The Polls feed's Open / Closed / All menu. iOS PollStatusFilterMenu. */
@Composable
private fun PollStatusFilterButton(
    selected: com.nostrvault.data.model.PollStatusFilter,
    onChange: (com.nostrvault.data.model.PollStatusFilter) -> Unit,
) {
    val colors = LocalNostrVaultColors.current
    var expanded by remember { mutableStateOf(false) }
    val all = selected == com.nostrvault.data.model.PollStatusFilter.ALL
    Box {
        IconButton(
            onClick = { expanded = true },
            modifier = Modifier
                .size(32.dp)
                .semantics { stateDescription = selected.label },
        ) {
            Icon(
                imageVector = NostrVaultIcons.FilterMenu,
                contentDescription = "Poll status",
                tint = if (all) SecondaryText else colors.primary,
                modifier = Modifier.size(18.dp),
            )
        }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            com.nostrvault.data.model.PollStatusFilter.entries.forEach { filter ->
                DropdownMenuItem(
                    text = { Text(filter.label) },
                    leadingIcon = {
                        if (filter == selected) {
                            Icon(NostrVaultIcons.Check, contentDescription = "Selected", modifier = Modifier.size(18.dp))
                        }
                    },
                    onClick = {
                        expanded = false
                        onChange(filter)
                    },
                )
            }
        }
    }
}

/**
 * Global's language picker. Pick any number of languages; none picked shows
 * every language. The menu stays open between picks so several can be
 * chosen in one go, as on iOS. The device's own languages come first.
 */
@Composable
private fun LanguageFilterButton(selected: List<String>, onChange: (List<String>) -> Unit) {
    val colors = LocalNostrVaultColors.current
    var expanded by remember { mutableStateOf(false) }
    val languages = remember {
        val locales = android.os.LocaleList.getDefault()
        FeedLanguage.pickerList((0 until locales.size()).map { locales[it].toLanguageTag() })
    }
    Box {
        IconButton(
            onClick = { expanded = true },
            modifier = Modifier
                .size(32.dp)
                .semantics { stateDescription = FeedLanguage.summary(selected) },
        ) {
            Icon(
                imageVector = if (selected.isEmpty()) NostrVaultIcons.LanguagesOutline else NostrVaultIcons.Languages,
                contentDescription = "Languages",
                tint = if (selected.isEmpty()) SecondaryText else colors.primary,
                modifier = Modifier.size(18.dp),
            )
        }
        DropdownMenu(
            expanded = expanded,
            onDismissRequest = { expanded = false },
            modifier = Modifier.heightIn(max = 420.dp),
        ) {
            DropdownMenuItem(
                text = { Text("All languages") },
                leadingIcon = {
                    Icon(
                        imageVector = if (selected.isEmpty()) NostrVaultIcons.Check else NostrVaultIcons.GlobeOutline,
                        contentDescription = null,
                        modifier = Modifier.size(18.dp),
                    )
                },
                onClick = { onChange(emptyList()) },
            )
            HorizontalDivider()
            languages.forEach { language ->
                val isOn = language.code in selected
                DropdownMenuItem(
                    text = { Text(language.displayName()) },
                    leadingIcon = {
                        if (isOn) {
                            Icon(NostrVaultIcons.Check, contentDescription = "Selected", modifier = Modifier.size(18.dp))
                        } else {
                            Spacer(Modifier.size(18.dp))
                        }
                    },
                    onClick = {
                        onChange(if (isOn) selected - language.code else selected + language.code)
                    },
                )
            }
        }
    }
}

/** Following and Global, the pair every feed with the choice shows. */
@Composable
private fun ScopeButtons(global: Boolean, onFollowing: () -> Unit, onGlobal: () -> Unit) {
    val colors = LocalNostrVaultColors.current
    IconButton(onClick = onFollowing, modifier = Modifier.size(40.dp)) {
        Icon(
            imageVector = if (!global) NostrVaultIcons.People else NostrVaultIcons.PeopleOutline,
            contentDescription = "Following",
            tint = if (!global) colors.primary else SecondaryText,
            modifier = Modifier.size(18.dp),
        )
    }
    IconButton(onClick = onGlobal, modifier = Modifier.size(40.dp)) {
        Icon(
            imageVector = if (global) NostrVaultIcons.Globe else NostrVaultIcons.GlobeOutline,
            contentDescription = "Global",
            tint = if (global) colors.primary else SecondaryText,
            modifier = Modifier.size(18.dp),
        )
    }
}
