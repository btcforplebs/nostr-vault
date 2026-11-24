package com.nostrvault.data.model

/**
 * How someone far out connects to you: the chain of follows from one of
 * your own follows to them, walked back through the globe list's `via`
 * links ([TrustRankCopy.GlobeRow]) with no relay call. "You > A > B > them".
 * iOS `Models/TrustChain.swift`.
 */
object TrustChain {
    /**
     * Ring-1 person first, [pubkey] last; null when they are not in the globe
     * list or a link is missing or loops. A ring-1 `via` must be one of your
     * follows in [TrustRankCopy.people] at hop 1, and each link must be one
     * ring nearer than the one before.
     */
    fun of(pubkey: String, copy: TrustRankCopy?): List<String>? {
        if (copy == null) return null
        var row = copy.globeRow(pubkey) ?: return null
        val chain = ArrayList<String>(row.hop)
        chain.add(row.pubkey)
        while (true) {
            if (row.hop == 2) {
                if (copy[row.via]?.hop != 1) return null
                chain.add(row.via)
                return chain.asReversed().toList()
            }
            val next = copy.globeRow(row.via) ?: return null
            if (next.hop != row.hop - 1) return null
            chain.add(next.pubkey)
            row = next
        }
    }

    /** "You > A > B > them", names from [name]. */
    fun text(chain: List<String>, name: (String) -> String): String =
        (listOf("You") + chain.map(name)).joinToString(" > ")
}
