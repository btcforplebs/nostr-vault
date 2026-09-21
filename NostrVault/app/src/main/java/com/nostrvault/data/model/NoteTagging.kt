package com.nostrvault.data.model

/**
 * The tags a composed kind-1 note carries *about its own content*: the hashtags
 * the author typed (NIP-24 `t`) and a description of each piece of media it
 * publishes (NIP-92 `imeta`).
 *
 * Both are pure string work, kept out of `ComposeNoteScreen` so the Android,
 * macOS and iOS editors agree about what a note advertises, and so the rules
 * are testable without a composition. The Swift twin lives at
 * `HavenApp/HavenApp/Models/NoteTagging.swift`.
 */
object NoteTagging {

    // region Hashtags

    /**
     * `#tag` runs that are not part of a URL or a `nostr:` reference.
     *
     * A `t` tag is what makes a note findable by hashtag — our own search
     * builds its trending list from `t` tags, as does every other client's tag
     * feed. NIP-24 stores the value without the `#` and lower-cased, so
     * `#Bitcoin` and `#bitcoin` are one tag.
     *
     * Rules, in the order they bite:
     * - a token that is a URL or a `nostr:`/`wss:` reference contributes
     *   nothing, so `https://host/page#section` is a fragment, not a tag;
     * - `#` must not follow a letter, digit or `_`, so `C#` inside a word and
     *   `a#b` are left alone;
     * - the run must contain at least one letter, so `#1` reads as "number 1"
     *   rather than a tag;
     * - duplicates collapse case-insensitively, first spelling wins the order.
     */
    fun hashtags(text: String): List<String> {
        val found = mutableListOf<String>()
        val seen = mutableSetOf<String>()

        for (token in text.split(WHITESPACE)) {
            if (token.isEmpty() || isReference(token)) continue
            for (match in HASHTAG.findAll(token)) {
                val tag = match.groupValues[1].lowercase()
                if (tag.none { it.isLetter() }) continue
                if (tag.length > MAX_HASHTAG_LENGTH) continue
                if (seen.add(tag)) found.add(tag)
            }
        }

        return found
    }

    /** `t` tags, ready to append to an event's tag list. */
    fun hashtagTags(text: String): List<List<String>> = hashtags(text).map { listOf("t", it) }

    /**
     * A tag longer than this is almost certainly a run-together sentence or a
     * hex blob, not something anyone browses by.
     */
    private const val MAX_HASHTAG_LENGTH = 64

    private val WHITESPACE = Regex("""\s+""")

    private val HASHTAG = Regex("""(?<![\p{L}\p{N}_])#([\p{L}\p{N}_]+)""")

    private val REFERENCE_PREFIXES = listOf("http://", "https://", "ws://", "wss://", "nostr:")

    private fun isReference(token: String): Boolean {
        val lowered = token.lowercase()
        return REFERENCE_PREFIXES.any { lowered.startsWith(it) }
    }

    // endregion

    // region NIP-92 imeta

    /** Everything we know about one uploaded attachment at publish time. */
    data class MediaDescriptor(
        val url: String,
        /** MIME type, e.g. `image/jpeg`. Omitted from the tag when unknown. */
        val mimeType: String? = null,
        /**
         * SHA-256 of the *original* file, hex. Blossom keys blobs by this, so
         * it is already computed before the upload starts.
         */
        val sha256: String? = null,
        /**
         * Pixel dimensions. Lets a reader reserve the right box before the
         * bytes arrive — [com.nostrvault.ui.components.imetaAspectRatio] reads
         * it, which is why our own media used to shift our own layout.
         */
        val pixelWidth: Int? = null,
        val pixelHeight: Int? = null,
        /**
         * Author-supplied description. The only thing that makes the image
         * mean anything to a screen-reader user.
         */
        val alt: String? = null,
        val byteCount: Long? = null,
    )

    /**
     * One flat `imeta` tag per NIP-92: `["imeta", "url …", "m …", "x …", …]`.
     *
     * Fields whose value we do not have are left out entirely rather than
     * emitted empty — a reader that sees `dim ` has to guess, one that sees no
     * `dim` knows to measure. A descriptor with no URL produces no tag.
     */
    fun imetaTag(media: MediaDescriptor): List<String>? {
        val url = media.url.trim()
        if (url.isEmpty()) return null

        val fields = mutableListOf("url $url")
        media.mimeType?.takeIf { it.isNotEmpty() }?.let { fields.add("m $it") }
        media.sha256?.takeIf { it.isNotEmpty() }?.let { fields.add("x $it") }
        val w = media.pixelWidth
        val h = media.pixelHeight
        if (w != null && h != null && w > 0 && h > 0) fields.add("dim ${w}x$h")
        media.byteCount?.takeIf { it > 0 }?.let { fields.add("size $it") }
        media.alt?.trim()?.takeIf { it.isNotEmpty() }?.let { alt ->
            // A newline inside a field would split the tag's meaning for a
            // reader that parses by prefix; collapse to spaces.
            fields.add("alt " + alt.split(NEWLINE).joinToString(" "))
        }

        return listOf("imeta") + fields
    }

    fun imetaTags(media: List<MediaDescriptor>): List<List<String>> = media.mapNotNull { imetaTag(it) }

    private val NEWLINE = Regex("""\R+""")

    // endregion
}
