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
    /** How many people are offered with no topic picked (iOS `limit`). */
    const val SUGGESTION_CAP = 10

    /** How many are ranked and kept, so a topic chip still has people to show (iOS `pool`). */
    const val POOL = 30

    /** How many of the top ones start ticked (iOS `preTicked`). */
    const val PRE_TICKED = 7

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

    /** One person offered, and how many of the referrer's close circle follow them. */
    data class Pick(val pubkey: String, val close: Int)

    /**
     * The referrer's close circle: their mutuals among the [lists] read,
     * follows of theirs whose own list has the referrer in it.
     */
    fun closeCircle(referrer: String, follows: List<String>, lists: Map<String, List<String>>): Set<String> {
        val me = referrer.lowercase()
        return follows.filter { lists[it]?.contains(me) == true }.toSet()
    }

    /**
     * Up to [cap] of [follows], closest to the referrer first (setup screens
     * r3, Logen 2026-11-22, iOS `ReferralSuggestions.rank` #2414): a follow
     * comes first when more of the referrer's close circle ([closeCircle])
     * follow them too. Ties go to how many of all the referrer's follows'
     * [lists] name them, then to the referrer's own list order. With no mutual
     * found, the overall count decides, as before. Lists by anyone outside
     * [follows] are ignored, and an author never counts itself. Never the
     * referrer, or anyone in [skip].
     */
    fun rank(
        referrer: String,
        follows: List<String>,
        lists: Map<String, List<String>>,
        skip: Set<String> = emptySet(),
        cap: Int = POOL,
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
        return follows.asSequence()
            .distinct()
            .filter { it != referrer && it !in skip }
            .withIndex()
            .sortedWith(
                compareByDescending<IndexedValue<String>> { near[it.value] ?: 0 }
                    .thenByDescending { all[it.value] ?: 0 }
                    .thenBy { it.index },
            )
            .map { Pick(it.value, near[it.value] ?: 0) }
            .take(cap)
            .toList()
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
