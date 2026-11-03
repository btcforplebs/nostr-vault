package com.nostrvault.service.shareportal.handlers

import com.nostrvault.data.model.NoteTagging
import kotlin.math.roundToLong

/**
 * What a shared picture or video post publishes: NIP-68 (kind 20) for
 * pictures, NIP-71 (kind 21, or 22 for a portrait video) for one video.
 * Pure, tested against the shared fixtures (`media-post-cases.json`).
 * Twin: MediaPostShareTags.swift.
 *
 * One post is pictures or one video, never both: NIP-68 holds only pictures
 * and NIP-71 one video. The review card says so before anything uploads.
 */
object MediaPostShareTags {
    const val PICTURE_KIND = 20
    const val VIDEO_KIND = 21
    const val SHORT_VIDEO_KIND = 22
    const val MAX_PICTURES = 20

    /** One uploaded file, as the event describes it. */
    data class Media(
        val url: String,
        val mime: String,
        val sha256: String,
        val width: Int? = null,
        val height: Int? = null,
        val bytes: Long? = null,
        /** Seconds, videos only. */
        val duration: Double? = null,
        val alt: String? = null,
    )

    enum class Shape { PICTURES, VIDEO }

    enum class Problem(val message: String) {
        NOTHING("Nothing to post: no picture or video came with this share."),
        MIXED("A post is pictures or one video, not both. Share them separately."),
        TOO_MANY_VIDEOS("One video per post. Share the others separately."),
        TOO_MANY_PICTURES("Up to $MAX_PICTURES pictures per post."),
        NOT_MEDIA("Only pictures and videos can be posted."),
    }

    /** Either a shape or the problem that stops the post. */
    data class ShapeResult(val shape: Shape? = null, val problem: Problem? = null)

    fun isPicture(mime: String): Boolean = mime.lowercase().startsWith("image/")
    fun isVideo(mime: String): Boolean = mime.lowercase().startsWith("video/")

    /** Pictures NIP-68 lists. Anything else (HEIC, TIFF, …) becomes a JPEG before it uploads. */
    val POSTABLE_IMAGE_TYPES = setOf("image/jpeg", "image/png", "image/gif", "image/webp", "image/avif", "image/apng")

    fun needsJpeg(mime: String): Boolean = isPicture(mime) && mime.lowercase() !in POSTABLE_IMAGE_TYPES

    /** What the shared files can become, by their types. */
    fun shape(mimes: List<String>): ShapeResult {
        if (mimes.isEmpty()) return ShapeResult(problem = Problem.NOTHING)
        if (mimes.any { !isPicture(it) && !isVideo(it) }) return ShapeResult(problem = Problem.NOT_MEDIA)
        val videos = mimes.count { isVideo(it) }
        if (videos > 0 && videos < mimes.size) return ShapeResult(problem = Problem.MIXED)
        if (videos > 1) return ShapeResult(problem = Problem.TOO_MANY_VIDEOS)
        if (videos == 1) return ShapeResult(shape = Shape.VIDEO)
        if (mimes.size > MAX_PICTURES) return ShapeResult(problem = Problem.TOO_MANY_PICTURES)
        return ShapeResult(shape = Shape.PICTURES)
    }

    /** Kind 22 for a video taller than it is wide (NIP-71 short form). */
    fun kind(shape: Shape, media: List<Media>): Int = when (shape) {
        Shape.PICTURES -> PICTURE_KIND
        Shape.VIDEO -> {
            val m = media.firstOrNull()
            val w = m?.width
            val h = m?.height
            if (w != null && h != null && h > w) SHORT_VIDEO_KIND else VIDEO_KIND
        }
    }

    /** One `imeta` per file (NIP-92 fields), in the order shared. */
    fun imeta(m: Media): List<String> {
        val fields = mutableListOf("imeta", "url ${m.url}", "m ${m.mime.lowercase()}", "x ${m.sha256}")
        if (m.width != null && m.height != null && m.width > 0 && m.height > 0) fields += "dim ${m.width}x${m.height}"
        if (m.bytes != null && m.bytes > 0) fields += "size ${m.bytes}"
        if (m.duration != null && m.duration > 0) fields += "duration ${format(m.duration)}"
        flat(m.alt)?.let { fields += "alt $it" }
        return fields
    }

    /**
     * The event's tags. [title] empty means none for pictures, and the
     * caption's first line (or "Video") for a video, where NIP-71 asks for one.
     */
    fun tags(shape: Shape, media: List<Media>, title: String, caption: String, publishedAt: Long): List<List<String>> {
        val out = mutableListOf<List<String>>()
        val t = title.trim()
        when (shape) {
            Shape.PICTURES -> if (t.isNotEmpty()) out += listOf("title", t)
            Shape.VIDEO -> {
                out += listOf("title", t.ifEmpty { videoTitle(caption) })
                out += listOf("published_at", publishedAt.toString())
            }
        }
        media.forEach { out += imeta(it) }
        // NIP-68 filter tags: each type and hash once.
        if (shape == Shape.PICTURES) {
            val types = mutableListOf<String>()
            media.forEach { m -> m.mime.lowercase().let { if (it !in types) types += it } }
            types.forEach { out += listOf("m", it) }
            media.forEach { out += listOf("x", it.sha256) }
        }
        out += NoteTagging.hashtagTags("$t $caption")
        out += listOf("alt", altText(shape, media.size, t, caption))
        return out
    }

    /** The caption is the content, trimmed. */
    fun content(caption: String): String = caption.trim()

    fun videoTitle(caption: String): String {
        val first = lines(caption).firstOrNull()?.trim { it == ' ' || it == '\t' }.orEmpty()
        if (first.isEmpty()) return "Video"
        return if (first.length > 80) first.take(80) + "…" else first
    }

    /** For clients that don't know these kinds (NIP-31). */
    fun altText(shape: Shape, count: Int, title: String, caption: String): String {
        val what = when (shape) {
            Shape.PICTURES -> if (count == 1) "A picture" else "$count pictures"
            Shape.VIDEO -> "A video"
        }
        val about = title.ifEmpty { flat(caption)?.take(140).orEmpty() }
        return if (about.isEmpty()) what else "$what: $about"
    }

    /** Lines without the empty ones, as Swift's `split(whereSeparator: \.isNewline)`. */
    private fun lines(s: String): List<String> = s.split(NEWLINES).filter { it.isNotEmpty() }

    private fun flat(s: String?): String? {
        s ?: return null
        val joined = lines(s).joinToString(" ").trim { it == ' ' || it == '\t' }
        return joined.ifEmpty { null }
    }

    private val NEWLINES = Regex("\r\n|[\n\r\u000B\u000C\u0085  ]")

    /** Seconds with at most 3 decimals, no trailing zeros ("12", "12.5"). */
    fun format(seconds: Double): String {
        val ms = (seconds * 1000).roundToLong()
        val whole = ms / 1000
        val frac = ms % 1000
        if (frac == 0L) return whole.toString()
        return "$whole." + String.format(java.util.Locale.ROOT, "%03d", frac).trimEnd('0')
    }
}
