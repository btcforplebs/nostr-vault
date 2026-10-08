package com.nostrvault.data.model

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/**
 * Which posts the topic feed shows to an account with no web of trust yet
 * (Fill your feed). Unfiltered, a tag like #bitcoin was ~95% bots and link
 * farms (sampled 2026-10-08: 569 posts → 29 from 23 people). Every rule here
 * is a fact about the post or its author, never a list of people we chose,
 * so nobody's web of trust is steered. Port of iOS `TopicFeedFilter`.
 *
 * - The author follows at least [MIN_FOLLOWS] people. Bots and farms almost
 *   never follow anyone; people do. Unknown counts wait until looked up.
 * - Fewer than [MAX_HASHTAGS] hashtags (hashtag stuffing).
 * - Not a link to a site that [FARM_AUTHORS]+ different accounts link to in
 *   the same feed (how farms post). Images and video don't count.
 * - Not a copy of text already shown.
 * - At most [PER_AUTHOR] posts per person, so one voice can't fill the page.
 * - Not marked adult (#nsfw and the like, or a NIP-36 content warning).
 * - Not posted by an app or game on its player's behalf: the post's
 *   `client` tag names the site it links to (Plebs vs. Zombies scores,
 *   holdbtc). Sampled 2026-10-08 these were most of #nostr's leftover junk.
 */
object TopicFeedFilter {
    /** 20, not 10: the scheduled-content bots that got past 10 follow exactly
     *  10 (sampled 2026-10-08: BTC Globe Live, Situation Room, Money Bot). At
     *  30 real people start dropping out. */
    const val MIN_FOLLOWS = 20
    const val MAX_HASHTAGS = 6
    const val FARM_AUTHORS = 4
    const val PER_AUTHOR = 2

    /** Different people (not the author) who must have replied, reposted,
     *  liked or zapped a post for it to go first. Sampled 2026-10-08 this
     *  left only people: #bitcoin 37 → 11, #nostr 71 → 11, no games or ads. */
    const val MIN_RESPONDERS = 2

    data class Post(val id: String, val pubkey: String, val content: String, val tags: List<List<String>>)

    /** [posts] newest first. [followCounts]: how many people each author
     *  follows (their kind 3), absent while unknown. Returns the ids to show,
     *  in the same order. */
    fun shown(posts: List<Post>, followCounts: Map<String, Int>): List<String> {
        val domainAuthors = HashMap<String, MutableSet<String>>()
        for (post in posts) {
            for (domain in linkDomains(post.content)) domainAuthors.getOrPut(domain) { HashSet() }.add(post.pubkey)
        }
        val farms = domainAuthors.filterValues { it.size >= FARM_AUTHORS }.keys

        val seenText = HashSet<String>()
        val perAuthorCount = HashMap<String, Int>()
        val out = ArrayList<String>()
        for (post in posts) {
            val follows = followCounts[post.pubkey] ?: continue
            if (follows < MIN_FOLLOWS) continue
            if (hashtagCount(post.tags) >= MAX_HASHTAGS) continue
            if (linkDomains(post.content).any { it in farms }) continue
            if (isAdult(post.tags) || isAppMade(post)) continue
            if (!seenText.add(textKey(post.content))) continue
            val count = perAuthorCount[post.pubkey] ?: 0
            if (count >= PER_AUTHOR) continue
            perAuthorCount[post.pubkey] = count + 1
            out += post.id
        }
        return out
    }

    /** [ids] as [shown] returned them, with the posts people responded to
     *  moved to the front. Both groups keep their order; nothing is dropped. */
    fun ordered(ids: List<String>, responders: Map<String, Int>): List<String> {
        val (answered, rest) = ids.partition { (responders[it] ?: 0) >= MIN_RESPONDERS }
        return answered + rest
    }

    val adultHashtags = setOf("nsfw", "porn", "xxx", "nude", "nudes", "onlyfans")

    fun isAdult(tags: List<List<String>>): Boolean = tags.any { tag ->
        tag.firstOrNull() == "content-warning" ||
            (tag.size >= 2 && tag[0] == "t" && tag[1].lowercase() in adultHashtags)
    }

    /** Everyday Nostr apps. Sharing a note's web link from the app you're in
     *  (Damus and damus.io) is a person posting, not the app. */
    val generalClients = setOf(
        "damus", "primal", "primalandroid", "primalios", "snort", "coracle", "yakihonne",
        "nostrudel", "amethyst", "iris", "nostrich", "jumble", "ditto", "olas", "nostur",
        "nostrapp", "habla", "highlighter", "zapstore", "nostrvault", "haven",
    )

    /** The `client` tag and a linked site's name agree ("Plebs vs. Zombies"
     *  and plebsvszombies.cc): the app wrote this post, not the person. The
     *  poster writes the `client` tag, so this only catches apps that label
     *  themselves honestly. It is housekeeping, not a spam defence. */
    fun isAppMade(post: Post): Boolean {
        val clients = post.tags.filter { it.size >= 2 && it[0] == "client" }
            .map { lettersOnly(it[1]) }
            .filter { it.length >= 4 && it !in generalClients }
        if (clients.isEmpty()) return false
        val sites = linkDomains(post.content).map { host ->
            val labels = host.split(".")
            lettersOnly(if (labels.size >= 2) labels[labels.size - 2] else labels.firstOrNull().orEmpty())
        }.filter { it.length >= 4 }
        return clients.any { client -> sites.any { client.contains(it) || it.contains(client) } }
    }

    /**
     * Who responded. A zap receipt (9735) is signed by the zap service, so
     * the person is the signer of the zap request (9734) inside it, and only
     * if that request's own signature checks out ([isValid], given the
     * request's JSON); a `P` tag that disagrees with it voids the receipt.
     * Unsigned names would let one wallet key mint any number of "zappers".
     */
    fun responder(event: JsonObject, isValid: (String) -> Boolean): String? {
        // Safe casts throughout: anyone can publish a receipt, and `.jsonPrimitive`
        // throws on an object or array.
        val pubkey = (event["pubkey"] as? JsonPrimitive)?.contentOrNull
        if ((event["kind"] as? JsonPrimitive)?.intOrNull != 9735) return pubkey
        val tags = tagsOf(event)
        val description = tags.firstOrNull { it.size >= 2 && it[0] == "description" }?.get(1) ?: return null
        val request = try {
            Json.parseToJsonElement(description) as? JsonObject
        } catch (e: Exception) {
            null
        } ?: return null
        if ((request["kind"] as? JsonPrimitive)?.intOrNull != 9734 || !isValid(description)) return null
        val sender = (request["pubkey"] as? JsonPrimitive)?.contentOrNull ?: return null
        val claimed = tags.firstOrNull { it.size >= 2 && it[0] == "P" }?.get(1)
        if (claimed != null && claimed != sender) return null
        return sender
    }

    fun tagsOf(event: JsonObject): List<List<String>> = try {
        event["tags"]?.jsonArray?.map { tag -> tag.jsonArray.map { it.jsonPrimitive.contentOrNull.orEmpty() } }.orEmpty()
    } catch (e: Exception) {
        emptyList()
    }

    fun hashtagCount(tags: List<List<String>>): Int = tags.count { it.size >= 2 && it[0] == "t" }

    /** Lowercased, whitespace-collapsed, links dropped (farms vary the link). */
    fun textKey(content: String): String = content.lowercase()
        .split(Regex("\\s+"))
        .filter { it.isNotEmpty() && !it.startsWith("http://") && !it.startsWith("https://") && !it.startsWith("nostr:") }
        .joinToString(" ")
        .take(120)

    private val mediaExtensions = setOf("jpg", "jpeg", "png", "gif", "webp", "heic", "mp4", "mov", "webm")

    /** Scheme, optional user info, host, then the path up to any query or
     *  fragment. Lenient on purpose, like iOS `URL(string:)`: `java.net.URI`
     *  rejects `|`, `{` or a bare `%` and drops hosts with `_`, which would
     *  let a farm's links slip past the farm check. */
    private val linkPattern = Regex("^https?://(?:[^/?#@]*@)?([^/?#:]+)(?::\\d*)?([^?#]*)", RegexOption.IGNORE_CASE)

    /** Hosts of the non-media links in a post. */
    fun linkDomains(content: String): Set<String> {
        val out = HashSet<String>()
        for (word in content.split(Regex("\\s+"))) {
            if (!word.startsWith("http://") && !word.startsWith("https://")) continue
            val match = linkPattern.find(word) ?: continue
            val host = match.groupValues[1].lowercase().takeIf { it.isNotEmpty() } ?: continue
            val extension = match.groupValues[2].substringAfterLast('/').substringAfterLast('.', "").lowercase()
            if (extension in mediaExtensions) continue
            out += host
        }
        return out
    }

    private fun lettersOnly(text: String): String =
        text.lowercase().filter { it in 'a'..'z' || it in '0'..'9' }
}
