package com.nostrvault.service.shareportal.handlers

/**
 * NIP-84 (kind 9802) tags for a highlight shared from another app. Pure.
 * Mirrors HighlightShareTags.swift; both platforms build exactly:
 *
 * - `["r", <url>, "source"]` when the share named a web page
 *
 * No `context` tag: the review card says "Delete what you don't want to
 * keep", so the full selection (which can come from any app's text menu, a
 * chat for example) must not go out behind the person's back. Phase 2 may add
 * it back only if the card shows it with a way to turn it off.
 * - `["comment", <comment>]` when the person added one (a quote highlight)
 * - `["alt", "Highlight: \"<passage>\""]`
 *
 * Values are trimmed. A highlight of text with no URL (Android's text menu)
 * carries no `r` tag.
 */
object HighlightShareTags {
    const val KIND = 9802

    fun tags(url: String?, passage: String, comment: String): List<List<String>> = buildList {
        val p = passage.trim()
        url?.trim()?.takeIf { it.isNotEmpty() }?.let { add(listOf("r", it, "source")) }
        comment.trim().takeIf { it.isNotEmpty() }?.let { add(listOf("comment", it)) }
        add(listOf("alt", "Highlight: \"$p\""))
    }
}
