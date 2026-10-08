package com.nostrvault.relay

/**
 * The relay matrix: every relay the owner uses, one row each, and the jobs it
 * does. Each job is still its own list underneath, so every feature that reads
 * a list keeps working:
 *
 * - Read: [HavenConfig.feedRelays] ([HavenConfig.readRelays])
 * - Write: [HavenConfig.blastrRelays] ([HavenConfig.writeRelays])
 * - DMs: [HavenConfig.dmRelays] (published as kind 10050)
 * - Search: [HavenConfig.searchRelays]
 * - Import: [HavenConfig.importSeedRelays]
 *
 * Read and Write together are the public relay list (kind 10002). Mirrors
 * iOS `RelayMatrix`.
 */
object RelayMatrix {

    enum class Job(val title: String, val detail: String) {
        READ("Read", "Load your feed, profiles and threads from here"),
        WRITE("Write", "Publish your posts here"),
        DMS("DMs", "Inbox for private messages"),
        SEARCH("Search", "Send searches here"),
        IMPORT("Import", "Pull your history into your relay");

        companion object {
            /** Grid columns; the rest are tags under the name and switches in the detail. */
            val columns = listOf(READ, WRITE, DMS, SEARCH)
            val advanced = listOf(IMPORT)
        }
    }

    /**
     * The relays in [urls] with no speed yet. An edit probes only these, so
     * the rows already timed keep their dots instead of all going grey.
     */
    fun needingProbe(urls: List<String>, known: Set<String>): List<String> =
        urls.filter { it.isNotEmpty() && key(it) !in known }

    /** The lists the matrix edits, as stored. */
    data class Lists(
        val read: List<String>,
        val write: List<String>,
        val dms: List<String>,
        val search: List<String>,
        val import: List<String>,
    ) {
        operator fun get(job: Job): List<String> = when (job) {
            Job.READ -> read
            Job.WRITE -> write
            Job.DMS -> dms
            Job.SEARCH -> search
            Job.IMPORT -> import
        }

        fun with(job: Job, list: List<String>): Lists = when (job) {
            Job.READ -> copy(read = list)
            Job.WRITE -> copy(write = list)
            Job.DMS -> copy(dms = list)
            Job.SEARCH -> copy(search = list)
            Job.IMPORT -> copy(import = list)
        }
    }

    data class Row(val url: String, val jobs: Set<Job>) {
        val id: String get() = key(url)
        fun has(job: Job) = job in jobs
    }

    /** Two spellings of one relay compare equal: case, whitespace and trailing slashes are ignored. */
    fun key(url: String): String = DMInbox.normalizedRelayURL(url).lowercase()

    /** The lists as this config stores them. Read is the wizard's inbox list until a feed list is set. */
    fun lists(config: HavenConfig): Lists = Lists(
        read = config.feedRelays ?: config.activeInboxRelays,
        write = config.blastrRelays,
        dms = config.dmRelays,
        search = config.activeSearchRelays,
        import = config.importSeedRelays,
    )

    /** Writes the lists back. Search goes back to "defaults" (null) when it equals them. */
    fun applying(lists: Lists, to: HavenConfig): HavenConfig = to.copy(
        feedRelays = lists.read,
        blastrRelays = lists.write,
        dmRelays = lists.dms,
        searchRelays = lists.search.takeUnless { to.searchRelays == null && it == to.activeSearchRelays },
        importSeedRelays = lists.import,
    )

    /**
     * One row per relay, in the order relays first appear across the jobs
     * (Read, Write, DMs, Search, Import). [pinned] (the owner's own relay and
     * its DM inbox) is left out: it has its own row.
     */
    fun rows(lists: Lists, pinned: List<String> = emptyList()): List<Row> {
        val pinnedKeys = pinned.filter { it.isNotBlank() }.map(::key).toSet()
        val order = mutableListOf<String>()
        val firstSpelling = HashMap<String, String>()
        val jobs = HashMap<String, MutableSet<Job>>()
        for (job in Job.entries) {
            for (raw in lists[job]) {
                val url = DMInbox.normalizedRelayURL(raw)
                if (url.isEmpty()) continue
                val k = key(url)
                if (k in pinnedKeys) continue
                if (k !in firstSpelling) {
                    firstSpelling[k] = url
                    order.add(k)
                }
                jobs.getOrPut(k) { mutableSetOf() }.add(job)
            }
        }
        return order.map { Row(firstSpelling.getValue(it), jobs[it].orEmpty()) }
    }

    /** Turns one job on or off for one relay. Off removes every spelling; on appends it once. */
    fun setting(job: Job, on: Boolean, url: String, lists: Lists): Lists {
        val k = key(url)
        val present = lists[job].any { key(it) == k }
        return when {
            on && present -> lists
            on -> lists.with(job, lists[job] + DMInbox.normalizedRelayURL(url))
            else -> lists.with(job, lists[job].filter { key(it) != k })
        }
    }

    /** Takes a relay out of every job. */
    fun removing(url: String, lists: Lists): Lists =
        Job.entries.fold(lists) { acc, job -> setting(job, false, url, acc) }

    /** A relay added from the + button starts with Read and Write. */
    fun adding(url: String, lists: Lists): Lists =
        listOf(Job.READ, Job.WRITE).fold(lists) { acc, job -> setting(job, true, url, acc) }

    /** What someone typed, as a relay URL, or null when it can't be one. */
    fun relayURL(typed: String): String? {
        var url = typed.trim()
        if (url.isEmpty() || url.contains(' ')) return null
        val lower = url.lowercase()
        if (!lower.startsWith("wss://") && !lower.startsWith("ws://")) {
            if (lower.contains("://")) return null
            url = "wss://$url"
        }
        url = DMInbox.normalizedRelayURL(url)
        val host = url.substringAfter("://").substringBefore('/').substringBefore(':')
        return if (host.isEmpty()) null else url
    }

    sealed class Problem(val title: String, val detail: String, val broken: Boolean = true) {
        data object NoRead : Problem("No Read relay", "Your feed falls back to ${labels(RelayConfiguration.FALLBACK_RELAYS)}.")
        data object NoWrite : Problem("No Write relay", "Your posts fall back to ${labels(RelayConfiguration.FALLBACK_WRITE_RELAYS)}.")
        data object NoDMs : Problem("No DM relay", "People can't message you.")
        data object OneDM : Problem("Only one DM relay", "If it goes down, nobody can message you. Add a second.", broken = false)
        data object NoSearch : Problem("No Search relay", "Search won't find anything.")
        data class Unreachable(val key: String) :
            Problem("${label(key)} isn't answering", "It didn't answer just now. Remove it if it stays down.")
    }

    /** Problems with the lists, worst first. [ownDMInbox] counts as a DM relay. */
    fun problems(lists: Lists, ownDMInbox: String, unreachable: List<String>): List<Problem> = buildList {
        fun nonEmpty(list: List<String>) = list.any { DMInbox.normalizedRelayURL(it).isNotEmpty() }
        if (!nonEmpty(lists.read)) add(Problem.NoRead)
        if (!nonEmpty(lists.write)) add(Problem.NoWrite)
        when (DMInbox.merged(ownDMInbox, lists.dms).size) {
            0 -> add(Problem.NoDMs)
            1 -> add(Problem.OneDM)
        }
        if (!nonEmpty(lists.search)) add(Problem.NoSearch)
        unreachable.forEach { add(Problem.Unreachable(it)) }
    }

    fun labels(urls: List<String>): String = urls.joinToString(", ") { label(it) }

    // Never connect

    /** Blocks [url]: out of every job, into [blocked] once. */
    fun blocking(url: String, lists: Lists, blocked: List<String>): Pair<Lists, List<String>> {
        val k = key(url)
        val newBlocked = if (blocked.any { key(it) == k }) blocked else blocked + DMInbox.normalizedRelayURL(url)
        return removing(url, lists) to newBlocked
    }

    fun unblocking(url: String, blocked: List<String>): List<String> {
        val k = key(url)
        return blocked.filter { key(it) != k }
    }

    // Recommended

    /** Well-known public relays, timed for "Fastest from this device". Same as iOS. */
    val wellKnownRelays = listOf(
        "wss://relay.damus.io",
        "wss://relay.primal.net",
        "wss://nos.lol",
        "wss://relay.snort.social",
        "wss://relay.btcforplebs.com",
        "wss://nostr.mom",
        "wss://nostr-pub.wellorder.net",
        "wss://offchain.pub",
        "wss://relay.nostr.bg",
        "wss://nostr.oxtr.dev",
        "wss://relay.nostr.net",
        "wss://nostr.bitcoiner.social",
    )

    data class FollowSuggestion(val url: String, val follows: Int)

    private fun taken(lists: Lists, blocked: List<String>, pinned: List<String>): Set<String> =
        (Job.entries.flatMap { lists[it] } + blocked + pinned).filter { it.isNotBlank() }.map(::key).toSet()

    /**
     * Relays the follows write to (their kind 10002 write relays), most used
     * first, leaving out relays already in a job, blocked ones and ones no
     * other client can reach. A relay needs [minimumFollows] follows.
     */
    fun followSuggestions(
        follows: List<String>,
        outbox: Map<String, List<String>>,
        lists: Lists,
        blocked: List<String>,
        pinned: List<String> = emptyList(),
        minimumFollows: Int = 2,
        limit: Int = 8,
    ): List<FollowSuggestion> {
        val taken = taken(lists, blocked, pinned)
        val counts = HashMap<String, Int>()
        val spelling = HashMap<String, String>()
        for (pubkey in follows.toSet()) {
            val seen = HashSet<String>()
            for (raw in outbox[pubkey].orEmpty()) {
                val url = DMInbox.normalizedRelayURL(raw)
                val k = key(url)
                if (!isPublicRelay(url) || k in taken || !seen.add(k)) continue
                counts[k] = (counts[k] ?: 0) + 1
                spelling.putIfAbsent(k, url)
            }
        }
        return counts.entries
            .filter { it.value >= minimumFollows }
            .sortedWith(compareByDescending<Map.Entry<String, Int>> { it.value }.thenBy { it.key })
            .take(limit)
            .map { FollowSuggestion(spelling.getValue(it.key), it.value) }
    }

    fun followsWithRelayLists(follows: List<String>, outbox: Map<String, List<String>>): Int =
        follows.toSet().count { outbox[it].orEmpty().isNotEmpty() }

    /** The fastest relays that answered, quickest first; [milliseconds] is keyed by [key]. */
    fun fastest(
        candidates: List<String>,
        milliseconds: Map<String, Int>,
        lists: Lists,
        blocked: List<String>,
        pinned: List<String> = emptyList(),
        limit: Int = 5,
    ): List<String> {
        val taken = taken(lists, blocked, pinned)
        return candidates
            .map(DMInbox::normalizedRelayURL)
            .filter { key(it) !in taken && milliseconds[key(it)] != null }
            .distinctBy(::key)
            .sortedWith(compareBy<String> { milliseconds.getValue(key(it)) }.thenBy { it })
            .take(limit)
    }

    /** A relay any client could reach: wss, a real host, not loopback, private or Tor. */
    fun isPublicRelay(url: String): Boolean {
        if (!url.lowercase().startsWith("wss://")) return false
        val host = url.substringAfter("://").substringBefore('/').substringBefore(':').lowercase()
        if (!host.contains('.') || host == "localhost" || host.endsWith(".onion") || host.endsWith(".local")) return false
        if (listOf("127.", "10.", "192.168.", "0.", "169.254.").any { host.startsWith(it) }) return false
        if (host.startsWith("172.") && host.split('.').getOrNull(1)?.toIntOrNull() in 16..31) return false
        return true
    }

    /** The host, for a compact label: "wss://relay.primal.net/" → "relay.primal.net". */
    fun label(url: String): String =
        DMInbox.normalizedRelayURL(url).replaceFirst(Regex("^wss?://", RegexOption.IGNORE_CASE), "")
}

/**
 * The owner's Never connect list, readable from any thread. [ConfigStore]
 * points [source] at its config; [com.nostrvault.data.remote.WebSocketClient]
 * and the search sockets refuse to connect to anything on it. A blocked relay
 * with no path blocks every path on that host and port. Relays that aren't
 * public (loopback, LAN, Tor) are never blocked: the app's own relay lives there.
 */
object RelayBlocklist {
    @Volatile
    var source: () -> List<String> = { emptyList() }

    fun isBlocked(url: String, blocked: List<String> = source()): Boolean {
        if (blocked.isEmpty()) return false
        val k = RelayMatrix.key(url)
        val authority = authorityOf(k)
        return blocked.any { entry ->
            val b = RelayMatrix.key(entry)
            RelayMatrix.isPublicRelay(b) && (b == k || (pathOf(b).isEmpty() && authorityOf(b) == authority))
        }
    }

    private fun authorityOf(key: String) = key.substringAfter("://").substringBefore('/')
    private fun pathOf(key: String) = key.substringAfter("://").substringAfter('/', "")
}
