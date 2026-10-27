package com.nostrvault.ui.components

/**
 * Known aspect ratios for note media, so the feed can reserve the right box
 * *before* an image decodes instead of growing into it afterwards.
 *
 * A feed that reserves 200dp and then re-lays-out to the decoded ratio shifts
 * everything below each image once, by up to 400dp, exactly as you are reading
 * it. There are only two ways to avoid that: be told the size, or remember it.
 * Both are here.
 */

/**
 * Width ÷ height from a NIP-92 `imeta` tag's `dim <w>x<h>` field, or null.
 *
 * `imeta` is a flat tag: `["imeta", "url https://…", "dim 3024x4032", "m image/jpeg"]`.
 * This app's own composer does not write one, so this covers notes from clients
 * that do — which is most of them.
 */
internal fun imetaAspectRatio(tags: List<List<String>>, url: String): Float? {
    val dim = imetaField(tags, url, "dim") ?: return null
    val parts = dim.split('x', 'X')
    if (parts.size != 2) return null
    val w = parts[0].trim().toFloatOrNull() ?: return null
    val h = parts[1].trim().toFloatOrNull() ?: return null
    if (w <= 0f || h <= 0f) return null
    return w / h
}

/**
 * The value of one field (`dim`, `blurhash`, `image`, …) in the NIP-92 `imeta`
 * tag whose `url` is [url], or null. A field from another URL's tag is never
 * returned: in a two-image note that would dress the second in the first's data.
 */
internal fun imetaField(tags: List<List<String>>, url: String, field: String): String? {
    val prefix = "$field "
    for (tag in tags) {
        if (tag.firstOrNull() != "imeta" || tag.size < 2) continue
        val fields = tag.drop(1)
        val tagUrl = fields.firstOrNull { it.startsWith("url ") }?.removePrefix("url ")?.trim()
        if (tagUrl != url) continue
        val value = fields.firstOrNull { it.startsWith(prefix) }?.removePrefix(prefix)?.trim()
        if (!value.isNullOrEmpty()) return value
    }
    return null
}

/**
 * Ratios learned from images this process has already decoded.
 *
 * A `LazyColumn` disposes and recomposes rows as you scroll, so without this the
 * *same* image shifts the feed again every time it comes back. Bounded, because
 * a long session touches a lot of URLs and this is a convenience, not a cache of
 * anything expensive.
 *
 * Not persisted: a wrong remembered ratio would be a permanent layout bug for
 * that note, and the cost of relearning it is one decode the app is doing anyway.
 */
internal object MediaAspectCache {
    private const val MAX_ENTRIES = 512
    private val ratios = object : LinkedHashMap<String, Float>(64, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, Float>?): Boolean =
            size > MAX_ENTRIES
    }

    @Synchronized
    fun get(url: String): Float? = ratios[url]

    @Synchronized
    fun put(url: String, ratio: Float) {
        if (ratio > 0f && ratio.isFinite()) ratios[url] = ratio
    }

    @Synchronized
    fun clear() = ratios.clear()
}

/**
 * The best ratio available without decoding: what the author told us, else what
 * we learned earlier this session, else null (reserve a default and accept one
 * shift the first time this URL is seen).
 */
internal fun knownAspectRatio(tags: List<List<String>>, url: String): Float? =
    imetaAspectRatio(tags, url) ?: MediaAspectCache.get(url)

/**
 * The box a feed video gets: the author's `dim` while it agrees with the frame we decoded, else
 * the decoded frame. A phone records portrait as landscape pixels plus a rotate-90 flag, and many
 * clients write `dim` from those pixels (1920x1080 for an upright video), so trusting the tag gave
 * a portrait video a landscape box. The decoded poster has the rotation applied.
 */
internal fun videoBoxRatio(hinted: Float?, decoded: Float?): Float? {
    if (hinted != null && decoded != null && isPortrait(hinted) != isPortrait(decoded) &&
        !isSquareish(hinted) && !isSquareish(decoded)
    ) return decoded
    return hinted ?: decoded
}

private fun isPortrait(ratio: Float) = ratio < 1f
private fun isSquareish(ratio: Float) = ratio in 0.95f..1.05f

/**
 * The tallest a portrait video may stand in the feed, in dp: a little over half the screen, so one
 * video never fills it and the note's text and the next note stay in view. Never more than the
 * 600dp a portrait photo gets.
 */
internal fun feedVideoMaxHeightDp(screenHeightDp: Int): Float =
    minOf(600f, screenHeightDp * FEED_VIDEO_MAX_SCREEN_SHARE)

internal const val FEED_VIDEO_MAX_SCREEN_SHARE = 0.6f

/** Width ÷ height as the player shows the picture: its size times the pixel aspect ratio. 0 when not known yet. */
internal fun videoDisplayAspect(width: Int, height: Int, pixelWidthHeightRatio: Float): Float =
    if (width > 0 && height > 0) width * pixelWidthHeightRatio / height else 0f
