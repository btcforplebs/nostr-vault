package com.nostrvault.util

import com.nostrvault.relay.HavenBridge

/**
 * Finds a real secret key (`nsec1…`) in text the app is about to publish, or
 * in a profile it has read (Logen 2026-11-20, research
 * RESEARCH/NV_PUBLIC_NSEC_ACCOUNTS_2026_11_20.md: people paste their nsec into
 * a sign-up name box). Twin of Apple `SecretKeyLeak.swift` and web
 * `secret-key-leak.js`.
 *
 * Only a whole BIP-173 bech32 string counts: "nsec1" plus 58 characters, one
 * case, a valid checksum and 32 bytes of key. A prefix, a truncated key or a
 * typo is not a key and is left alone.
 *
 * The key never leaves this object's local variables: nothing here logs,
 * stores or sends it.
 */
object SecretKeyLeak {

    /** What the composer, profile form or DM box shows. No override. */
    const val MESSAGE = "This is a secret key. Publishing it lets anyone post as you."

    private const val PREFIX = "nsec1"
    /** "nsec1" + 52 data characters + 6 checksum characters. */
    private const val LENGTH = 63
    private const val CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"

    /** True when [text] holds at least one checksum-valid nsec. */
    fun containsSecretKey(text: String?): Boolean {
        if (text.isNullOrEmpty()) return false
        var found = false
        forEachSecretHex(text) { found = true; false }
        return found
    }

    /**
     * The x-only public key (hex) of every nsec in [text], deduplicated.
     * [derive] turns a secret key's hex into its public key's hex; the
     * default is the app's own secp256k1 (libhaven), null when it isn't loaded.
     */
    fun derivedPubkeys(
        text: String?,
        derive: (String) -> String? = ::deriveWithHaven,
    ): List<String> {
        if (text.isNullOrEmpty()) return emptyList()
        val out = LinkedHashSet<String>()
        forEachSecretHex(text) { secretHex ->
            derive(secretHex)?.lowercase()?.takeIf { it.length == 64 }?.let { out.add(it) }
            true
        }
        return out.toList()
    }

    /** Throws [SecretKeyLeakException] when [text] holds an nsec. */
    fun requireNone(text: String?) {
        if (containsSecretKey(text)) throw SecretKeyLeakException()
    }

    /**
     * Kinds whose content is someone else's event, which the app does not
     * write: a repost of a note that already shows a key is not a new leak.
     */
    private val unguardedKinds = setOf(6, 16)

    /** True when an event of [kind] with [content] and [tags] would publish an nsec. */
    fun eventLeaksKey(kind: Int, content: String, tags: List<List<String>>): Boolean {
        if (kind in unguardedKinds) return false
        if (containsSecretKey(content)) return true
        return tags.any { tag -> tag.any { containsSecretKey(it) } }
    }

    /** The signer's check, before any signer sees the event. */
    fun requireEventSafe(kind: Int, content: String, tags: List<List<String>>) {
        if (eventLeaksKey(kind, content, tags)) throw SecretKeyLeakException()
    }

    /**
     * Calls [onKey] with the hex of each checksum-valid nsec in [text], in
     * order, until it returns false. Every "nsec1" is tried, so a key that
     * follows other letters ("mynsec1…") or another "nsec1" is still found.
     */
    private inline fun forEachSecretHex(text: String, onKey: (String) -> Boolean) {
        var from = 0
        while (true) {
            val at = text.indexOf(PREFIX, from, ignoreCase = true)
            if (at < 0 || at + LENGTH > text.length) return
            from = at + 1
            val token = text.substring(at, at + LENGTH)
            val hex = secretHex(token) ?: continue
            if (!onKey(hex)) return
        }
    }

    /** The key's hex when [token] is exactly one valid nsec, else null. */
    private fun secretHex(token: String): String? {
        // BIP-173: one case only.
        val lower = token.lowercase()
        if (token != lower && token != token.uppercase()) return null
        for (i in PREFIX.length until lower.length) {
            if (CHARSET.indexOf(lower[i]) < 0) return null
        }
        // Checksum, hrp and 32-byte length: the app's own bech32 decoder.
        return HavenBridge.decodeNsec(lower)
    }

    private fun deriveWithHaven(secretHex: String): String? =
        if (HavenBridge.isLoaded) runCatching { HavenBridge.getPublicKey(secretHex) }.getOrNull() else null
}

/** A publish refused because it holds a secret key; its message is [SecretKeyLeak.MESSAGE]. */
class SecretKeyLeakException : IllegalStateException(SecretKeyLeak.MESSAGE)
