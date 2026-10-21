package com.nostrvault.data.model

import java.util.Date

/**
 * The Search tab's who/when filter (iOS `SearchFilter.swift`). Search always
 * runs Global; this narrows what the stream shows and never re-runs it, so
 * flipping a filter is instant and costs the relays nothing.
 */
data class SearchFilter(val who: Who = Who.EVERYONE, val period: Period = Period.ANY_TIME) {

    enum class Who(val label: String, val shortLabel: String) {
        EVERYONE("Everyone", "Everyone"),
        FOLLOWS("People you follow", "Follows"),
        YOU("You", "You"),
    }

    /** iOS `When` (a keyword in Kotlin). */
    enum class Period(val label: String, val shortLabel: String, val windowSeconds: Long?) {
        ANY_TIME("Any time", "Any time", null),
        DAY("Last 24 hours", "24 h", 24 * 60 * 60L),
        WEEK("Last week", "Week", 7 * 24 * 60 * 60L),
        MONTH("Last month", "Month", 30 * 24 * 60 * 60L),
    }

    /** Whether anything is being filtered out. */
    val isActive: Boolean get() = this != ALL

    /** Short form: "Follows", "Week", "You · 24 h". Null when nothing is filtered. */
    val summary: String? get() = parts(Who::shortLabel, Period::shortLabel)

    /**
     * The line under the search field: "People you follow · Last week", or just
     * the one that is on. Full labels, since there is room there. Null when nothing is filtered.
     */
    val caption: String? get() = parts(Who::label, Period::label)

    /** Spoken form: "People you follow, Last week". */
    val accessibilitySummary: String get() = if (isActive) "${who.label}, ${period.label}" else "No filter"

    private fun parts(whoText: (Who) -> String, periodText: (Period) -> String): String? =
        listOfNotNull(
            whoText(who).takeIf { who != Who.EVERYONE },
            periodText(period).takeIf { period != Period.ANY_TIME },
        ).joinToString(" · ").ifEmpty { null }

    /** Whether a note or profile from [pubkey] passes "who". "You" with no account matches nothing. */
    fun allowsAuthor(pubkey: String, own: String?, follows: Set<String>): Boolean = when (who) {
        Who.EVERYONE -> true
        Who.FOLLOWS -> pubkey in follows
        Who.YOU -> !own.isNullOrEmpty() && own == pubkey
    }

    /** Whether a note dated [date] passes "when". */
    fun allowsDate(date: Date, now: Date = Date()): Boolean {
        val window = period.windowSeconds ?: return true
        return now.time - date.time <= window * 1000
    }

    /** [results] narrowed: profiles by who, notes by who and when. Order kept. */
    fun apply(results: GlobalSearchResults, own: String?, follows: Set<String>, now: Date = Date()): GlobalSearchResults {
        if (!isActive) return results
        return GlobalSearchResults(
            profiles = results.profiles.filter { allowsAuthor(it.pubkey, own, follows) },
            notes = results.notes.filter { allowsAuthor(it.pubkey, own, follows) && allowsDate(it.createdAt, now) },
        )
    }

    companion object {
        val ALL = SearchFilter()
    }
}
