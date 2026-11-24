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
    /**
     * How many are ranked, kept and listed (a scrolling list, Logen
     * 2026-11-22: "a longer list than the top ~11"). Topic chips filter it.
     */
    const val POOL = 100

    /**
     * How many start ticked: none. Each person is a choice, made on their row
     * or their preview, not a stranger ticked for you (Logen 2026-11-22).
     */
    const val PRE_TICKED = 0

    /** How many of the referrer's followers are read (kind 3 lists that tag them). */
    const val FOLLOWERS_TO_READ = 500

    /** At most this many topic chips. */
    const val TOPIC_LIMIT = 6

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
     * One person offered: how much the referrer and they interact ([talks],
     * [com.nostrvault.data.model.TrustMap.engagementScores]), how many of the
     * referrer's close circle follow them, and whether they are someone the
     * referrer follows or only one of the referrer's followers.
     */
    data class Pick(val pubkey: String, val close: Int, val talks: Int = 0, val followedByReferrer: Boolean = true)

    /**
     * The referrer's close circle: their mutuals among the [lists] read,
     * follows of theirs whose own list has the referrer in it.
     */
    fun closeCircle(referrer: String, follows: List<String>, lists: Map<String, List<String>>): Set<String> {
        val me = referrer.lowercase()
        return follows.filter { lists[it]?.contains(me) == true }.toSet()
    }

    /**
     * Up to [cap] of the referrer's [follows] and [followers], the people the
     * referrer interacts with most first (Logen 2026-11-22: replies,
     * reactions, zaps and mentions, both ways, [talks]), not the most
     * followed. Ties go to how many of the referrer's close circle
     * ([closeCircle]) follow them, then how many of all the referrer's
     * follows' [lists] name them, then follows before followers, then list
     * order. Lists by anyone outside [follows] are ignored, and an author
     * never counts itself. Never the referrer, or anyone in [skip].
     */
    fun rank(
        referrer: String,
        follows: List<String>,
        lists: Map<String, List<String>>,
        skip: Set<String> = emptySet(),
        cap: Int = POOL,
        talks: Map<String, Int> = emptyMap(),
        followers: List<String> = emptyList(),
    ): List<Pick> {
        val following = follows.toSet()
        val close = closeCircle(referrer, follows, lists)
        val all = HashMap<String, Int>()
        val near = HashMap<String, Int>()
        for ((author, list) in lists) {
            if (author !in following) continue
            val isClose = author in close
            for (key in list.toSet()) {
                if (key == author) continue
                all[key] = (all[key] ?: 0) + 1
                if (isClose) near[key] = (near[key] ?: 0) + 1
            }
        }
        return (follows + followers).asSequence()
            .distinct()
            .filter { it != referrer && it !in skip }
            .withIndex()
            .sortedWith(
                compareByDescending<IndexedValue<String>> { talks[it.value] ?: 0 }
                    .thenByDescending { near[it.value] ?: 0 }
                    .thenByDescending { all[it.value] ?: 0 }
                    .thenBy { it.index },
            )
            .map { Pick(it.value, near[it.value] ?: 0, talks[it.value] ?: 0, it.value in following) }
            .take(cap)
            .toList()
    }

    /**
     * How much [referrer] and each person interact, from [events] by them and
     * aimed at them: [com.nostrvault.data.model.TrustMap.engagementScores] (their
     * own count double, a zap triples). A zap they sent is a receipt signed by
     * the zap service with them in `P`, so it counts as their own.
     */
    fun talks(referrer: String, events: List<com.nostrvault.data.model.TrustMap.Interaction>): Map<String, Int> {
        val sentZaps = events
            .filter { it.kind == 9735 && it.tags.any { t -> t.size > 1 && t[0] == "P" && t[1] == referrer } }
            .map { it.copy(pubkey = referrer) }
        val theirs = events.filter { it.pubkey == referrer } + sentZaps
        return com.nostrvault.data.model.TrustMap.engagementScores(theirs, events, referrer)
    }

    /** A topic chip: a hashtag and who of the people offered used it. */
    data class Topic(val topic: String, val people: Set<String>)

    /**
     * Topic chips for the people offered: the hashtags (`t` tags) the most of
     * them used in their recent notes or interest lists, each counted once per
     * person, and only when at least two of them used it. Most-shared first,
     * then by name. iOS `ReferralSuggestions.topics`.
     * - notes: (author, tags) of the events read.
     */
    fun topics(notes: List<Pair<String, List<List<String>>>>, among: List<String>, limit: Int = TOPIC_LIMIT): List<Topic> {
        val wanted = among.toSet()
        val users = HashMap<String, MutableSet<String>>()
        for ((author, tags) in notes) {
            if (author !in wanted) continue
            for (tag in tags) {
                if (tag.size < 2 || tag[0] != "t") continue
                val topic = tag[1].trim().trim('#').lowercase()
                if (topic.length !in 2..24 || topic.all(Char::isDigit)) continue
                users.getOrPut(topic) { mutableSetOf() }.add(author)
            }
        }
        return users.filter { it.value.size >= 2 }
            .entries
            .sortedWith(compareByDescending<Map.Entry<String, MutableSet<String>>> { it.value.size }.thenBy { it.key })
            .take(limit)
            .map { Topic(it.key, it.value) }
    }
}
