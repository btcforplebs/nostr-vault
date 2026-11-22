package com.nostrvault.ui.screens

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.service.NostrService
import com.nostrvault.service.TrustPathService
import com.nostrvault.setup.ReferrerFollows
import com.nostrvault.ui.navigation.BridgeEntityDecoder
import com.nostrvault.ui.navigation.ProfileWebLink
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import javax.inject.Inject

/**
 * Setup's "Who told you about Nostr Vault?" step: find the person from a
 * scanned QR code, a pasted npub or a `/p/` link, show their card, then
 * "<Name>'s people": their follows and followers, the people they interact
 * with most first ([ReferrerFollows.rank]), in a scrolling list with topic
 * chips that filter it (setup screens r3, iOS #2414). None start ticked: a
 * row's Follow, or its preview's, picks someone (Logen 2026-11-22).
 * Nothing is signed here; [finish] leaves the picks in [ReferrerFollows] for
 * the end of setup.
 */
@HiltViewModel
class ReferrerStepViewModel @Inject constructor(
    private val nostrService: NostrService,
    private val trustPathService: TrustPathService,
) : ViewModel() {

    enum class Phase { ENTER, FOUND, SUGGEST }

    private val _phase = MutableStateFlow(Phase.ENTER)
    val phase: StateFlow<Phase> = _phase.asStateFlow()

    private val _input = MutableStateFlow(ReferrerFollows.prefill.orEmpty())
    val input: StateFlow<String> = _input.asStateFlow()

    private val _error = MutableStateFlow<String?>(null)
    val error: StateFlow<String?> = _error.asStateFlow()

    /** The referrer's hex pubkey once found. */
    private val _referrer = MutableStateFlow<String?>(null)
    val referrer: StateFlow<String?> = _referrer.asStateFlow()

    /** Up to [ReferrerFollows.POOL] of their follows, closest first; null while loading. */
    private val _suggestions = MutableStateFlow<List<ReferrerFollows.Pick>?>(null)
    val suggestions: StateFlow<List<ReferrerFollows.Pick>?> = _suggestions.asStateFlow()

    /** Hashtags the people offered share; empty when none do. */
    private val _topics = MutableStateFlow<List<ReferrerFollows.Topic>>(emptyList())
    val topics: StateFlow<List<ReferrerFollows.Topic>> = _topics.asStateFlow()

    /** The topic chip picked; null shows the top ones. */
    private val _topic = MutableStateFlow<String?>(null)
    val topic: StateFlow<String?> = _topic.asStateFlow()

    private val _ticked = MutableStateFlow<Set<String>>(emptySet())
    val ticked: StateFlow<Set<String>> = _ticked.asStateFlow()

    val profiles: StateFlow<Map<String, FeedProfile>> = nostrService.profiles

    private var load: Job? = null

    /** The person whose preview is open; null when none. */
    private val _preview = MutableStateFlow<String?>(null)
    val preview: StateFlow<String?> = _preview.asStateFlow()

    fun openPreview(pubkey: String) { _preview.value = pubkey }
    fun closePreview() { _preview.value = null }

    init {
        // Opened from someone's link before setup: start on their card.
        if (_input.value.isNotBlank()) find(ownHex = null)
    }

    fun setInput(value: String) { _input.value = value; _error.value = null }

    /** Looks up whoever [input] names. [ownHex] is the account being set up. */
    fun find(ownHex: String?) {
        val pk = ProfileWebLink.pubkeyFrom(_input.value, BridgeEntityDecoder)
        if (pk == null) { _error.value = "That isn't a Nostr Vault link or an npub."; return }
        if (pk == ownHex) { _error.value = "That's you. Who told you about Nostr Vault?"; return }
        ReferrerFollows.prefill = null
        _referrer.value = pk
        _suggestions.value = null
        _topics.value = emptyList()
        _topic.value = null
        _ticked.value = emptySet()
        _phase.value = Phase.FOUND
        nostrService.fetchMissingProfiles(listOf(pk))
        load?.cancel()
        load = viewModelScope.launch {
            // Twice more on no answer: a link opened before setup starts this
            // as the app launches, while the network may still be coming up.
            var list: List<String>? = null
            for (attempt in 0 until 3) {
                list = trustPathService.followList(pk)
                if (list != null) break
                kotlinx.coroutines.delay(2_000)
            }
            val follows = list.orEmpty()
            // At once: who they interact with most (both ways), who follows
            // them, and their first 150 follows' lists (who of their close
            // circle, and of all of them, follow each one). With no answer,
            // follows in list order, then followers.
            val talks = async { trustPathService.referralTalks(pk) }
            val followers = async { trustPathService.referralFollowers(pk) }
            val lists = async { trustPathService.referralLists(follows) }
            // An existing key already follows some of them: never offered again.
            val mine = ownHex?.let { trustPathService.followList(it) }.orEmpty()
            val picks = ReferrerFollows.rank(
                pk, follows, lists.await(),
                skip = setOfNotNull(ownHex) + mine,
                talks = talks.await(),
                followers = followers.await(),
            )
            val keys = picks.map { it.pubkey }
            nostrService.fetchMissingProfiles(keys)
            _suggestions.value = picks
            _ticked.value = keys.take(ReferrerFollows.PRE_TICKED).toSet()
            // The chips come after the list is up: a slow relay only delays them.
            _topics.value = ReferrerFollows.topics(trustPathService.referralTopicTags(keys), keys)
        }
    }

    /** "Follow <name>": on to the people they follow. */
    fun followReferrer() { _phase.value = Phase.SUGGEST }

    /** A topic chip: shows only who used it; the same one again, or null, shows the top ones. */
    fun pickTopic(topic: String?) {
        _topic.value = if (topic == _topic.value) null else topic
    }

    /** The people listed: the whole pool, or everyone in it who used the picked topic. */
    fun shown(picks: List<ReferrerFollows.Pick>, topics: List<ReferrerFollows.Topic>, topic: String?): List<ReferrerFollows.Pick> {
        val people = topic?.let { t -> topics.firstOrNull { it.topic == t }?.people }
            ?: return picks
        return picks.filter { it.pubkey in people }
    }

    /** Ticked, in rank order, whether or not a topic hides them now. */
    fun tickedInOrder(): List<String> {
        val ticked = _ticked.value
        return _suggestions.value.orEmpty().map { it.pubkey }.filter { it in ticked }
    }

    fun toggle(pubkey: String) {
        _ticked.value = _ticked.value.let { if (pubkey in it) it - pubkey else it + pubkey }
    }

    /** Back to the field, to pick someone else. */
    fun change() {
        load?.cancel()
        _referrer.value = null
        _phase.value = Phase.ENTER
    }

    /** Keeps the referrer and the ticked suggestions, in the order shown, for the end of setup. */
    fun finish() {
        val pk = _referrer.value ?: return ReferrerFollows.clear()
        ReferrerFollows.choose(pk, tickedInOrder())
    }

    /** Following them and none of their follows. */
    fun finishReferrerOnly() {
        _referrer.value?.let { ReferrerFollows.choose(it, emptyList()) } ?: ReferrerFollows.clear()
    }

    fun skip() {
        load?.cancel()
        ReferrerFollows.clear()
    }
}
