package com.nostrvault.service

import java.net.URI

/**
 * Which extra relays the Following feed asks, and for whom (the NIP-65
 * outbox model, sized for a phone). Port of iOS `FeedOutboxPlan` (#227).
 *
 * The feed used to ask only the owner's feed relays, so a follow who never
 * writes to any of them was invisible. Measured 2026-10-04 (iOS) for an
 * account following 992 people: 56 of the 411 follows with a relay list wrote
 * to none of its 6 feed relays, and 7 of the 9 notes missing from two hours of
 * its feed were on relays it never asked.
 *
 * Asking every follow's relays would open hundreds of sockets. Instead a
 * greedy cover picks the few relays that reach the most uncovered follows,
 * and each is asked only for the follows it was picked for.
 *
 * Most follows publish no relay list at all (581 of those 992), so they go
 * to one fallback relay. Of their notes over three hours, the feed relays
 * had 53 of 59; relay.ditto.pub had all 59. Re-measure before changing it.
 */
object FeedOutboxPlan {
    /** Extra sockets the feed may open on top of the feed relays, fallback included. */
    const val MAX_EXTRA_RELAYS = 8
    const val FALLBACK_RELAY = "wss://relay.ditto.pub"

    /**
     * @param follows the authors the feed shows.
     * @param writeRelays each author's NIP-65 write relays, where known.
     * @param feedRelays the relays the feed already asks for everyone.
     * @param unreachableRelays relays failing right now. A follow whose only
     *   feed relay is down is not reached by it, and a down relay is never picked.
     * @param fallbackRelay asked for the follows with no usable relay list;
     *   null to skip them.
     * @return extra relay URL → the follows to ask it for (sorted). Each follow
     *   appears under one relay only: the first pick that reached them.
     */
    fun plan(
        follows: Collection<String>,
        writeRelays: Map<String, List<String>>,
        feedRelays: Collection<String>,
        unreachableRelays: Collection<String> = emptyList(),
        fallbackRelay: String? = FALLBACK_RELAY,
        maxExtraRelays: Int = MAX_EXTRA_RELAYS,
    ): Map<String, List<String>> {
        val down = unreachableRelays.mapNotNull(::normalizedKey).toSet()
        val asked = feedRelays.mapNotNull(::normalizedKey).toSet() - down
        // Follows none of whose write relays the feed already asks, with the
        // relays that would reach them.
        val candidates = HashMap<String, MutableSet<String>>()   // relay key → follows
        val urlForKey = HashMap<String, String>()
        val unlisted = HashSet<String>()
        for (author in follows.toSet()) {
            val usable = (writeRelays[author] ?: emptyList()).mapNotNull { raw ->
                val key = normalizedKey(raw)?.takeIf { it !in down } ?: return@mapNotNull null
                urlForKey.getOrPut(key) { raw.trim() }
                key
            }
            if (usable.isEmpty()) {
                unlisted.add(author)
                continue
            }
            if (usable.any { it in asked }) continue
            for (key in usable) candidates.getOrPut(key) { HashSet() }.add(author)
        }

        val plan = LinkedHashMap<String, List<String>>()
        val covered = HashSet<String>()
        // The fallback first: it takes a slot only when someone needs it.
        val fallbackKey = fallbackRelay?.let(::normalizedKey)
        if (unlisted.isNotEmpty() && fallbackRelay != null && fallbackKey != null &&
            fallbackKey !in asked && fallbackKey !in down && maxExtraRelays > 0
        ) {
            urlForKey[fallbackKey] = fallbackRelay
            // Listed follows the fallback relay reaches are taken there too.
            val reached = candidates.remove(fallbackKey) ?: emptySet()
            covered.addAll(reached)
            plan[fallbackRelay] = (unlisted + reached).sorted()
        }
        while (plan.size < maxExtraRelays) {
            // Most still-uncovered follows wins; ties go to the smaller key so
            // the same inputs always pick the same relays.
            var bestKey: String? = null
            var bestGain = 0
            for ((key, authors) in candidates) {
                val gain = authors.count { it !in covered }
                if (gain == 0) continue
                if (bestKey == null || gain > bestGain || (gain == bestGain && key < bestKey)) {
                    bestKey = key
                    bestGain = gain
                }
            }
            val pick = bestKey ?: break
            val url = urlForKey[pick] ?: break
            val newlyCovered = (candidates.remove(pick) ?: emptySet()).filter { it !in covered }
            covered.addAll(newlyCovered)
            plan[url] = newlyCovered.sorted()
        }
        return plan
    }

    /**
     * `wss://Host/` and `wss://host` are one relay. Only public `wss` relays
     * qualify: a plain `ws://`, a loopback or LAN address, or an onion host is
     * somebody else's private setup and cannot be reached from this phone.
     */
    fun normalizedKey(raw: String): String? {
        val uri = try {
            URI(raw.trim())
        } catch (_: Exception) {
            return null
        }
        if (uri.scheme?.lowercase() != "wss") return null
        val host = uri.host?.lowercase() ?: return null
        if ("." !in host || host.endsWith(".onion") || host.endsWith(".local") ||
            host == "localhost" || host.startsWith("127.") || host.startsWith("192.168.") ||
            host.startsWith("10.")
        ) return null
        val port = if (uri.port != -1) ":${uri.port}" else ""
        val path = (uri.path ?: "").removeSuffix("/")
        return "wss://$host$port$path"
    }
}
