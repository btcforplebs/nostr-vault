package com.nostrvault.data.model

import java.util.Date

/**
 * The header of a NIP-23 long-form post, read off its tags.
 *
 * A kind-30023 event's content is Markdown and everything around it — title,
 * summary, cover image, the identifier it is addressed by — lives in tags. A
 * list of these can be rendered without touching the (potentially very long)
 * body.
 */
data class ArticleMeta(
    val title: String,
    val summary: String?,
    val imageUrl: String?,
    /** The "d" tag: what an naddr points at, and what makes a revision replace its predecessor. */
    val identifier: String?,
    /**
     * `published_at` when the author set it, otherwise the event's own
     * timestamp. Authors edit long-form posts, and each edit is a new event
     * with a new created_at, so ordering by that alone makes an old article
     * look new every time its typo is fixed.
     */
    val publishedAt: Date,
) {
    companion object {
        const val KIND = 30023

        /** Minutes to read [body] at 200 words a minute, at least 1; null when empty. iOS LongFormMetadata. */
        fun readingTimeMinutes(body: String): Int? {
            val words = body.split(Regex("\\s+")).count { it.isNotEmpty() }
            if (words == 0) return null
            return maxOf(1, (words + 199) / 200)
        }

        /**
         * What an article row says under its title: the author's summary, or
         * else the top of the body with the Markdown stripped — never raw
         * Markdown. iOS ArticleInlineBody.previewText.
         */
        fun previewText(summary: String?, body: String, limit: Int = 200): String? {
            if (!summary.isNullOrBlank()) return summary
            val plain = ArticleEngagement.plainText(body)
                .lineSequence()
                .map { it.trim() }
                .filter { it.isNotEmpty() && !it.matches(Regex("[-*_=]{3,}")) }
                .joinToString(" ")
            if (plain.isEmpty()) return null
            return if (plain.length > limit) plain.take(limit).trimEnd() + "…" else plain
        }

        fun from(note: FeedNote): ArticleMeta {
            fun tag(name: String): String? = note.tags
                .firstOrNull { it.size >= 2 && it[0] == name }
                ?.get(1)
                ?.takeIf { it.isNotBlank() }

            val published = tag("published_at")?.toLongOrNull()
                ?.let { Date(it * 1000) }
                ?: note.createdAt

            return ArticleMeta(
                // An untitled article is legal; falling back to the first line
                // of the body beats printing an empty row.
                title = tag("title")
                    ?: note.content.lineSequence()
                        .firstOrNull { it.isNotBlank() }
                        ?.removePrefix("#")?.trim()?.take(120)
                    ?: "Untitled",
                summary = tag("summary"),
                imageUrl = tag("image"),
                identifier = tag("d"),
                publishedAt = published,
            )
        }
    }
}
