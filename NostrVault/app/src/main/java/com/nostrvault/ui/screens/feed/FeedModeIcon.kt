package com.nostrvault.ui.screens.feed

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.runtime.*
import com.nostrvault.data.model.FeedMode
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.ui.theme.*

/**
 * The subset of [profiles] this list of pubkeys names, dropping the ones the
 * relay has not answered yet. Small by construction — a handful of entries per
 * feed row — so a card is handed only what it can draw rather than the whole
 * profile cache.
 */
internal fun List<String>.resolveAgainst(
    profiles: Map<String, FeedProfile>,
): Map<String, FeedProfile> {
    if (isEmpty()) return emptyMap()
    val resolved = HashMap<String, FeedProfile>(size)
    for (pubkey in this) profiles[pubkey]?.let { resolved[pubkey] = it }
    return resolved
}

/** Icon for the feed picker and the top bar; matches the iPhone's. */
internal val FeedMode.icon: ImageVector
    get() = when (this) {
        FeedMode.FOLLOWING -> NostrVaultIcons.People
        FeedMode.DISCOVERY -> NostrVaultIcons.Discover
        FeedMode.GLOBAL -> NostrVaultIcons.Globe
        FeedMode.POPULAR -> NostrVaultIcons.Popular
        FeedMode.MEDIA -> NostrVaultIcons.Media
        FeedMode.REELS -> NostrVaultIcons.Reels
        FeedMode.ARTICLES -> NostrVaultIcons.Articles
        FeedMode.RECIPES -> NostrVaultIcons.Recipes
        FeedMode.POLLS -> NostrVaultIcons.Polls
        FeedMode.LIVE -> NostrVaultIcons.Live
        FeedMode.MARKETPLACE -> NostrVaultIcons.Marketplace
        FeedMode.MUSIC -> NostrVaultIcons.Music
        FeedMode.HASHTAGS -> NostrVaultIcons.TagIcon
    }
