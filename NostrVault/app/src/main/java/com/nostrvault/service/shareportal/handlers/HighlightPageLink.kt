package com.nostrvault.service.shareportal.handlers

import java.net.URI

/**
 * The optional "Page link" on a highlight that arrived without one. A text
 * menu's Share… sends only the selected words, so the person can paste the
 * page's address; it goes out as the highlight's `r` tag. Pure. Twin:
 * HighlightPageLink.swift, same cases (HighlightPageLinkTest).
 */
object HighlightPageLink {
    sealed interface Check {
        /** Nothing typed: the highlight goes out without a link. */
        data object Empty : Check
        /** A web address, with https:// added when it was left off. */
        data class Link(val url: String) : Check
        /** Typed but not a web address: Send/Publish wait until it is fixed or cleared. */
        data object NotALink : Check
    }

    const val LABEL = "Page link (optional)"
    const val HINT = "Text shared from a page's text menu has no link. Paste the page's address to link the highlight to it."
    const val PROBLEM = "That doesn't look like a web address."

    fun check(typed: String): Check {
        val s = typed.trim()
        if (s.isEmpty()) return Check.Empty
        if (s.any { it.isWhitespace() }) return Check.NotALink
        val lower = s.lowercase()
        val full = when {
            lower.startsWith("https://") || lower.startsWith("http://") -> s
            "://" in lower || lower.startsWith("//") -> return Check.NotALink
            else -> "https://$s"
        }
        val uri = runCatching { URI(full) }.getOrNull() ?: return Check.NotALink
        val scheme = uri.scheme?.lowercase()
        val host = uri.host
        if ((scheme != "https" && scheme != "http") || host == null ||
            '.' !in host || host.startsWith('.') || host.endsWith('.')
        ) return Check.NotALink
        return Check.Link(full)
    }

    /** The link to publish, or null (empty or not a link). */
    fun link(typed: String): String? = (check(typed) as? Check.Link)?.url
}
