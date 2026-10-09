package com.nostrvault.ui.screens.dm

import java.net.URI

/**
 * Photos in direct messages. A photo is uploaded to Blossom and its URL sent
 * on its own line of an ordinary DM (see DMThreadViewModel.sendMessage); the
 * thread shows such links as the photo. Same rules as iOS DMAttachment (#288).
 */
object DMAttachment {
    /** Image and GIF extensions, as iOS SupportedMediaFormats.imageOrGifExtensions. */
    private val imageOrGifExtensions = setOf(
        "jpg", "jpeg", "png", "webp", "heic", "avif", "tiff", "tif", "svg", "gif",
    )

    /** A message split for display: its text without the photo links, and the photos. */
    data class Parts(val text: String, val images: List<String>)

    /**
     * The photos [content] links, in order and without repeats, and the text
     * with those links taken out. Only http(s) links whose path ends in an
     * image or GIF extension count; anything else stays in the text as the
     * sender wrote it.
     */
    fun split(content: String): Parts {
        val images = mutableListOf<String>()
        val lines = content.split("\n").mapNotNull { line ->
            val kept = mutableListOf<String>()
            var removedAny = false
            for (word in line.split(" ")) {
                val url = imageUrl(word)
                if (url != null) {
                    if (url !in images) images.add(url)
                    removedAny = true
                } else {
                    kept.add(word)
                }
            }
            if (!removedAny) return@mapNotNull line
            val rest = kept.joinToString(" ").trim { it == ' ' || it == '\t' }
            rest.ifEmpty { null }
        }
        if (images.isEmpty()) return Parts(content, emptyList())
        return Parts(lines.joinToString("\n").trim(), images)
    }

    private fun imageUrl(word: String): String? {
        val token = word.trim()
        if (token.isEmpty()) return null
        val uri = runCatching { URI(token) }.getOrNull() ?: return null
        val scheme = uri.scheme?.lowercase()
        if (scheme != "https" && scheme != "http") return null
        if ((uri.host ?: uri.rawAuthority).isNullOrEmpty()) return null
        val lastSegment = uri.path.orEmpty().substringAfterLast('/')
        if (!lastSegment.contains('.')) return null
        val ext = lastSegment.substringAfterLast('.').lowercase()
        return if (ext in imageOrGifExtensions) token else null
    }
}
