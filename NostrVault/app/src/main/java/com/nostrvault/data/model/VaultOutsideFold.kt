package com.nostrvault.data.model

/**
 * The Vault list's fold for strangers' likes and reposts (Logen 2026-11-13
 * "go all", option A): All leaves them out ([VaultActivity.Companion.build]
 * `foldsOutsideLikes`) and shows one "N from outside your web" line instead,
 * which opens the "Outside your web" filter where they are listed. iOS
 * `VaultActivity+OutsideFold.swift`, web `net/outside-fold.js`.
 */
object VaultOutsideFold {
    /** The kinds that fold when they come from outside your web. Zaps cost the sender sats and follows are about you, so both keep their lines. */
    val FOLDED_KINDS: Set<VaultActivity.Kind> = setOf(VaultActivity.Kind.REACTION, VaultActivity.Kind.REPOST)

    /**
     * The line's N: each person once per line, as the faces count them. In
     * Zaps Only mode likes don't show anywhere, so they don't count.
     */
    fun count(outsideLines: List<VaultActivity>, zapsOnly: Boolean = false): Int =
        outsideLines
            .filter { it.kind in FOLDED_KINDS && !(zapsOnly && it.kind == VaultActivity.Kind.REACTION) }
            .sumOf { it.actors.size }

    /** "3 from outside your web". */
    fun label(count: Int): String = "$count from outside your web"
}
