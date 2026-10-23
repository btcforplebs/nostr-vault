package com.nostrvault.data.model

/**
 * The feeds' Web of Trust switch stays on until you follow enough people for
 * it to mean something: with fewer, "Everyone" is the whole unfiltered
 * firehose and the trust filter has nothing to stand on. Only turning it off
 * is locked; an account that already shows everyone keeps that, and coming
 * back to the Web of Trust is always allowed.
 */
object WotUnlock {
    const val MIN_FOLLOWS = 5

    /** People you follow, not counting yourself (your own list names you). */
    fun followCount(followed: Collection<String>, self: String): Int =
        followed.map { it.lowercase() }.toSet().minus(self.lowercase()).size

    /** How many more follows unlock the switch; 0 when it is unlocked. */
    fun followsNeeded(count: Int): Int = (MIN_FOLLOWS - count).coerceAtLeast(0)

    /** "Follow 3 more people to unlock Everyone" (iOS `TrustScopeLock.progressText`). */
    fun progressLine(needed: Int): String =
        "Follow $needed more ${if (needed == 1) "person" else "people"} to unlock Everyone"
}
