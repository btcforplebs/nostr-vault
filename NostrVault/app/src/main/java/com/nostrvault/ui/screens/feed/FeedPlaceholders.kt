package com.nostrvault.ui.screens.feed

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.data.model.FeedMode
import com.nostrvault.ui.theme.*

// ── Empty state ──────────────────────────────────────────────────

// iOS FeedView empty state: thin gradient icon, bold title, monospaced
// subtitle, and a full-width gradient "Refresh Feed" button.
/**
 * iOS's empty states for the feeds with a Following / Global choice. Recipes,
 * Marketplace and Live: from your follows, with a Show Global button;
 * otherwise what came back, with Try again; and "Could not reach any relay"
 * when no relay answered ([loadFailed]). Articles and Media just say which
 * side came back empty, with no button.
 */
internal data class ScopedEmptyText(
    val title: String,
    val subtitle: String,
    /** The button's label, or null for none. */
    val action: String?,
    val showsGlobal: Boolean,
    /** Draw the no-connection icon rather than the feed's own. */
    val noConnection: Boolean = false,
)

internal fun scopedEmptyText(mode: FeedMode, scopeFollowing: Boolean, loadFailed: Boolean = false): ScopedEmptyText? {
    // These feeds come from other people's relays; with none answering, an
    // empty grid is not "nothing posted" (iOS RecipeFeedService.loadFailed).
    val needsConnection = when (mode) {
        FeedMode.RECIPES -> "Recipes"
        FeedMode.MARKETPLACE -> "Listings"
        FeedMode.LIVE -> "Live streams"
        else -> null
    }
    if (loadFailed && needsConnection != null) {
        return ScopedEmptyText(
            "Could not reach any relay",
            "$needsConnection come from other people's relays, so this one needs a connection.",
            "Try again", false, noConnection = true,
        )
    }
    return when (mode) {
        FeedMode.RECIPES -> if (scopeFollowing) ScopedEmptyText(
            "No recipes from your follows",
            "Nobody you follow has posted a recipe. Switch to Global to see everyone's.",
            "Show Global recipes", true,
        ) else ScopedEmptyText("No recipes found", "Nothing tagged zapcooking or nostrcooking came back.", "Try again", false)
        FeedMode.MARKETPLACE -> if (scopeFollowing) ScopedEmptyText(
            "No listings from your follows",
            "Nobody you follow is selling anything. Switch to Global to see every listing.",
            "Show Global listings", true,
        ) else ScopedEmptyText("No listings found", "No products, auctions or classifieds with a photo came back.", "Try again", false)
        FeedMode.LIVE -> if (scopeFollowing) ScopedEmptyText(
            "Nobody you follow is live",
            "Switch to Global to see everyone who is streaming.",
            "Show Global streams", true,
        ) else ScopedEmptyText(
            "Nothing live right now",
            "Most stream announcements on Nostr are for streams that already ended. Only running ones show here.",
            "Try again", false,
        )
        // iOS FeedView.emptyArticlesStateView.
        FeedMode.ARTICLES -> ScopedEmptyText(
            "No articles yet",
            if (scopeFollowing) "Long-form posts from people you follow show up here. Nothing to read yet."
            else "Long-form posts from across Nostr show up here. Nothing to read yet.",
            null, false,
        )
        // iOS FeedView.mediaGridView (feed.media.empty.*).
        FeedMode.MEDIA -> ScopedEmptyText(
            "No Media Found",
            if (scopeFollowing) "Your followers haven't shared any media yet."
            else "No global media found on connected relays.",
            null, false,
        )
        else -> null
    }
}

@Composable
internal fun ScopedEmptyPlaceholder(
    mode: FeedMode,
    scopeFollowing: Boolean,
    onRefresh: () -> Unit,
    onShowGlobal: () -> Unit,
    subtitleOverride: String? = null,
    loadFailed: Boolean = false,
) {
    val text = scopedEmptyText(mode, scopeFollowing, loadFailed)
    if (text == null) {
        EmptyFeedPlaceholder(mode, onRefresh = onRefresh, subtitleOverride = subtitleOverride)
        return
    }
    EmptyFeedPlaceholder(
        mode,
        onRefresh = when {
            text.action == null -> null
            text.showsGlobal -> onShowGlobal
            else -> onRefresh
        },
        // A failed load says why, whatever the caller would have said.
        subtitleOverride = if (text.noConnection) text.subtitle else subtitleOverride ?: text.subtitle,
        titleOverride = text.title,
        actionLabel = text.action ?: "",
        iconOverride = if (text.noConnection) NostrVaultIcons.NoConnection else null,
    )
}

/**
 * iOS FeedView's loading screens (loadingContactsView, loadingExtendedNetworkView,
 * loadingPopularView): a large spinner, a bold title, a monospaced line of
 * what it is doing, and a faint footer.
 */
@Composable
internal fun FeedLoadingPlaceholder(title: String, detail: String, footer: String) {
    val colors = LocalNostrVaultColors.current
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
        modifier = Modifier
            .fillMaxSize()
            .padding(horizontal = 24.dp)
            .semantics(mergeDescendants = true) {},
    ) {
        CircularProgressIndicator(color = colors.primary)
        Spacer(Modifier.height(16.dp))
        Text(
            text = title,
            color = PrimaryText,
            fontSize = 18.sp,
            fontWeight = FontWeight.Bold,
            letterSpacing = 0.3.sp,
            textAlign = TextAlign.Center,
        )
        Spacer(Modifier.height(8.dp))
        Text(
            text = detail,
            color = SecondaryText,
            fontSize = 13.sp,
            fontFamily = FontFamily.Monospace,
            textAlign = TextAlign.Center,
        )
        Spacer(Modifier.height(32.dp))
        Text(
            text = footer,
            color = SecondaryText.copy(alpha = SecondaryText.alpha * 0.6f),
            fontSize = 12.sp,
            fontWeight = FontWeight.Medium,
            fontFamily = FontFamily.Monospace,
            letterSpacing = 0.5.sp,
            textAlign = TextAlign.Center,
        )
    }
}

/**
 * iOS emptyStateView while the relay boots: a spinner, "Relay Starting...",
 * and what the relay is doing right now, else "Initializing relay".
 */
@Composable
internal fun RelayStartingPlaceholder(bootStatus: String) {
    val colors = LocalNostrVaultColors.current
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
        modifier = Modifier
            .fillMaxSize()
            .padding(horizontal = 24.dp)
            .semantics(mergeDescendants = true) {},
    ) {
        CircularProgressIndicator(color = colors.primary)
        Spacer(Modifier.height(16.dp))
        Text(
            text = "Relay Starting...",
            color = PrimaryText,
            fontSize = 22.sp,
            fontWeight = FontWeight.Bold,
            letterSpacing = 0.2.sp,
        )
        Spacer(Modifier.height(12.dp))
        Text(
            text = bootStatus.ifEmpty { "Initializing relay" },
            color = SecondaryText,
            fontSize = 13.sp,
            fontFamily = FontFamily.Monospace,
            letterSpacing = 0.3.sp,
            textAlign = TextAlign.Center,
        )
    }
}

@Composable
internal fun ImportingFeedPlaceholder(statusMessage: String) {
    val colors = LocalNostrVaultColors.current
    val stage = com.nostrvault.setup.ImportTourStage.from(statusMessage, completed = false).text
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(16.dp, Alignment.CenterVertically),
        modifier = Modifier
            .fillMaxSize()
            .padding(32.dp)
            .semantics(mergeDescendants = true) {},
    ) {
        CircularProgressIndicator(color = colors.primary)
        Text(
            text = "Your feed fills in as your notes come home",
            color = PrimaryText,
            fontSize = 20.sp,
            fontWeight = FontWeight.Bold,
            textAlign = TextAlign.Center,
        )
        Text(
            text = stage,
            color = SecondaryText,
            fontSize = 13.sp,
            textAlign = TextAlign.Center,
        )
    }
}

@Composable
internal fun EmptyFeedPlaceholder(
    mode: FeedMode,
    onRefresh: (() -> Unit)? = null,
    /// Overrides the per-mode subtitle. Discovery uses it to say which of the
    /// two reasons its feed is empty — see the call site in FeedScreen.
    subtitleOverride: String? = null,
    titleOverride: String? = null,
    /** What the button under the text says; it runs [onRefresh]. */
    actionLabel: String = "Refresh Feed",
    /** Replaces the feed's own icon: "Could not reach any relay" draws no-connection. */
    iconOverride: androidx.compose.ui.graphics.vector.ImageVector? = null,
) {
    val colors = LocalNostrVaultColors.current
    val gradient = Brush.linearGradient(listOf(colors.primary, colors.primaryLight))
    Box(
        contentAlignment = Alignment.Center,
        modifier = Modifier
            .fillMaxSize()
            .padding(horizontal = 24.dp),
    ) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Icon(
                imageVector = iconOverride ?: when (mode) {
                    FeedMode.FOLLOWING -> NostrVaultIcons.PersonAdd
                    FeedMode.DISCOVERY -> NostrVaultIcons.GlobeOutline
                    FeedMode.GLOBAL -> NostrVaultIcons.Globe
                    FeedMode.POPULAR -> NostrVaultIcons.BarChart
                    FeedMode.MEDIA -> NostrVaultIcons.Media
                    FeedMode.ARTICLES -> NostrVaultIcons.Articles
                    FeedMode.RECIPES -> NostrVaultIcons.Recipes
                    FeedMode.POLLS -> NostrVaultIcons.Polls
                    FeedMode.LIVE -> NostrVaultIcons.Live
                    FeedMode.MARKETPLACE -> NostrVaultIcons.Marketplace
                    FeedMode.REELS -> NostrVaultIcons.Reels
                    FeedMode.MUSIC -> NostrVaultIcons.Music
                    FeedMode.HASHTAGS -> NostrVaultIcons.TagIcon
                },
                contentDescription = null,
                tint = colors.primaryLight,
                modifier = Modifier.size(56.dp),
            )
            Spacer(Modifier.height(16.dp))
            Text(
                text = titleOverride ?: when (mode) {
                    FeedMode.FOLLOWING -> "No Following Feed"
                    FeedMode.DISCOVERY -> "No Discovery Feed"
                    FeedMode.GLOBAL -> "No Global Notes Yet"
                    FeedMode.POPULAR -> "No Popular Notes Found"
                    FeedMode.MEDIA -> "No Media Found"
                    FeedMode.ARTICLES -> "No Articles Yet"
                    FeedMode.RECIPES -> "No Recipes Yet"
                    FeedMode.POLLS -> "No polls yet"
                    FeedMode.LIVE -> "Nothing Live"
                    FeedMode.MARKETPLACE -> "No Listings"
                    FeedMode.REELS -> "No Videos Yet"
                    FeedMode.MUSIC -> "No Music"
                    FeedMode.HASHTAGS -> "No Hashtags"
                },
                color = PrimaryText,
                fontSize = 22.sp,
                fontWeight = FontWeight.Bold,
                letterSpacing = 0.2.sp,
            )
            Spacer(Modifier.height(12.dp))
            Text(
                text = subtitleOverride ?: when (mode) {
                    FeedMode.FOLLOWING -> "Follow npubs on Nostr to see their posts here"
                    FeedMode.DISCOVERY -> "Follow more people on Nostr to build your extended network"
                    FeedMode.GLOBAL -> "Waiting for notes from your feed relays"
                    FeedMode.POPULAR -> "Not enough engagement data from relays.\nCheck back later or try refreshing."
                    FeedMode.MEDIA -> "Photos and videos from your feed show up here"
                    FeedMode.ARTICLES -> "Long-form posts in your vault show up here"
                    FeedMode.RECIPES -> "Recipes from zap.cooking show up here"
                    FeedMode.POLLS -> "Polls from people you follow show up here"
                    FeedMode.LIVE -> "Streams that are running right now show up here"
                    FeedMode.MARKETPLACE -> "Items for sale on Nostr show up here"
                    FeedMode.REELS -> "Videos from your feed show up here"
                    FeedMode.MUSIC -> "Songs from Wavlake show up here"
                    FeedMode.HASHTAGS -> "Posts in the hashtags you follow show up here"
                },
                color = SecondaryText,
                fontSize = 13.sp,
                fontFamily = FontFamily.Monospace,
                letterSpacing = 0.3.sp,
                textAlign = TextAlign.Center,
            )
            if (onRefresh != null) {
                Spacer(Modifier.height(40.dp))
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                    modifier = Modifier
                        .fillMaxWidth()
                        .background(gradient, RoundedCornerShape(10.dp))
                        .clickable(onClick = onRefresh)
                        .padding(vertical = 14.dp),
                ) {
                    Spacer(Modifier.weight(1f))
                    Icon(
                        imageVector = NostrVaultIcons.Refresh,
                        contentDescription = null,
                        tint = Color.Black,
                        modifier = Modifier.size(16.dp),
                    )
                    Text(
                        text = actionLabel,
                        color = Color.Black,
                        fontSize = 14.sp,
                        fontWeight = FontWeight.SemiBold,
                    )
                    Spacer(Modifier.weight(1f))
                }
            }
        }
    }
}
