package com.nostrvault.data.model

import com.nostrvault.relay.HavenBridge

/**
 * NIP-19 references written without `nostr:` — `nevent1…`, `@npub1…` — and
 * what a reference opens. Port of iOS `QuoteReference.prefixBare` /
 * `target(ofBech32:)` (#1250).
 *
 * Many clients paste references bare. They drew as raw bech32 with no quote
 * card or mention; [prefixBare] gives them the prefix so every parser that
 * already handles `nostr:` treats them the same.
 */
object BareNostrRefs {

    /** What a reference opens. */
    sealed class Target {
        data class Note(val id: String) : Target()
        /** [naddr] is the lowercased bech32, for the address route. */
        data class Address(val naddr: String, val coordinate: QuoteRef.Coordinate) : Target()
        data class Profile(val pubkey: String) : Target()
    }

    /**
     * A reference not part of a URL or a longer word; a leading `@` is taken
     * with it. The bech32 alphabet has no b, i, o or 1 after the separator.
     */
    private val BARE = Regex(
        """(?<![A-Za-z0-9_/:.=?&#%+~@-])@?((?:npub|nprofile|note|nevent|naddr)1[02-9ac-hj-np-z]+)(?![A-Za-z0-9])""",
    )

    /**
     * [content] with `nostr:` put in front of every bare reference that
     * decodes. Only references that decode (checksum included) are touched,
     * so a word that merely starts like one ("note1st") stays text, and one
     * inside a URL (`njump.me/nevent1…`) stays part of the URL. A leading `@`
     * is dropped: the mention draws its own.
     */
    fun prefixBare(content: String): String {
        if (!content.contains('1')) return content
        return BARE.replace(content) { m ->
            val bech = m.groupValues[1]
            if (target(bech) != null) "nostr:$bech" else m.value
        }
    }

    /**
     * What a bare bech32 reference opens, or null when it does not decode to
     * one. `nsec1` and other kinds are never a target. HavenBridge's decoder
     * checks the checksum, so a mistyped paste never opens some other note.
     */
    fun target(identifier: String): Target? {
        val id = identifier.lowercase()
        return when {
            id.startsWith("note1") -> HavenBridge.decodeNote(id)?.let { Target.Note(it) }
            id.startsWith("nevent1") -> HavenBridge.decodeNevent(id)?.let { Target.Note(it) }
            id.startsWith("naddr1") -> HavenBridge.decodeNaddr(id)?.let { Target.Address(id, it) }
            id.startsWith("npub1") -> HavenBridge.decodeNpub(id)?.let { Target.Profile(it) }
            id.startsWith("nprofile1") -> HavenBridge.decodeNprofilePubkey(id)?.let { Target.Profile(it) }
            else -> null
        }
    }

    /**
     * What a search-field paste opens: a `nostr:` link or the same reference
     * bare, with an optional leading `@`. Null for anything else, which then
     * searches as text.
     */
    fun pastedTarget(query: String): Target? {
        var body = query.trim()
        if (body.startsWith("@")) body = body.drop(1)
        if (body.startsWith("nostr:", ignoreCase = true)) body = body.drop("nostr:".length)
        if (body.isEmpty() || !body.all { it.isLetterOrDigit() && it.code < 128 }) return null
        return target(body)
    }
}
