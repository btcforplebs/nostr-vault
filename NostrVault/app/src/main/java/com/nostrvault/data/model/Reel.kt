package com.nostrvault.data.model

import com.nostrvault.ui.components.isVideoUrl

/** Whose videos the Reels feed shows. Global is opt-in behind a warning. */
enum class ReelsScope { FOLLOWING, GLOBAL }

/**
 * One page of the Reels feed: a note and the single video it plays.
 *
 * Mirrors iOS `Reel`. Extraction lives here, away from the networking, because
 * the interesting decisions are all about the tags: which URL in a note is the
 * video, and which notes must not autoplay at all.
 */
data class Reel(
    val note: FeedNote,
    /** Unix seconds; the sort key. */
    val createdAt: Long,
    val videoUrl: String,
    /** MIME from the event, for extensionless Blossom URLs. */
    val mimeType: String?,
    /** Poster frame the event publishes, shown until the video has a frame. */
    val posterUrl: String?,
    /** Width / height when the event says; otherwise learned from the player. */
    val aspectRatio: Float?,
    val title: String?,
    /** The note text with the video link itself taken out. */
    val caption: String,
) {
    val id: String get() = note.id

    companion object {
        /** NIP-71 video events: normal and short, and their addressable forms. */
        val VIDEO_KINDS = listOf(21, 22, 34235, 34236)

        /** Newest first; id breaks ties so the order is total and stable. */
        val NEWEST_FIRST: Comparator<Reel> =
            compareByDescending<Reel> { it.createdAt }.thenByDescending { it.id }

        /**
         * The reel this note plays, or null when it has no video known to be one.
         *
         * Extensionless links with no MIME hint are left out rather than
         * HEAD-requested one by one: a page that turns out to be an image is
         * worse than a missing one. [cachedMimeType] lets a caller supply
         * content types it already learned elsewhere without a network call.
         */
        fun from(
            note: FeedNote,
            createdAt: Long,
            cachedMimeType: (String) -> String? = { null },
        ): Reel? {
            // A note with a content warning autoplaying full-screen defeats the
            // warning, so those stay in the timeline where they can be blurred.
            if (note.tags.any { it.firstOrNull() == "content-warning" }) return null

            fun isKnownVideo(url: String, mime: String?): Boolean {
                val hint = (mime ?: cachedMimeType(url))?.lowercase()
                if (hint != null && hint.startsWith("video/")) return true
                // An explicit image or audio type beats whatever the path says.
                if (hint != null && (hint.startsWith("image/") || hint.startsWith("audio/"))) return false
                return isVideoUrl(url)
            }

            val imeta = imetaFields(note.tags)
            var pickUrl: String? = null
            var pickMime: String? = null

            // First URL known to be video, in the order the note gives them.
            for (entry in imeta) {
                val url = entry["url"]?.takeIf(::isHttp) ?: continue
                val mime = entry["m"]
                if (isKnownVideo(url, mime)) {
                    pickUrl = url
                    pickMime = mime
                    break
                }
            }
            if (pickUrl == null) {
                pickUrl = note.mediaURLs.firstOrNull { isHttp(it) && isKnownVideo(it, null) }
            }
            // Older NIP-71 events carry a bare `url` tag instead of imeta.
            if (pickUrl == null && note.kind in VIDEO_KINDS) {
                note.tags.value("url")?.takeIf(::isHttp)?.let { url ->
                    pickUrl = url
                    pickMime = note.tags.value("m")
                }
            }
            val url = pickUrl ?: return null

            val entry = imeta.firstOrNull { it["url"] == url }
            return Reel(
                note = note,
                createdAt = createdAt,
                videoUrl = url,
                mimeType = pickMime,
                posterUrl = (entry?.get("image") ?: entry?.get("thumb")
                    ?: note.tags.firstOrNull { it.size >= 2 && (it[0] == "image" || it[0] == "thumb") }?.get(1))
                    ?.takeIf(::isHttp),
                aspectRatio = entry?.get("dim")?.let(::aspectFromDim),
                title = note.tags.value("title")?.trim()?.takeIf { it.isNotEmpty() },
                caption = note.content.replace(url, "").trim(),
            )
        }

        /**
         * Fill the screen when the video is close to the screen's shape (a
         * portrait clip on a phone loses a sliver at the sides); otherwise fit,
         * so a landscape clip, or a phone video on a tablet, is not cropped to
         * a strip. An unknown shape fits.
         */
        fun fillsScreen(videoAspect: Float?, screenAspect: Float): Boolean {
            if (videoAspect == null || videoAspect <= 0f || screenAspect <= 0f) return false
            val mismatch = maxOf(videoAspect / screenAspect, screenAspect / videoAspect)
            return mismatch <= FILL_TOLERANCE
        }

        /** How far apart the video's and screen's shapes may be and still fill. */
        const val FILL_TOLERANCE = 1.3f

        /** `dim 1080x1920` → 0.5625. */
        fun aspectFromDim(dim: String): Float? {
            val parts = dim.lowercase().split("x")
            if (parts.size != 2) return null
            val w = parts[0].trim().toDoubleOrNull() ?: return null
            val h = parts[1].trim().toDoubleOrNull() ?: return null
            if (w <= 0 || h <= 0) return null
            return (w / h).toFloat()
        }

        private fun isHttp(url: String): Boolean {
            val scheme = url.substringBefore(':', "").lowercase()
            return scheme == "https" || scheme == "http"
        }

        private fun List<List<String>>.value(name: String): String? =
            firstOrNull { it.size >= 2 && it[0] == name }?.get(1)

        /** Each NIP-92 `imeta` tag as a field map (`url`, `m`, `dim`, `image`…). */
        private fun imetaFields(tags: List<List<String>>): List<Map<String, String>> =
            tags.filter { it.size >= 2 && it[0] == "imeta" }.map { tag ->
                buildMap {
                    for (field in tag.drop(1)) {
                        val space = field.indexOf(' ')
                        if (space <= 0) continue
                        val key = field.substring(0, space)
                        val value = field.substring(space + 1).trim()
                        // First value wins — `image` and `fallback` may repeat.
                        if (value.isNotEmpty() && key !in this) put(key, value)
                    }
                }
            }
    }
}

/**
 * The two filters a Reels page asks for. Each pages on its own cursor: kind-1
 * notes are dense and NIP-71 events are sparse, so one shared cursor would
 * either skip notes or re-ask for the same video window.
 */
enum class ReelStream(val kinds: List<Int>, val limit: Int) {
    VIDEO(Reel.VIDEO_KINDS, 100),
    NOTE(listOf(1), 300),
    ;

    companion object {
        fun forKind(kind: Int): ReelStream? = when (kind) {
            1 -> NOTE
            in Reel.VIDEO_KINDS -> VIDEO
            else -> null
        }
    }
}

/**
 * Where the next Reels page starts, per stream. Pure so the paging rule can be
 * tested without a relay. Mirrors the cursor handling in iOS `ReelsFeedService`.
 */
data class ReelCursors(
    /** `until` for the next page. A stream missing here has not paged yet. */
    val until: Map<ReelStream, Long> = emptyMap(),
    /** Streams whose history has run out. */
    val exhausted: Set<ReelStream> = emptySet(),
    /** Consecutive pages that produced no reel. */
    val emptyPages: Int = 0,
) {
    /** Stops a video-less stretch of history from paging forever. */
    val reachedEnd: Boolean
        get() = exhausted.size == ReelStream.entries.size || emptyPages >= MAX_EMPTY_PAGES

    val activeStreams: List<ReelStream> get() = ReelStream.entries.filter { it !in exhausted }

    /**
     * The cursors after a page, given the oldest `created_at` each relay
     * returned per stream.
     *
     * Next cursor per stream is the NEWEST of the relays' oldest events.
     * Taking the oldest overall would jump a dense relay past history a sparse
     * relay never had; this way every relay resumes where it stopped, and the
     * overlap is deduplicated by event id. A stream no relay returned anything
     * for has run out.
     */
    fun afterPage(oldestPerRelay: Collection<Map<ReelStream, Long>>, producedReels: Boolean): ReelCursors {
        val nextUntil = until.toMutableMap()
        val nextExhausted = exhausted.toMutableSet()
        for (stream in activeStreams) {
            val resume = oldestPerRelay.mapNotNull { it[stream] }.maxOrNull()
            if (resume != null) nextUntil[stream] = resume - 1 else nextExhausted += stream
        }
        return ReelCursors(
            until = nextUntil,
            exhausted = nextExhausted,
            emptyPages = if (producedReels) 0 else emptyPages + 1,
        )
    }

    /** The REQ filters for the next page, one per stream still paging. */
    fun filters(authors: List<String>?): List<String> = activeStreams.map { stream ->
        buildString {
            append("{\"kinds\":[")
            append(stream.kinds.joinToString(","))
            append("],\"limit\":")
            append(stream.limit)
            if (authors != null) {
                append(",\"authors\":[")
                append(authors.joinToString(",") { "\"$it\"" })
                append("]")
            }
            until[stream]?.let { append(",\"until\":").append(it) }
            append("}")
        }
    }

    companion object {
        const val MAX_EMPTY_PAGES = 4

        /** How close to the end of what is loaded the viewer must be for paging to continue on its own. */
        const val NEAR_END = 3

        /**
         * Whether a finished page should start the next one without waiting for
         * a swipe. A page of notes with no video in it would otherwise park the
         * pager on its last reel with nothing left to trigger the next page.
         */
        fun shouldContinue(reelCount: Int, shownIndex: Int, reachedEnd: Boolean): Boolean =
            !reachedEnd && (reelCount == 0 || shownIndex >= reelCount - NEAR_END)
    }
}
