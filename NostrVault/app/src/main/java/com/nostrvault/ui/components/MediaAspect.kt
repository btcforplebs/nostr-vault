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
    for (tag in tags) {
        if (tag.firstOrNull() != "imeta" || tag.size < 2) continue
        val fields = tag.drop(1)
        val tagUrl = fields.firstOrNull { it.startsWith("url ") }?.removePrefix("url ")?.trim()
        if (tagUrl != url) continue
        val dim = fields.firstOrNull { it.startsWith("dim ") }?.removePrefix("dim ")?.trim()
            ?: continue
        val parts = dim.split('x', 'X')
        if (parts.size != 2) continue
        val w = parts[0].trim().toFloatOrNull() ?: continue
        val h = parts[1].trim().toFloatOrNull() ?: continue
        if (w <= 0f || h <= 0f) continue
        return w / h
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
