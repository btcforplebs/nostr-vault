package com.nostrvault.util

/**
 * The words a zap carries (the zap request's `content`, NIP-57). Twin of iOS ZapComment.swift.
 *
 * Only the user writes them. A one-tap zap carries nothing, and the amount sheet's comment box
 * is optional; there is no app-supplied default.
 */
object ZapComment {
    /** Longest comment the box accepts. Zap requests travel in the LNURL callback URL. */
    const val MAX_LENGTH = 280

    /** What the zap request carries for [typed]: trimmed, capped, or "" when nothing was written. */
    fun content(typed: String): String = typed.trim().take(MAX_LENGTH)
}
