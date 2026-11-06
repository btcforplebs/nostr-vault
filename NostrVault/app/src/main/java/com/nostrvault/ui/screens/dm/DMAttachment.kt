package com.nostrvault.ui.screens.dm

import java.net.URI

/**
 * Photos and videos in direct messages. A photo or video is uploaded to Blossom and its URL sent
 * on its own line of an ordinary DM (see DMThreadViewModel.sendMessage); the
 * thread shows such links as the photo. Same rules as iOS DMAttachment (#288).
 */
object DMAttachment {
    /** Image and GIF extensions, as iOS SupportedMediaFormats.imageOrGifExtensions. */
    private val imageOrGifExtensions = setOf(
        "jpg", "jpeg", "png", "webp", "heic", "avif", "tiff", "tif", "svg", "gif",
    )

    /** Video extensions, as iOS SupportedMediaFormats.videoExtensions. */
    private val videoExtensions = setOf("mp4", "mov", "webm", "m4v", "avi", "mkv", "3gp")

    /** A message split for display: its text without the media links, the photos and the videos. */
    data class Parts(val text: String, val images: List<String>, val videos: List<String> = emptyList())

    /**
     * A video's link as it is sent: its Blossom URL with the file's extension
     * when it has none, so the other app (which tells videos by extension)
     * shows it as a video (iOS DMAttachment.videoLink).
     */
    fun videoLink(url: String, extension: String): String {
        val lastSegment = runCatching { URI(url).path }.getOrNull().orEmpty().substringAfterLast('/')
        return if (lastSegment.contains('.') || extension.isEmpty()) url else "$url.$extension"
    }

    /**
     * The photos [content] links, in order and without repeats, and the text
     * with those links taken out. Only http(s) links whose path ends in an
     * image or GIF extension count; anything else stays in the text as the
     * sender wrote it. [withVideos] also takes out video links (a DM shows
     * them as videos; Live chat keeps them as text).
     */
    fun split(content: String, withVideos: Boolean = false): Parts {
        val images = mutableListOf<String>()
        val videos = mutableListOf<String>()
        val lines = content.split("\n").mapNotNull { line ->
            val kept = mutableListOf<String>()
            var removedAny = false
            for (word in line.split(" ")) {
                val url = mediaUrl(word, imageOrGifExtensions)
                val video = if (url == null && withVideos) mediaUrl(word, videoExtensions) else null
                if (url != null) {
                    if (url !in images) images.add(url)
                    removedAny = true
                } else if (video != null) {
                    if (video !in videos) videos.add(video)
                    removedAny = true
                } else {
                    kept.add(word)
                }
            }
            if (!removedAny) return@mapNotNull line
            val rest = kept.joinToString(" ").trim { it == ' ' || it == '\t' }
            rest.ifEmpty { null }
        }
        if (images.isEmpty() && videos.isEmpty()) return Parts(content, emptyList())
        return Parts(lines.joinToString("\n").trim(), images, videos)
    }

    private fun mediaUrl(word: String, extensions: Set<String>): String? {
        val token = word.trim()
        if (token.isEmpty()) return null
        val uri = runCatching { URI(token) }.getOrNull() ?: return null
        val scheme = uri.scheme?.lowercase()
        if (scheme != "https" && scheme != "http") return null
        if ((uri.host ?: uri.rawAuthority).isNullOrEmpty()) return null
        val lastSegment = uri.path.orEmpty().substringAfterLast('/')
        if (!lastSegment.contains('.')) return null
        val ext = lastSegment.substringAfterLast('.').lowercase()
        return if (ext in extensions) token else null
    }
}
