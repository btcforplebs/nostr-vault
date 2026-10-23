package com.nostrvault.setup

/**
 * "Who told you about Nostr Vault?" in setup: whoever it was, and which of the
 * people they follow to follow too.
 *
 * A plain object because the choice outlives the wizard: it is made mid-setup
 * but can only be signed once setup has stored the key and made the account
 * active, so `completeSetup` takes it from here. A `/p/` link opened before
 * setup leaves its id here too, and the step starts with it filled in.
 */
object ReferrerFollows {
    /** The most people the step offers from the referrer's follows. */
    const val SUGGESTION_CAP = 10

    /** How many of the referrer's follows have their own lists read to rank with (iOS `listsToRead`). */
    const val LISTS_TO_READ = 150

    /** The p-tagged pubkeys of a kind 3, lowercased, each once, in order. */
    fun follows(tags: List<List<String>>): List<String> {
        val hex = Regex("^[0-9a-f]{64}$")
        return tags.asSequence()
            .filter { it.size >= 2 && it[0] == "p" }
            .map { it[1].lowercase() }
            .filter { hex.matches(it) }
            .distinct()
            .toList()
    }

    /**
     * How many of the referrer's follows' [lists] name each person, a list's
     * author not counting itself. Lists by anyone outside [referrerFollows]
     * are ignored. iOS `ReferralSuggestions.rank`.
     */
    fun vouches(referrerFollows: List<String>, lists: Map<String, List<String>>): Map<String, Int> {
        val following = referrerFollows.toSet()
        val counts = HashMap<String, Int>()
        for ((author, follows) in lists) {
            if (author !in following) continue
            for (key in follows.toSet()) if (key != author) counts[key] = (counts[key] ?: 0) + 1
        }
        return counts
    }

    /** The `npub1…` / `nprofile1…` / hex id from a `/p/` link opened before setup. */
    @Volatile var prefill: String? = null

    /** The referrer first, then the ticked suggestions. Empty when skipped. */
    @Volatile private var picks: List<String> = emptyList()

    fun choose(referrer: String, alsoFollow: List<String>) {
        picks = (listOf(referrer) + alsoFollow).distinct()
    }

    fun clear() { picks = emptyList() }

    /** The picks, once: a second call (or a second setup) gets nothing. */
    fun take(): List<String> = picks.also { picks = emptyList() }

    /**
     * Up to [cap] of [follows] to offer, most-followed first: by how many of
     * the referrer's follows' lists name them ([vouches]), ties in the
     * referrer's own list order. Never the referrer, you, or anyone in [skip].
     */
    fun suggestions(
        referrer: String,
        follows: List<String>,
        vouches: Map<String, Int>,
        skip: Set<String> = emptySet(),
        cap: Int = SUGGESTION_CAP,
    ): List<String> = follows.asSequence()
        .distinct()
        .filter { it != referrer && it !in skip }
        .withIndex()
        .sortedWith(compareByDescending<IndexedValue<String>> { vouches[it.value] ?: 0 }.thenBy { it.index })
        .map { it.value }
        .take(cap)
        .toList()
}
