package com.nostrvault.ui.screens.feed

import com.nostrvault.data.model.FeedProfile

/**
 * Who a zap pill says it is paying: the profile's best name, or the start of
 * the pubkey when no profile has loaded (the same fallback the reels use).
 */
fun zapRecipientName(profiles: Map<String, FeedProfile>, pubkey: String): String =
    profiles[pubkey]?.bestName ?: (pubkey.take(8) + "…")
