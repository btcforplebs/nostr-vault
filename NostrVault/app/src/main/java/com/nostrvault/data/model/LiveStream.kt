package com.nostrvault.data.model

/**
 * A NIP-53 live event (kind 30311), reduced to what a grid and a player need.
 *
 * Parsing lives here, away from the networking, because the interesting
 * decisions are all about the tags: which streams are worth showing, and which
 * URLs can actually be played.
 */
data class LiveStream(
    val hostPubkey: String,
    val identifier: String,
    val createdAt: Long,
    val title: String?,
    val summary: String?,
    /** NIP-53 `image`: the host's cover art. */
    val imageUrl: String?,
    val streamingUrl: String?,
    val status: String?,
    /** NIP-53 `ends`: when the host said the stream finished, in seconds. */
    val ends: Long? = null,
    val participants: Int?,
    /**
     * The `relays` tag: where this stream's own chat lives.
     *
     * Measured 2026-09-07 against 19 live streams: chat was on nos.lol, and
     * relay.zap.stream — the relay every client's docs name for this — served
     * zero kind-1311 events of any kind. So the stream's own hint is the only
     * trustworthy source, and a hardcoded list is a fallback, not the answer.
     */
    val chatRelays: List<String> = emptyList(),
    /**
     * Who the stream belongs to: the signer, plus any `p` tag marked Host. A
     * service such as zap.stream signs on the host's behalf, so Following and
     * the Web of Trust judge the stream by these, not by the signer alone.
     */
    val hosts: Set<String> = setOf(hostPubkey),
    /**
     * What the tile tries to draw, best first: `thumb`, a frame of the
     * broadcast itself (zap.stream and its forks, refreshed every republish),
     * then `image`, the cover art. iOS measured 2026-10-04: 3 of 9 live
     * streams carried `thumb`, and every one also had an `image`.
     */
    val previewImageUrls: List<String> = listOfNotNull(imageUrl),
) {
    /** The addressable form: what an naddr for this stream points at. */
    val address: String get() = "$KIND:$hostPubkey:$identifier"

    /**
     * Shown only when the stream is running AND something can play it.
     *
     * iOS measured this against a real sample (2026-09-05): 478 of 632 events
     * were already `ended` and only 89 carried a streaming tag at all, so
     * without both halves of the test the grid is mostly gravestones. A
     * missing status with a playable URL counts — 71 events omit status
     * entirely, which is a real bucket rather than noise.
     */
    val isPlayableLive: Boolean
        get() = streamingUrl != null && (status == null || status == "live")

    /**
     * Whether the announcement still means the stream is on air at [nowSeconds].
     *
     * A `live` status alone is not enough: hosts who quit without publishing
     * `ended` leave it standing. Running streams are republished every few
     * minutes, so NIP-53's one-hour cutoff is safe — measured 2026-09-26,
     * every older `live` tile's URL was a 404.
     */
    fun isOnAirAt(nowSeconds: Long): Boolean =
        (ends == null || ends > nowSeconds) && nowSeconds - createdAt <= STALE_AFTER_SECONDS

    companion object {
        const val KIND = 30311

        /** NIP-53: a `live` event not updated for an hour may be treated as ended. */
        const val STALE_AFTER_SECONDS = 60L * 60

        /** @return null when the event is not a usable live event (no `d` tag). */
        fun from(pubkey: String, createdAt: Long, tags: List<List<String>>): LiveStream? {
            fun value(name: String): String? = tags
                .firstOrNull { it.size >= 2 && it[0] == name }
                ?.get(1)
                ?.trim()
                ?.takeIf { it.isNotEmpty() }

            val identifier = value("d") ?: return null

            // Only an HTTP(S) HLS playlist is a live stream the player can
            // open. Real events also carry rtmp, ftp, `zapcast:` URLs and plain
            // web pages (a youtube.com/live link) — a tile for one of those is
            // a tile that can only disappoint. zap.stream publishes two
            // `streaming` tags, HLS and `moq://`, in no fixed order, so the
            // first playable one wins, not simply the first.
            val streaming = tags
                .filter { it.size >= 2 && it[0] == "streaming" }
                .map { it[1].trim() }
                .firstOrNull { raw ->
                    val scheme = raw.substringBefore(':').lowercase()
                    val path = raw.substringBefore('?').substringBefore('#').lowercase()
                    (scheme == "http" || scheme == "https") && path.endsWith(".m3u8")
                }

            val previews = listOf("thumb", "image")
                .mapNotNull { value(it) }
                .filter { raw ->
                    val scheme = raw.substringBefore(':').lowercase()
                    scheme == "http" || scheme == "https"
                }
                .distinct()

            return LiveStream(
                hostPubkey = pubkey,
                identifier = identifier,
                createdAt = createdAt,
                title = value("title"),
                summary = value("summary"),
                imageUrl = value("image"),
                streamingUrl = streaming,
                status = value("status")?.lowercase(),
                ends = value("ends")?.toLongOrNull(),
                participants = value("current_participants")?.toIntOrNull(),
                chatRelays = tags.firstOrNull { it.isNotEmpty() && it[0] == "relays" }
                    ?.drop(1)
                    ?.map { it.trim() }
                    ?.filter { it.startsWith("wss://") || it.startsWith("ws://") }
                    ?: emptyList(),
                hosts = setOf(pubkey) + tags
                    .filter { it.size >= 4 && it[0] == "p" && it[3].equals("host", ignoreCase = true) }
                    .map { it[1] },
                previewImageUrls = previews,
            )
        }
    }
}
