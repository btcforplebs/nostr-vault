package com.nostrvault.ui.screens

import com.nostrvault.data.model.ArticleEngagementEvent
import com.nostrvault.data.model.ArticleHighlight
import com.nostrvault.data.model.ArticleTallies
import com.nostrvault.data.model.BlockedPeople
import com.nostrvault.data.model.TrustGate

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

    /**
     * Comments split for the "Outside your web" fold ([TrustGate]): likes
     * and zap receipts always stay in (a like says nothing, a receipt is the
     * provider's), comments from outside your web go to the second list.
     */
    fun splitComments(
        events: List<ArticleEngagementEvent>,
        trusted: Set<String>?,
        always: Set<String>,
    ): Pair<List<ArticleEngagementEvent>, List<ArticleEngagementEvent>> =
        events.partition { it.kind == ArticleTallies.REACTION_KIND || it.kind == ArticleTallies.ZAP_RECEIPT_KIND || TrustGate.allows(it.pubkey, trusted, always) }
}
