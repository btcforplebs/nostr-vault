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
            val columns = listOf(READ, WRITE, DMS)
            val advanced = listOf(SEARCH, IMPORT)
        }
    }

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
        data object NoRead : Problem("No Read relay", "Your feed falls back to the default relays.")
        data object NoWrite : Problem("No Write relay", "Your posts go to the default relays.")
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

    /** The host, for a compact label: "wss://relay.primal.net/" → "relay.primal.net". */
    fun label(url: String): String =
        DMInbox.normalizedRelayURL(url).replaceFirst(Regex("^wss?://", RegexOption.IGNORE_CASE), "")
}
