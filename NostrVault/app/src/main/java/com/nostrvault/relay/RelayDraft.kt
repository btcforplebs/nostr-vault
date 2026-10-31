package com.nostrvault.relay

import com.nostrvault.relay.RelayMatrix.Job
import com.nostrvault.relay.RelayMatrix.Lists

/**
 * Settings > Relays as an unsaved draft (Logen 2026-10-31, option A).
 *
 * Nothing is written or published until Save. Rows come in two sections:
 * "Yours", the relays on the owner's published relay list (kind 10002) and
 * DM inbox (kind 10050) plus any added here, and "App defaults", everything
 * else the app put in the lists. Save publishes only the Yours rows; App
 * defaults stay on this device. Search and Import are never published.
 *
 * The row order is fixed when the screen opens: tapping dots, removing and
 * saving never move a row. Only an explicit add puts a row at the end of Yours.
 */
object RelayDraft {

    enum class Section { YOURS, DEFAULTS }

    data class Entry(val key: String, val url: String, val section: Section)

    /**
     * The owner's published lists. [relayListKnown] / [dmListKnown] are false
     * when the relays didn't settle whether one exists: publishing then could
     * replace a list set in another app, so Save keeps the change on this device.
     */
    data class Published(
        val read: List<String> = emptyList(),
        val write: List<String> = emptyList(),
        val dms: List<String> = emptyList(),
        val relayListKnown: Boolean = false,
        val dmListKnown: Boolean = false,
        /**
         * Published kind 10002 tags this screen can't show or edit (ws://,
         * home network, .local, CGNAT, .ts.net). Save carries them through as
         * published, so editing one relay never drops another app's entries
         * (Tron, #1386; iOS `Published.kept`).
         */
        val kept: List<List<String>> = emptyList(),
    )

    /** Whether a relay can be a row of the published relay list: a wss:// address others can reach. */
    fun listable(url: String): Boolean = PublicRelayList.tags(listOf(url), emptyList(), emptyList()).isNotEmpty()

    /** The relays that index every account's lists; a "none" counts only when both answered. */
    val INDEXERS = listOf("wss://purplepag.es", "wss://user.kindpag.es")

    /**
     * Whether a lookup settled the list: every one of the [INDEXERS]
     * answered, found or not. Any other relay answering proves little: most
     * of them are this device's own defaults, a list made in another app may
     * never have reached them (Tron, PR 1378), and one of them may hold an
     * older copy that re-signing would bring back (Tron, #1386). Requiring
     * every relay instead made a new account's empty list "unknown" whenever
     * one relay was rate-limiting. [found] is kept for the iOS twin's shape.
     */
    @Suppress("UNUSED_PARAMETER")
    fun settled(found: Boolean, answeredBy: Collection<String>): Boolean {
        val answered = answeredBy.map(RelayMatrix::key).toSet()
        return INDEXERS.all { RelayMatrix.key(it) in answered }
    }

    data class State(
        /** The lists when the screen opened, or at the last Save. */
        val start: Lists,
        val draft: Lists,
        val layout: List<Entry>,
        /** Removed rows (by key), with the jobs each had, for Undo. */
        val removed: Map<String, Set<Job>>,
        val published: Published,
        /** App defaults added by hand since the last Save: now Yours. */
        val moved: Set<String> = emptySet(),
    ) {
        val yours: Set<String> get() = layout.filter { it.section == Section.YOURS }.map { it.key }.toSet()
    }

    data class Row(val entry: Entry, val jobs: Set<Job>, val removed: Boolean) {
        fun has(job: Job) = job in jobs
    }

    /**
     * The draft for [lists] (this device's config). The published relays
     * join their jobs, so the screen shows the owner's real lists. [pinned]
     * (the vault's own relay and inbox) has its own row and is left out.
     */
    fun start(lists: Lists, published: Published, pinned: List<String> = emptyList()): State {
        val pinnedKeys = pinned.filter { it.isNotBlank() }.map(RelayMatrix::key).toSet()
        fun join(job: Job, urls: List<String>, into: Lists) = urls
            .filter { DMInbox.normalizedRelayURL(it).isNotEmpty() && RelayMatrix.key(it) !in pinnedKeys }
            .fold(into) { acc, url -> RelayMatrix.setting(job, true, url, acc) }
        val joined = join(Job.DMS, published.dms, join(Job.WRITE, published.write, join(Job.READ, published.read, lists)))
        val theirs = (published.read + published.write + published.dms).map(RelayMatrix::key).toSet()
        // On his relays, Read, Write and DMs are what he published: a default
        // job the app also gave one of them would otherwise go out with his
        // list at the next Save.
        val publishedJobs = mapOf(Job.READ to published.read, Job.WRITE to published.write, Job.DMS to published.dms)
            .mapValues { (_, urls) -> urls.map(RelayMatrix::key).toSet() }
        val draft = RelayMatrix.rows(joined, pinned).filter { it.id in theirs }.fold(joined) { acc, row ->
            publishedJobs.entries.fold(acc) { inner, (job, keys) -> RelayMatrix.setting(job, row.id in keys, row.url, inner) }
        }
        val rows = RelayMatrix.rows(draft, pinned)
        val layout = rows.filter { it.id in theirs }.map { Entry(it.id, it.url, Section.YOURS) } +
            rows.filter { it.id !in theirs }.map { Entry(it.id, it.url, Section.DEFAULTS) }
        return State(start = draft, draft = draft, layout = layout, removed = emptyMap(), published = published)
    }

    fun rows(state: State): List<Row> = state.layout.map { entry ->
        val removed = state.removed[entry.key]
        Row(entry, removed ?: jobs(state.draft, entry.key), removed != null)
    }

    fun jobs(lists: Lists, key: String): Set<Job> =
        Job.entries.filter { job -> lists[job].any { RelayMatrix.key(it) == key } }.toSet()

    /** Turns one job on or off. A removed row ignores taps until Undo. */
    fun toggle(state: State, key: String, job: Job): State {
        val entry = state.layout.firstOrNull { it.key == key } ?: return state
        if (key in state.removed) return state
        val on = job !in jobs(state.draft, key)
        return state.copy(draft = RelayMatrix.setting(job, on, entry.url, state.draft))
    }

    fun remove(state: State, key: String): State {
        val entry = state.layout.firstOrNull { it.key == key } ?: return state
        if (key in state.removed) return state
        return state.copy(
            draft = RelayMatrix.removing(entry.url, state.draft),
            removed = state.removed + (key to jobs(state.draft, key)),
        )
    }

    fun undo(state: State, key: String): State {
        val entry = state.layout.firstOrNull { it.key == key } ?: return state
        val jobs = state.removed[key] ?: return state
        val draft = jobs.fold(state.draft) { acc, job -> RelayMatrix.setting(job, true, entry.url, acc) }
        return state.copy(draft = draft, removed = state.removed - key)
    }

    /**
     * Adds [url] with [jobs]: a new row at the end of Yours. A relay already
     * listed keeps its row and gets the jobs; an App default someone adds by
     * hand becomes theirs and moves to the end of Yours.
     */
    fun add(state: State, url: String, jobs: Set<Job>): State {
        val k = RelayMatrix.key(url)
        if (k.isEmpty()) return state
        val s = if (k in state.removed) undo(state, k) else state
        val existing = s.layout.firstOrNull { it.key == k }
        val spelling = existing?.url ?: DMInbox.normalizedRelayURL(url)
        val layout = when {
            existing == null -> s.layout + Entry(k, spelling, Section.YOURS)
            existing.section == Section.DEFAULTS -> s.layout.filter { it.key != k } + existing.copy(section = Section.YOURS)
            else -> s.layout
        }
        val draft = jobs.fold(s.draft) { acc, job -> RelayMatrix.setting(job, true, spelling, acc) }
        val moved = if (existing?.section == Section.DEFAULTS) s.moved + k else s.moved
        return s.copy(layout = layout, draft = draft, moved = moved)
    }

    /**
     * Sets one job for a relay that may have no row of its own (the vault's
     * relay, pinned at the top). A change shows up as kept on this device.
     */
    fun setJob(state: State, url: String, job: Job, on: Boolean): State =
        state.copy(draft = RelayMatrix.setting(job, on, url, state.draft))

    /**
     * Search goes back to the app's [defaults]. Relays that had no row get
     * one at the end of App defaults, so nothing already shown moves.
     */
    fun resetSearch(state: State, defaults: List<String>, pinned: List<String> = emptyList()): State {
        val draft = state.draft.copy(search = defaults)
        val known = state.layout.map { it.key }.toSet() + pinned.filter { it.isNotBlank() }.map(RelayMatrix::key)
        val added = RelayMatrix.rows(draft).filter { it.id !in known }.map { Entry(it.id, it.url, Section.DEFAULTS) }
        return state.copy(draft = draft, layout = state.layout + added)
    }

    /** Every relay in the start or the draft, first spelling kept: rows and pinned ones alike. */
    private fun allRelays(state: State): List<Pair<String, String>> {
        val seen = LinkedHashMap<String, String>()
        state.layout.forEach { seen.putIfAbsent(it.key, it.url) }
        for (lists in listOf(state.start, state.draft)) for (job in Job.entries) for (url in lists[job]) {
            val k = RelayMatrix.key(url)
            if (k.isNotEmpty()) seen.putIfAbsent(k, DMInbox.normalizedRelayURL(url))
        }
        return seen.entries.map { it.key to it.value }
    }

    /** Relays whose jobs differ from [State.start], counting a default made Yours as a change. */
    fun changeCount(state: State): Int = allRelays(state).count { (k, _) ->
        jobs(state.draft, k) != jobs(state.start, k) || k in state.moved
    }

    private fun movedToYours(state: State, entry: Entry): Boolean = entry.key in state.moved

    // ── Save ──────────────────────────────────────────────────────

    /** One line of the confirm sheet: a relay and the jobs it gains or loses. */
    data class Change(val url: String, val added: Set<Job>, val removed: Set<Job>)

    data class Plan(
        /** Kind 10002 tags to publish, or null when it isn't published. */
        val relayListTags: List<List<String>>?,
        val relayListChanges: List<Change>,
        /** The kind 10050 relays to publish, or null when it isn't published. */
        val dmRelays: List<String>?,
        val dmChanges: List<Change>,
        /** Changes kept on this device: App defaults, Search and Import. */
        val localChanges: List<Change>,
        /** A Yours change that can't be published because the list wasn't loaded. */
        val relayListHeld: Boolean,
        val dmListHeld: Boolean,
    )

    private fun yoursOnly(list: List<String>, yours: Set<String>) = list.filter { RelayMatrix.key(it) in yours }

    /**
     * What Save does. Kind 10002 goes out only when a Yours row's Read or
     * Write changed, kind 10050 only when a Yours row's DMs changed, and each
     * holds the Yours rows alone ([ownRelay] and [ownInbox] lead, as before).
     */
    fun plan(state: State, ownRelay: String, ownInbox: String): Plan {
        val yours = state.yours
        val draft = state.draft
        val start = state.start
        val p = state.published

        val readNow = yoursOnly(draft.read, yours)
        val writeNow = yoursOnly(draft.write, yours)
        val relayListEdited = keys(readNow) != keys(yoursOnly(start.read, yours)) ||
            keys(writeNow) != keys(yoursOnly(start.write, yours)) || movedAny(state, setOf(Job.READ, Job.WRITE))
        val shown = PublicRelayList.tags(listOf(ownRelay), readNow, writeNow)
        val shownKeys = shown.map { RelayMatrix.key(it[1]) }.toSet()
        // The published entries the screen can't show go out again untouched.
        val newTags = shown + p.kept.filter { RelayMatrix.key(it[1]) !in shownKeys }
        val relayListChanges = if (relayListEdited) diff(
            before = PublicRelayList.tags(emptyList(), p.read, p.write) + p.kept, after = newTags,
        ) else emptyList()
        val publishRelayList = relayListEdited && p.relayListKnown && relayListChanges.isNotEmpty()

        val dmsNow = yoursOnly(draft.dms, yours)
        val dmEdited = keys(dmsNow) != keys(yoursOnly(start.dms, yours)) || movedAny(state, setOf(Job.DMS))
        val newDMs = DMInbox.merged(ownInbox, dmsNow)
        val dmChanges = if (dmEdited) setDiff(p.dms, newDMs, Job.DMS) else emptyList()
        val publishDMs = dmEdited && p.dmListKnown && dmChanges.isNotEmpty()

        val localChanges = allRelays(state).mapNotNull { (k, url) ->
            val before = jobs(start, k)
            val after = jobs(draft, k)
            val local = if (k in yours) setOf(Job.SEARCH, Job.IMPORT) else Job.entries.toSet()
            val added = (after - before).intersect(local)
            val removed = (before - after).intersect(local)
            if (added.isEmpty() && removed.isEmpty()) null else Change(url, added, removed)
        }

        return Plan(
            relayListTags = if (publishRelayList) newTags else null,
            relayListChanges = relayListChanges,
            dmRelays = if (publishDMs) newDMs else null,
            dmChanges = dmChanges,
            localChanges = localChanges,
            relayListHeld = relayListEdited && !p.relayListKnown,
            dmListHeld = dmEdited && !p.dmListKnown,
        )
    }

    /**
     * True when Save must not sign: the screen opened with a published list
     * ([openedWithList]) but the lookup at Save found no copy at all. The
     * indexers can answer "none" for a list that only lives on the owner's
     * own relays; rebasing onto nothing would publish only the rows the
     * screen added and drop the rest (Tron, #1458).
     */
    fun vanishedAtSave(openedWithList: Boolean, foundAtSave: Boolean): Boolean = openedWithList && !foundAtSave

    /**
     * Save edits the newest kind 10002, fetched right before it is signed,
     * not the copy read when Relays opened (Logen 2026-10-31). The screen's
     * edit is what changed from [before] (the list as published at open) to
     * [after] (what Save would publish), per relay and per Read / Write; it
     * is applied to [newest]. A relay another app added or changed since is
     * kept; every tag that is not an `r` tag stays as published.
     */
    fun rebaseRelayList(before: List<List<String>>, after: List<List<String>>, newest: List<List<String>>): List<List<String>> {
        fun pairs(tags: List<List<String>>) = tags.filter { it.size >= 2 && it[0] == "r" }.flatMap { t ->
            val k = RelayMatrix.key(t[1])
            when (t.getOrNull(2)) {
                "read" -> listOf(k to Job.READ)
                "write" -> listOf(k to Job.WRITE)
                else -> listOf(k to Job.READ, k to Job.WRITE)
            }
        }.toSet()
        val was = pairs(before)
        val now = pairs(after)
        val result = pairs(newest) - (was - now) + (now - was)
        val urls = LinkedHashMap<String, String>()
        for (t in newest + after) if (t.size >= 2 && t[0] == "r") urls.putIfAbsent(RelayMatrix.key(t[1]), t[1])
        val rTags = urls.mapNotNull { (k, url) ->
            val read = (k to Job.READ) in result
            val write = (k to Job.WRITE) in result
            when {
                read && write -> listOf("r", url)
                read -> listOf("r", url, "read")
                write -> listOf("r", url, "write")
                else -> null
            }
        }
        return rTags + newest.filter { it.isNotEmpty() && it[0] != "r" }
    }

    /**
     * [rebaseRelayList] for the DM inbox (kind 10050): the relays added and
     * removed between [before] and [after], applied to the [newest] tags.
     */
    fun rebaseDMList(before: List<String>, after: List<String>, newest: List<List<String>>): List<List<String>> {
        val was = before.map(RelayMatrix::key).toSet()
        val now = after.map(RelayMatrix::key).toSet()
        return com.nostrvault.service.ListMerge.edit(
            "relay", newest,
            add = after.filter { RelayMatrix.key(it) !in was },
            remove = before.filter { RelayMatrix.key(it) !in now },
        )
    }

    private fun movedAny(state: State, jobs: Set<Job>): Boolean = state.layout.any { entry ->
        movedToYours(state, entry) && jobs(state.draft, entry.key).any { it in jobs }
    }

    /**
     * After Save: the saved lists become the start, removed rows leave, and
     * every other row keeps its place, including defaults now published.
     */
    fun saved(state: State, plan: Plan): State {
        val published = state.published.let { p ->
            var next = p
            if (plan.relayListTags != null) {
                val rows = plan.relayListTags.filter { listable(it[1]) }
                next = next.copy(
                    read = rows.filter { it.size == 2 || it.getOrNull(2) == "read" }.map { it[1] },
                    write = rows.filter { it.size == 2 || it.getOrNull(2) == "write" }.map { it[1] },
                )
            }
            if (plan.dmRelays != null) next = next.copy(dms = plan.dmRelays)
            next
        }
        return state.copy(
            start = state.draft,
            layout = state.layout.filter { it.key !in state.removed },
            removed = emptyMap(),
            published = published,
            moved = emptySet(),
        )
    }

    private fun keys(list: List<String>) = list.map(RelayMatrix::key).toSet()

    /** Read/Write per relay between two kind 10002 tag lists. */
    private fun diff(before: List<List<String>>, after: List<List<String>>): List<Change> {
        fun jobsOf(tags: List<List<String>>): LinkedHashMap<String, Pair<String, Set<Job>>> {
            val out = LinkedHashMap<String, Pair<String, Set<Job>>>()
            for (tag in tags) {
                if (tag.size < 2 || tag[0] != "r") continue
                val jobs = when (tag.getOrNull(2)) {
                    "read" -> setOf(Job.READ)
                    "write" -> setOf(Job.WRITE)
                    else -> setOf(Job.READ, Job.WRITE)
                }
                val k = RelayMatrix.key(tag[1])
                out[k] = (out[k]?.first ?: tag[1]) to (out[k]?.second.orEmpty() + jobs)
            }
            return out
        }
        val b = jobsOf(before)
        val a = jobsOf(after)
        return (a.keys + b.keys).mapNotNull { k ->
            val was = b[k]?.second.orEmpty()
            val now = a[k]?.second.orEmpty()
            if (was == now) null else Change((a[k] ?: b[k])!!.first, now - was, was - now)
        }
    }

    private fun setDiff(before: List<String>, after: List<String>, job: Job): List<Change> {
        val b = keys(before)
        val a = keys(after)
        return after.filter { RelayMatrix.key(it) !in b }.map { Change(it, setOf(job), emptySet()) } +
            before.filter { RelayMatrix.key(it) !in a }.map { Change(it, emptySet(), setOf(job)) }
    }
}
