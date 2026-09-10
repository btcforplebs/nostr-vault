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

    /**
     * `nostr:note1...` / `nostr:nevent1...` / `nostr:naddr1...` event references.
     *
     * The `nostr:` prefix is optional because clients in the wild post the bare
     * bech32, and a bare `nevent1…` rendered as raw text looks broken here even
     * though the note is fine. A preceding character must be whitespace or a
     * delimiter so this cannot bite into the middle of a word or a URL path,
     * and `bech32` alone is not enough to be sure — anything that fails to
     * decode is dropped rather than shown, which is what [resolve] already does.
     */
    val REGEX = Regex(
        """(?:nostr:)?(note1[a-z0-9]{20,}|nevent1[a-z0-9]{20,}|naddr1[a-z0-9]{20,})""",
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

        /**
         * Relay hints (NIP-19 TLV type 1) the reference carries. Defaulted so a
         * decoder that does not care about them stays a three-method interface.
         */
        fun relayHints(identifier: String): List<String> = emptyList()
    }

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
     * Relay hints for each quote reference in [content], keyed by the same
     * lookup key [resolvedIdentifiers] produces.
     *
     * The hint is the author telling us where the quoted event lives. Without
     * it a quote of something outside the reader's own relay set can never
     * resolve, however correct the rest of the pipeline is.
     */
    fun relayHints(content: String, decoder: Decoder): Map<String, List<String>> {
        val out = mutableMapOf<String, MutableList<String>>()
        for (identifier in identifiers(content)) {
            val key = resolve(identifier, decoder) ?: continue
            val hints = decoder.relayHints(identifier)
            if (hints.isEmpty()) continue
            val bucket = out.getOrPut(key) { mutableListOf() }
            for (h in hints) if (h !in bucket) bucket.add(h)
        }
        return out
    }

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

    private fun isHexEventId(value: String): Boolean =
        value.length == 64 && value.all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' }
}
