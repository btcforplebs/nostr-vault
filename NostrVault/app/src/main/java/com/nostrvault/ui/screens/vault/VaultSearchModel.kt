package com.nostrvault.ui.screens.vault

import com.nostrvault.data.model.FeedNote
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.data.model.SearchTermMatcher
import com.nostrvault.data.model.VaultSearchLogic
import com.nostrvault.data.model.VaultSearchLogic.Status
import com.nostrvault.relay.RelayForegroundService
import com.nostrvault.service.FeedFilterEngine
import com.nostrvault.service.FeedService
import com.nostrvault.service.GlobalSearchSession
import com.nostrvault.service.NostrService
import com.nostrvault.service.mergeSearchProfiles
import com.nostrvault.service.ownSearchPubkeys
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Runs the Vault's search against the local relay (iOS `VaultSearchModel`): the
 * phone relay walk the Search tab's Relay mode used ([GlobalSearchSession]),
 * widened to the kinds the Vault holds, its matches turned into the result
 * sections. Lives on [scope]'s main thread; the walk runs on its own IO
 * sockets and the sorting into sections on [Dispatchers.Default].
 */
internal class VaultSearchModel(
    private val scope: CoroutineScope,
    private val nostrService: NostrService,
    private val feedService: FeedService,
) {
    data class Results(
        val people: List<FeedProfile> = emptyList(),
        val notes: List<FeedNote> = emptyList(),
        val hashtags: List<String> = emptyList(),
        val links: List<VaultSearchLogic.Link> = emptyList(),
    ) {
        fun notes(section: VaultSearchLogic.Section): List<FeedNote> =
            notes.filter { VaultSearchLogic.section(it.kind) == section }

        fun count(section: VaultSearchLogic.Section): Int = when (section) {
            VaultSearchLogic.Section.PEOPLE -> people.size
            VaultSearchLogic.Section.HASHTAGS -> hashtags.size
            VaultSearchLogic.Section.LINKS -> links.size
            else -> notes(section).size
        }

        val isEmpty: Boolean get() = people.isEmpty() && notes.isEmpty() && hashtags.isEmpty() && links.isEmpty()
    }

    private val state = VaultSearchLogic.QueryState()
    private val _results = MutableStateFlow(Results())
    val results: StateFlow<Results> = _results.asStateFlow()
    private val _status = MutableStateFlow(Status.IDLE)
    val status: StateFlow<Status> = _status.asStateFlow()
    /** The query the results are for. */
    private val _resultsQuery = MutableStateFlow("")
    val resultsQuery: StateFlow<String> = _resultsQuery.asStateFlow()

    private var pending: Job? = null
    private var session: GlobalSearchSession? = null

    private fun publishState() {
        _status.value = state.status
        _resultsQuery.value = state.resultsQuery
    }

    /**
     * Searches [query] after a short pause, so typing does not start a walk of
     * the whole store per keystroke. [now] skips the pause (the keyboard's Search).
     */
    fun search(query: String, now: Boolean = false) {
        pending?.cancel()
        pending = null
        when (val next = state.typed(query)) {
            VaultSearchLogic.QueryState.Next.Clear -> {
                stopWalk()
                _results.value = Results()
            }
            // Whatever is still walking is for a query the field has left.
            VaultSearchLogic.QueryState.Next.Keep -> stopWalk()
            is VaultSearchLogic.QueryState.Next.Run -> pending = scope.launch {
                if (!now) delay(DEBOUNCE_MS)
                run(next.query)
            }
        }
        publishState()
    }

    fun cancel() {
        pending?.cancel()
        pending = null
        stopWalk()
        _results.value = Results()
        state.reset()
        publishState()
    }

    private fun stopWalk() {
        session?.cancel()
        session = null
    }

    private suspend fun run(query: String) {
        if (!state.started(query)) return
        publishState()
        stopWalk()
        val config = nostrService.configStore.config.value
        val relayUp = RelayForegroundService.relayStatus.value == RelayForegroundService.RelayStatus.RUNNING
        val base = config.nostrURL
        if (!relayUp || base == null) {
            // The relay is still starting: search what the app has loaded rather than show nothing.
            runInMemory(query)
            return
        }
        val matcher = SearchTermMatcher.create(query) ?: return
        val walk = GlobalSearchSession(
            query = query,
            matcher = matcher,
            plan = GlobalSearchSession.Plan(phoneRelayUrl = base, macRelayUrl = null, searchRelays = emptyList()),
            own = nostrService.ownSearchPubkeys(),
            follows = feedService.followedPubkeys.value.toSet(),
            cachedProfiles = nostrService.profiles.value.values.toList(),
            noteKinds = VaultSearchLogic.NOTE_KINDS,
        )
        session = walk
        walk.start()
        // Show what has matched so far while the walk goes on, then the end.
        walk.state.first { searchState ->
            if (session !== walk) return@first true
            val result = if (searchState.isRunning) Status.SEARCHING else if (walk.timedOut) Status.CUT_SHORT else Status.DONE
            if (searchState.isRunning && searchState.results.profiles.isEmpty() && searchState.results.notes.isEmpty()) {
                return@first false
            }
            land(query, searchState.results.profiles, searchState.results.notes, result)
            !searchState.isRunning
        }
        if (session === walk) {
            nostrService.mergeSearchProfiles(walk.finishedResults?.profiles.orEmpty())
            session = null
        }
    }

    /** The relay-down fallback: the same matching over the profiles, Vault events and feed notes already in memory. */
    private suspend fun runInMemory(query: String) {
        val matcher = SearchTermMatcher.create(query) ?: return
        val profiles = nostrService.profiles.value.values.toList()
        val events = nostrService.events
        val feedNotes = feedService.notes.value
        val (people, notes) = withContext(Dispatchers.Default) {
            val kinds = VaultSearchLogic.NOTE_KINDS.toHashSet()
            val people = profiles.filter(matcher::matchesProfile)
            val seen = HashSet<String>()
            val notes = ArrayList<FeedNote>()
            for (event in events) {
                if (event.kind in kinds && matcher.matchesNote(event.content, event.tags) && seen.add(event.id)) {
                    notes += FeedNote.fromEvent(event.id, event.pubkey, event.content, event.tags, event.createdAt, event.kind)
                }
            }
            for (note in feedNotes) {
                if (note.kind in kinds && matcher.matchesNote(note.content, note.tags) && seen.add(note.id)) notes += note
            }
            people to notes
        }
        land(query, people, notes, Status.IN_MEMORY)
    }

    /** Sorts what was found into sections, off the main thread, and shows it if the field still holds [query]. */
    private suspend fun land(query: String, profiles: List<FeedProfile>, found: List<FeedNote>, result: Status) {
        val cached = nostrService.profiles.value
        val blocked = feedService.blockedHexForActiveAccount()
        val follows = feedService.followedPubkeys.value.toHashSet()
        val sections = withContext(Dispatchers.Default) {
            sectionsFor(query, profiles, found, cached, blocked, follows,
                decodeNpub = nostrService::npubToHex, authorOf = { feedService.findNote(it)?.pubkey })
        }
        if (result == Status.SEARCHING) {
            // Matches so far, while the walk is still going: the status stays as it is.
            if (query == state.live) _results.value = sections
            return
        }
        if (!state.landed(query, result)) return
        _results.value = sections
        publishState()
    }

    companion object {
        const val DEBOUNCE_MS = 300L

        /**
         * The sections for [query]: the people the query is about (a pasted npub
         * finds its person even with no profile stored), blocked people and their
         * notes taken out, people you follow first, notes newest first, and the
         * hashtags and links those notes carry.
         */
        fun sectionsFor(
            query: String,
            profiles: List<FeedProfile>,
            found: List<FeedNote>,
            cached: Map<String, FeedProfile>,
            blocked: Set<String>,
            follows: Set<String>,
            decodeNpub: (String) -> String?,
            authorOf: (String) -> String? = { null },
        ): Results {
            var people = profiles.filter {
                VaultSearchLogic.keepsPerson(it.pubkey, listOf(it.displayName, it.name, it.about, it.nip05), query, decodeNpub)
            }
            if (people.isEmpty()) {
                VaultSearchLogic.keyOnlyPerson(query, decodeNpub) { it in cached }?.let { key ->
                    people = listOf(cached[key] ?: FeedProfile(pubkey = key))
                }
            }
            people = people.filter { it.pubkey !in blocked }
                .sortedWith(compareBy<FeedProfile> { it.pubkey !in follows }.thenBy(String.CASE_INSENSITIVE_ORDER) { it.bestName })
            val kinds = VaultSearchLogic.NOTE_KINDS.toHashSet()
            val notes = found
                .filter { it.kind in kinds && !FeedFilterEngine.involvesBlocked(it, blocked, authorOf) }
                .sortedByDescending { it.createdAt.time }
            return Results(
                people = people,
                notes = notes,
                hashtags = VaultSearchLogic.hashtags(notes.map { it.content to it.tags }, query),
                links = VaultSearchLogic.links(notes.map { it.id to it.content }),
            )
        }
    }
}
