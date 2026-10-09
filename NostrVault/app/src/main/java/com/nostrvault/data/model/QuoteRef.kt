package com.nostrvault.data.model

/**
 * The `nostr:` references a note makes to other events, and the key the app
 * looks each one up by.
 *
 * There is one definition here because there used to be three. The regex was
 * copied into the note parser, the text renderer and a formatter, and the
 * bech32 decode lived in two places that disagreed: the parser was changed to
 * hand out hex event ids while `FeedService` still expected bech32, so it
 * rejected every id it was given and no quoted note resolved at all. A parser
 * and its consumer cannot drift if they are the same code.
 *
 * bech32 decoding is injected via [Decoder] rather than calling HavenBridge
 * directly, so everything here is a plain JVM unit a test can drive.
 */
object QuoteRef {

    /** `nostr:note1...` / `nostr:nevent1...` / `nostr:naddr1...` event references. */
    val REGEX = Regex(
        """nostr:(note1[a-z0-9]+|nevent1[a-z0-9]+|naddr1[a-z0-9]+)""",
        RegexOption.IGNORE_CASE,
    )

    /** Marks a lookup key as an addressable-event coordinate, not a 32-byte event id. */
    const val COORDINATE_PREFIX = "naddr:"

    /**
     * A NIP-01 addressable event's address: `kind`, author and `d` tag. A
     * long-form article is edited in place, so it is named by this rather than
     * by the id of any one revision.
     */
    data class Coordinate(val kind: Int, val pubkey: String, val dTag: String)

    /** bech32 decoding, supplied by the caller. The real one wraps HavenBridge. */
    interface Decoder {
        fun noteToHex(note1: String): String?
        fun neventToHex(nevent1: String): String?
        fun naddrToCoordinate(naddr1: String): Coordinate?
    }

    /**
     * Reads a decoded naddr payload (NIP-19 TLV): type 0 = the `d` tag
     * (UTF-8), 1 = relay hint, 2 = author (32 bytes), 3 = kind (4 bytes,
     * big-endian). The one reader for every naddr the app meets — a quoted
     * `nostr:naddr1…` in a note and a `nostr:` link from another app — so both
     * agree on what a payload names. Port of iOS `QuoteReference.naddrParts(fromTLV:)`.
     *
     * Null, naming nothing, when:
     * - kind or author is missing (a fetch without them is unbounded);
     * - the `d` tag is not valid UTF-8. A lossy decode turned it into U+FFFD
     *   text; iOS read it as the empty `d` tag, which named a different event
     *   by the same author (#479). A zero-length `d` is a real empty `d` tag.
     * - an entry runs past the end, or the `d` tag, author or kind appears
     *   twice: a malformed payload yields nothing, not a guess.
     *
     * The relay hint is never read. Every lookup asks the user's own relays,
     * so a link cannot make the app dial a host of the sender's choosing.
     */
    fun coordinateFromNaddrTlv(payload: ByteArray): Coordinate? {
        var dTag: String? = null
        var pubkey: String? = null
        var kind: Int? = null
        var i = 0
        while (i < payload.size) {
            if (i + 2 > payload.size) return null
            val type = payload[i].toInt() and 0xFF
            val length = payload[i + 1].toInt() and 0xFF
            i += 2
            if (i + length > payload.size) return null
            val value = payload.copyOfRange(i, i + length)
            i += length
            when (type) {
                0 -> {
                    if (dTag != null) return null
                    dTag = strictUtf8(value) ?: return null
                }
                2 -> if (length == 32) {
                    if (pubkey != null) return null
                    pubkey = value.joinToString("") { "%02x".format(it) }
                }
                3 -> if (length == 4) {
                    if (kind != null) return null
                    kind = value.fold(0) { acc, b -> (acc shl 8) or (b.toInt() and 0xFF) }
                }
            }
        }
        val resolvedKind = kind ?: return null
        val resolvedPubkey = pubkey ?: return null
        return Coordinate(resolvedKind, resolvedPubkey, dTag ?: "")
    }

    /** [bytes] as UTF-8, or null when they are not valid UTF-8. Keeps a leading BOM. */
    private fun strictUtf8(bytes: ByteArray): String? = try {
        Charsets.UTF_8.newDecoder()
            .onMalformedInput(java.nio.charset.CodingErrorAction.REPORT)
            .onUnmappableCharacter(java.nio.charset.CodingErrorAction.REPORT)
            .decode(java.nio.ByteBuffer.wrap(bytes))
            .toString()
    } catch (_: java.nio.charset.CharacterCodingException) {
        null
    }

    /**
     * Kinds a `nostr:naddr1…` link from another app may open: the addressable
     * range (NIP-01, 30000–39999) only. naddr can name any kind, but a link
     * naming a profile (0), a follow list (3), a DM (4) or a gift wrap (1059)
     * must not land in a reader as if it were a post.
     */
    fun isLinkableKind(kind: Int): Boolean = kind in 30000..39999

    /** What a lookup key names. */
    sealed class Key {
        /** A 64-hex event id, fetched with an `ids` filter. */
        data class Event(val hexId: String) : Key()

        /** An addressable event, fetched with kind + author + `#d`. */
        data class Address(val coordinate: Coordinate) : Key()
    }

    /**
     * Every quote reference in [content], in the order they appear, repeats
     * dropped.
     *
     * Repeats are dropped because these address rows in a list: the same
     * reference twice is the same card twice.
     */
    fun identifiers(content: String): List<String> {
        val seen = LinkedHashSet<String>()
        for (match in REGEX.findAll(content)) seen.add(match.groupValues[1])
        return seen.toList()
    }

    /**
     * The lookup key for one bech32 identifier: a hex event id for
     * `note1`/`nevent1`, a coordinate for `naddr1`.
     */
    fun resolve(identifier: String, decoder: Decoder): String? = when {
        identifier.startsWith("note1", ignoreCase = true) ->
            decoder.noteToHex(identifier)
        identifier.startsWith("nevent1", ignoreCase = true) ->
            decoder.neventToHex(identifier)
        identifier.startsWith("naddr1", ignoreCase = true) ->
            decoder.naddrToCoordinate(identifier)?.let { format(it) }
        else -> null
    }

    /** The lookup keys for every quote reference in [content]. */
    fun resolvedIdentifiers(content: String, decoder: Decoder): List<String> =
        identifiers(content).mapNotNull { resolve(it, decoder) }.distinct()

    /**
     * Reads a lookup key back. Returns null only for a string that is neither —
     * so a caller that gets null is looking at something it did not produce,
     * rather than at a reference it should have handled.
     */
    fun key(value: String): Key? = when {
        value.startsWith(COORDINATE_PREFIX) -> parse(value)?.let { Key.Address(it) }
        isHexEventId(value) -> Key.Event(value)
        else -> null
    }

    /** Builds a coordinate string. One definition, so [parse] cannot drift from it. */
    fun format(coordinate: Coordinate): String =
        "$COORDINATE_PREFIX${coordinate.kind}:${coordinate.pubkey}:${coordinate.dTag}"

    /** Splits a coordinate string back into its parts. Null for anything else. */
    fun parse(value: String): Coordinate? {
        if (!value.startsWith(COORDINATE_PREFIX)) return null
        // limit 4 keeps a d tag containing ":" intact.
        val parts = value.split(":", limit = 4)
        if (parts.size < 3) return null
        val kind = parts[1].toIntOrNull() ?: return null
        if (parts[2].isEmpty()) return null
        return Coordinate(kind, parts[2], if (parts.size > 3) parts[3] else "")
    }

    /**
     * The coordinate of a NIP-53 live stream (kind 30311) that a web link
     * points at: `zap.stream/naddr1…`, `shosho.live/live/naddr1…`,
     * `njump.me/naddr1…`. Any host, because the naddr in the path is what names
     * the stream; null for anything else. iOS:
     * QuoteReference.liveStreamCoordinate(in:).
     */
    fun liveStreamCoordinate(url: String, decoder: Decoder): String? {
        val afterScheme = url.substringAfter("://", missingDelimiterValue = "")
        val path = afterScheme.substringAfter('/', missingDelimiterValue = "")
            .substringBefore('?')
            .substringBefore('#')
        for (component in path.split('/')) {
            val lower = component.lowercase()
            if (!lower.startsWith("naddr1")) continue
            val coordinate = decoder.naddrToCoordinate(lower) ?: continue
            if (coordinate.kind == LiveStream.KIND) return format(coordinate)
        }
        return null
    }

    private fun isHexEventId(value: String): Boolean =
        value.length == 64 && value.all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' }
}
