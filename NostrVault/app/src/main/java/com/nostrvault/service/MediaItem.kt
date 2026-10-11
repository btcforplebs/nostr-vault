package com.nostrvault.service

data class MediaItem(
    val url: String,
    val type: MediaType,
    val pubkey: String? = null,
    val tags: List<List<String>>? = null,
    val mimeType: String? = null,
    val createdAt: Long = 0L,
) {
    val isAnimatedGIF: Boolean
        get() = url.lowercase().endsWith(".gif")
}
