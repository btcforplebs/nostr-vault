package com.nostrvault.setup

/**
 * The import tour's Ready card counts (PLANS/NV_FIRST_RUN_ENTRY_PLAN_2026_11_05.md §4): only the real ones. A count
 * of 0 is never shown, since right after an import it more often means "not counted yet" than "none". With no real
 * count the card shows [NONE_YET] instead.
 */
data class ReadyCounts(val tiles: List<Pair<Int, String>>) {
    companion object {
        /** How often the card asks the vault before it stops (the vault is back up within a second or two). */
        const val TRIES = 3
        const val TRY_GAP_MS = 1_000L

        const val NONE_YET = "We couldn't count them yet. They'll show in your feed."

        fun from(notes: Int, likes: Int, all: Int) = ReadyCounts(
            listOf(notes to "notes", likes to "likes", all to "in all").filter { it.first > 0 },
        )
    }
}
