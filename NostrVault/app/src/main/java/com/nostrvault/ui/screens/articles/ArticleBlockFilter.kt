package com.nostrvault.ui.screens

import com.nostrvault.data.model.ArticleEngagementEvent
import com.nostrvault.data.model.ArticleHighlight
import com.nostrvault.data.model.ArticleTallies
import com.nostrvault.data.model.BlockedPeople

/**
 * An article's highlights, likes and comments with blocked people's taken
 * out, before they are counted or drawn, so a blocked person's words and
 * picture never show under an article and their comments are not counted.
 *
 * Zap receipts stay: they are signed by the recipient's Lightning provider,
 * not by whoever sent the zap. iOS: ArticleBlockFilter.swift.
 */
object ArticleBlockFilter {
    fun visibleEvents(events: List<ArticleEngagementEvent>, blocked: Set<String>): List<ArticleEngagementEvent> =
        if (blocked.isEmpty()) events
        else events.filter { it.kind == ArticleTallies.ZAP_RECEIPT_KIND || !BlockedPeople.isBlocked(it.pubkey, blocked) }

    fun visibleHighlights(highlights: List<ArticleHighlight>, blocked: Set<String>): List<ArticleHighlight> =
        if (blocked.isEmpty()) highlights
        else highlights.filterNot { BlockedPeople.isBlocked(it.pubkey, blocked) }
}
