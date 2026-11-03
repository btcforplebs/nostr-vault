package com.nostrvault.service.shareportal

/**
 * Article clip → the title and body of an article draft (contract §6.1):
 * quote + link, never a copy of the page. Pure. Twin: ArticleClipDraft.swift.
 */
object ArticleClipDraft {
    data class Clip(val title: String, val body: String)

    fun clip(title: String?, url: String?, selection: String?): Clip {
        val t = title?.trim().orEmpty().ifEmpty { url?.let(::host) ?: "Clipped link" }
        val parts = mutableListOf<String>()
        val q = selection?.trim().orEmpty()
        if (q.isNotEmpty()) parts += q.split("\n").joinToString("\n") { if (it.isBlank()) ">" else "> $it" }
        sourceLine(t, url)?.let { parts += it }
        return Clip(t, parts.joinToString("\n\n"))
    }

    /** `Source: [label](url)`, or null with no URL. Shared by the recipe draft. */
    fun sourceLine(label: String, url: String?): String? {
        if (url.isNullOrEmpty()) return null
        val l = label.replace("\\", "\\\\").replace("[", "\\[").replace("]", "\\]")
        val u = url.replace(" ", "%20").replace("(", "%28").replace(")", "%29")
        return "Source: [$l]($u)"
    }

    /** Lowercase host of an http(s) URL, as the contract's reference parses it. */
    fun host(url: String): String? {
        val m = Regex("^(?i)https?://([^/?#]*)").find(url) ?: return null
        return m.groupValues[1].lowercase().substringAfterLast('@').substringBefore(':').ifEmpty { null }
    }
}
