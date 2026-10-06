package com.nostrvault.data.model

/**
 * NIP-88 polls: a kind 1068 poll and the kind 1018 votes on it. The Swift twin
 * is HavenApp/HavenApp/Models/NIP88Poll.swift; keep the rules identical.
 *
 * A poll names its options in `option` tags and the relays its votes go to
 * in `relay` tags. A vote names the poll by `e` and its picks by `response`.
 * Anyone can publish a vote, so the count is kept honest here: one vote per
 * person (their newest), only options the poll has, and nothing after it
 * closes.
 */
object NIP88Poll {
    const val KIND = 1068
    const val RESPONSE_KIND = 1018

    /**
     * How far ahead of the clock a vote may be dated, in seconds. The newest
     * vote per person is the one counted, so a vote dated in 2099 would pin
     * that person's pick forever; this allows only for clock drift.
     */
    const val MAX_FUTURE_SKEW_SECS = 600L

    /** Where votes are looked for and sent, at most this many relays. */
    const val MAX_RELAYS = 8

    enum class PollType { SINGLE, MULTIPLE }

    data class Option(val id: String, val label: String)

    /** A kind 1068 poll, read from its event by [Poll.from]. */
    data class Poll(
        val id: String,
        val pubkey: String,
        val question: String,
        val options: List<Option>,
        val type: PollType,
        /** Unix seconds; null when the poll never closes. */
        val endsAt: Long?,
        val relays: List<String>,
    ) {
        fun isClosed(nowSecs: Long = System.currentTimeMillis() / 1000): Boolean =
            endsAt != null && endsAt <= nowSecs

        companion object {
            /** Null when it is not a poll or has no options to vote on. */
            fun from(id: String, pubkey: String, kind: Int, content: String, tags: List<List<String>>): Poll? {
                if (kind != KIND) return null
                val seen = HashSet<String>()
                val options = tags.mapNotNull { tag ->
                    if (tag.size < 3 || tag[0] != "option") return@mapNotNull null
                    val optionId = tag[1].trim()
                    val label = tag[2].trim()
                    if (optionId.isEmpty() || label.isEmpty() || !seen.add(optionId)) null
                    else Option(optionId, label)
                }
                if (options.isEmpty()) return null
                val typeTag = tags.firstOrNull { it.size >= 2 && it[0] == "polltype" }?.get(1)
                val endsAt = tags.firstOrNull { it.size >= 2 && it[0] == "endsAt" }?.get(1)
                    ?.toDoubleOrNull()?.takeIf { it > 0 }?.toLong()
                return Poll(
                    id = id,
                    pubkey = pubkey,
                    question = content.trim(),
                    options = options,
                    type = if (typeTag == "multiplechoice") PollType.MULTIPLE else PollType.SINGLE,
                    endsAt = endsAt,
                    relays = tags.filter { it.size >= 2 && it[0] == "relay" }.map { it[1] },
                )
            }
        }
    }

    /** The parts of a kind 1018 vote the count reads. The caller checks signatures. */
    data class Response(
        val id: String,
        val pubkey: String,
        val kind: Int,
        val createdAt: Long,
        val tags: List<List<String>>,
    )

    /** Relay filter (JSON) for a poll's votes. */
    fun responseFilter(pollId: String, limit: Int = 1_000): String =
        """{"kinds":[$RESPONSE_KIND],"#e":["$pollId"],"limit":$limit}"""

    /** NIP-88 vote tags: the poll, then one `response` per pick. */
    fun responseTags(poll: Poll, optionIds: List<String>, relayHint: String): List<List<String>> {
        val known = poll.options.map { it.id }.toSet()
        val picks = optionIds.filter { it in known }.distinct()
        return buildList {
            add(listOf("e", poll.id, relayHint))
            add(listOf("p", poll.pubkey))
            for (id in if (poll.type == PollType.SINGLE) picks.take(1) else picks) add(listOf("response", id))
        }
    }

    /**
     * The relays to read votes from and send them to: the poll's own first
     * (NIP-88 says votes go there), then [fallback], deduplicated.
     */
    fun relays(poll: Poll, fallback: List<String>): List<String> {
        val seen = HashSet<String>()
        return (poll.relays + fallback)
            .map { it.trim() }
            .filter { it.startsWith("wss://") || it.startsWith("ws://") }
            .filter { seen.add(it.lowercase().trim('/')) }
            .take(MAX_RELAYS)
    }

    /**
     * Counts the votes on [poll]. The caller checks signatures; this checks
     * that each vote is for this poll, in time, and for options it has.
     */
    fun tally(responses: List<Response>, poll: Poll, nowSecs: Long = System.currentTimeMillis() / 1000): PollTally {
        val known = poll.options.map { it.id }.toSet()
        val latestAllowed = minOf(nowSecs + MAX_FUTURE_SKEW_SECS, poll.endsAt ?: Long.MAX_VALUE)
        // Each person's newest vote. Ties go to the lower id so every device
        // counts the same vote.
        val newest = HashMap<String, Response>()
        for (r in responses) {
            if (r.kind != RESPONSE_KIND || r.createdAt > latestAllowed) continue
            if (r.tags.none { it.size >= 2 && it[0] == "e" && it[1] == poll.id }) continue
            val current = newest[r.pubkey]
            if (current != null &&
                (current.createdAt > r.createdAt || (current.createdAt == r.createdAt && current.id < r.id))) continue
            newest[r.pubkey] = r
        }

        val picksByVoter = HashMap<String, List<String>>()
        val votersByOption = HashMap<String, MutableSet<String>>()
        for ((pubkey, vote) in newest) {
            var picks = vote.tags
                .filter { it.size >= 2 && it[0] == "response" && it[1] in known }
                .map { it[1] }
                .distinct()
            // A single-choice poll counts the first pick only.
            if (poll.type == PollType.SINGLE) picks = picks.take(1)
            // A newest vote with nothing countable withdraws the person.
            if (picks.isEmpty()) continue
            picksByVoter[pubkey] = picks
            for (pick in picks) votersByOption.getOrPut(pick) { HashSet() }.add(pubkey)
        }
        return PollTally(picksByVoter.keys.toSet(), votersByOption, picksByVoter)
    }
}

/** Who voted for what on one poll. */
data class PollTally(
    /** Everyone whose vote counted. */
    val voters: Set<String> = emptySet(),
    /** The people behind each option, keyed by option id. */
    val votersByOption: Map<String, Set<String>> = emptyMap(),
    /** What each person picked, keyed by pubkey. */
    val picksByVoter: Map<String, List<String>> = emptyMap(),
) {
    fun count(optionId: String): Int = votersByOption[optionId]?.size ?: 0

    /**
     * An option's share of the people who voted, 0..1. In a multiple-choice
     * poll the shares add up to more than 1, the way other clients show it.
     */
    fun share(optionId: String): Double =
        if (voters.isEmpty()) 0.0 else count(optionId).toDouble() / voters.size
}

/** The poll this note is, when it is a NIP-88 poll with options. */
val FeedNote.poll: NIP88Poll.Poll?
    get() = NIP88Poll.Poll.from(id, pubkey, kind, content, tags)

/**
 * What a one-line row shows for a poll: its question, marked as a poll. Null
 * for any other note.
 */
val FeedNote.pollSummary: String?
    get() = poll?.let { p ->
        "Poll: " + p.question.ifEmpty { p.options.joinToString(" / ") { it.label } }
    }
