package com.nostrvault.service.shareportal.handlers

import com.nostrvault.util.findAllOnce

/**
 * Who a shared profile link names: the `npub` / `nprofile` identifiers in what was shared, in the order the review
 * card tries them (the link first, then the text, then the selection), each once. Pure and fixture-tested
 * (profile-cases.json); mirrors ProfileShareTarget.swift. Decoding to a pubkey is the app's own NIP-19 decoder
 * ([com.nostrvault.relay.HavenBridge]), which checks the checksum, so a mistyped identifier names nobody.
 */
object ProfileShareTarget {
    private const val BECH32 = "[qpzry9x8gf2tvdw0s3jn54khce6mua7l]"
    /** The same shapes the classifier offers Profile for (ShareClassifier). */
    private val pattern = Regex("\\b(?:npub1$BECH32{58}|nprofile1$BECH32{20,})\\b")
    /** More than this many is a list of people, not a profile link. */
    const val MAX_IDENTIFIERS = 20

    fun identifiers(url: String?, text: String?, selection: String?): List<String> {
        val out = mutableListOf<String>()
        for (field in listOf(url, text, selection)) {
            if (field.isNullOrEmpty()) continue
            for (m in pattern.findAllOnce(field)) {
                if (m.value !in out) out += m.value
                if (out.size == MAX_IDENTIFIERS) return out
            }
        }
        return out
    }

    /** The hex pubkeys those identifiers name, each once, in the same order; [decode] is the NIP-19 decoder. */
    fun pubkeys(url: String?, text: String?, selection: String?, decode: (String) -> String?): List<String> =
        identifiers(url, text, selection)
            .mapNotNull { id -> decode(id)?.lowercase()?.takeIf { HEX64.matches(it) } }
            .distinct()

    private val HEX64 = Regex("^[0-9a-f]{64}$")
}
