package com.nostrvault.service.shareportal.handlers

/**
 * NIP-84 (kind 9802) tags for a highlight shared from another app. Pure.
 * Mirrors HighlightShareTags.swift; both platforms build exactly:
 *
 * - `["r", <url>, "source"]` when the share named a web page
 * - `["context", <selection>]` when the passage was trimmed from a longer selection
 * - `["comment", <comment>]` when the person added one (a quote highlight)
 * - `["alt", "Highlight: \"<passage>\""]`
 *
 * Values are trimmed. A highlight of text with no URL (Android's text menu)
 * carries no `r` tag.
 */
object HighlightShareTags {
    const val KIND = 9802

    fun tags(url: String?, selection: String?, passage: String, comment: String): List<List<String>> = buildList {
        val p = passage.trim()
        url?.trim()?.takeIf { it.isNotEmpty() }?.let { add(listOf("r", it, "source")) }
        selection?.trim()?.takeIf { it.isNotEmpty() && it != p }?.let { add(listOf("context", it)) }
        comment.trim().takeIf { it.isNotEmpty() }?.let { add(listOf("comment", it)) }
        add(listOf("alt", "Highlight: \"$p\""))
    }
}
