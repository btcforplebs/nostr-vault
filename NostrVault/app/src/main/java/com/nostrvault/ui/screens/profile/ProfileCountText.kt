package com.nostrvault.ui.screens.profile

import java.util.Locale

/** How the profile writes its counts (iOS ProfileView `shortInt` and `countText`). */
internal object ProfileCountText {
    /** 639, 1.0k, 2.3M. */
    fun short(n: Int): String = when {
        n >= 1_000_000 -> String.format(Locale.ROOT, "%.1fM", n / 1_000_000.0)
        n >= 1_000 -> String.format(Locale.ROOT, "%.1fk", n / 1_000.0)
        else -> n.toString()
    }

    /**
     * "48", or "48+" while older pages may still raise it. Nothing loaded yet
     * with more to come reads "—", as Following does before it knows.
     */
    fun of(n: Int, hasMore: Boolean): String = when {
        !hasMore -> short(n)
        n == 0 -> "—"
        else -> short(n) + "+"
    }
}
