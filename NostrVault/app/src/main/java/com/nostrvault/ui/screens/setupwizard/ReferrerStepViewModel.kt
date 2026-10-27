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
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import javax.inject.Inject

/**
 * Setup's "Who told you about Nostr Vault?" step: find the person from a
 * scanned QR code, a pasted npub or a `/p/` link, show their card, then up
 * to ten of the people they follow, most-followed first, all ticked.
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

    /** Up to ten of their follows, most-followed first; null while loading. */
    private val _suggestions = MutableStateFlow<List<String>?>(null)
    val suggestions: StateFlow<List<String>?> = _suggestions.asStateFlow()

    private val _ticked = MutableStateFlow<Set<String>>(emptySet())
    val ticked: StateFlow<Set<String>> = _ticked.asStateFlow()

    val profiles: StateFlow<Map<String, FeedProfile>> = nostrService.profiles

    private var load: Job? = null

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
            // How many of their first 150 follows' lists name each one. With
            // no answer, list order.
            val vouches = ReferrerFollows.vouches(follows, trustPathService.referralLists(follows))
            // An existing key already follows some of them: never offered again.
            val mine = ownHex?.let { trustPathService.followList(it) }.orEmpty()
            val picks = ReferrerFollows.suggestions(pk, follows, vouches, skip = setOfNotNull(ownHex) + mine)
            nostrService.fetchMissingProfiles(picks)
            _suggestions.value = picks
            _ticked.value = picks.toSet()
        }
    }

    /** "Follow <name>": on to the people they follow. */
    fun followReferrer() { _phase.value = Phase.SUGGEST }

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
        val ticked = _ticked.value
        ReferrerFollows.choose(pk, _suggestions.value.orEmpty().filter { it in ticked })
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
