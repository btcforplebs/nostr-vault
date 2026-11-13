package com.nostrvault.ui.screens.emoji

import android.net.Uri
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.nostrvault.fips.FileNotesLive
import com.nostrvault.relay.HavenBridge
import com.nostrvault.service.EmojiListRepository
import com.nostrvault.service.NostrService
import com.nostrvault.service.emoji.EmojiListSave
import com.nostrvault.service.emoji.EmojiSetBrowser
import com.nostrvault.service.emoji.EmojiVaultPage
import com.nostrvault.service.emoji.EmojiVaultStore
import com.nostrvault.service.emoji.OwnEmojiSetFinder
import com.nostrvault.service.emoji.OwnEmojiSets
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import javax.inject.Inject

/** The Vault tab's Emoji page (custom emoji plan §4.3): sets, their saved copies, Save copies, zip import, browse. */
@HiltViewModel
class EmojiVaultViewModel @Inject constructor(
    private val emojiList: EmojiListRepository,
    private val store: EmojiVaultStore,
    private val listSave: EmojiListSave,
    private val browser: EmojiSetBrowser,
    private val nostrService: NostrService,
    private val ownSets: OwnEmojiSetFinder,
    fileNotesLive: FileNotesLive,
) : ViewModel() {
    val progress = store.progress
    val dead = store.dead
    val profiles = nostrService.profiles

    /** One block per set: the 10030's sets in its order, then sets only the saved copies still name. */
    val sets: StateFlow<List<EmojiVaultPage.SetBlock>> =
        combine(emojiList.library, store.saved, store.notes, store.dead) { library, saved, notes, dead ->
            EmojiVaultPage.blocks(library.sets, saved.values.toList(), notes, dead.map { it.url }.toSet())
        }.stateIn(viewModelScope, SharingStarted.Eagerly, emptyList())

    /** The sets in the 10030 now (Add or Remove). */
    val listed: StateFlow<Set<String>> = emojiList.library.map { l -> l.sets.map { it.address }.toSet() }
        .stateIn(viewModelScope, SharingStarted.Eagerly, emptySet())

    private val _message = MutableStateFlow<String?>(null)
    val message: StateFlow<String?> = _message.asStateFlow()

    private val _browse = MutableStateFlow<BrowseState>(BrowseState())
    val browse: StateFlow<BrowseState> = _browse.asStateFlow()

    data class BrowseState(val loading: Boolean = false, val found: List<EmojiSetBrowser.Found> = emptyList(), val note: String? = null)

    /** Your old sets in Find emoji sets: own sets not in the 10030, or wiped (Logen 2026-11-13). */
    data class OldSetsState(val loading: Boolean = false, val found: OwnEmojiSetFinder.Found? = null, val busy: String? = null)

    private val _oldSets = MutableStateFlow(OldSetsState())
    val oldSets: StateFlow<OldSetsState> = _oldSets.asStateFlow()

    init {
        emojiList.refresh(wide = true)
        viewModelScope.launch { fileNotesLive.events { null }.collect(store::onFileNote) }
    }

    fun refresh() = emojiList.refresh(force = true, wide = true)

    fun saveCopies() = store.saveCopies(emojiList.library.value.sets)

    fun importZip(uri: Uri) = store.importZip(uri, emojiList.library.value.sets)

    fun dismissMessage() { _message.value = null }

    /** Add or Remove a set: rewrites the 10030 (pick 5). */
    fun change(address: String, add: Boolean, found: EmojiSetBrowser.Found? = null) {
        viewModelScope.launch {
            val why = listSave.change(address, add, found?.event)
            _message.value = why ?: if (add) "Set added to your emoji list." else "Set removed from your emoji list."
        }
    }

    fun loadOldSets() {
        if (_oldSets.value.loading) return
        _oldSets.value = _oldSets.value.copy(loading = true)
        viewModelScope.launch {
            val found = runCatching { ownSets.find() }.getOrNull()
            _oldSets.value = OldSetsState(found = found)
        }
    }

    /** Add back one old set: restore its emoji if the newest copy lost them, then list it. Only on a tap. */
    fun addBack(old: OwnEmojiSets.OldSet) {
        val found = _oldSets.value.found ?: return
        if (_oldSets.value.busy != null) return
        _oldSets.value = _oldSets.value.copy(busy = old.address)
        viewModelScope.launch {
            val why = runCatching { ownSets.addBack(old, found) }.getOrElse { it.message ?: "Not added back." }
            _message.value = why ?: "\u201c${old.set.title}\u201d is back in your emoji list."
            _oldSets.value = _oldSets.value.copy(busy = null)
            if (why == null) loadOldSets()
        }
    }

    fun browse(scope: EmojiSetBrowser.Scope) = load { browser.browse(scope) }

    /** A pasted naddr (one set), or an npub / hex key (that person's sets). */
    fun lookUp(text: String) {
        val t = text.trim().removePrefix("nostr:")
        when {
            t.startsWith("naddr1") -> load { listOfNotNull(browser.byNaddr(t)) }
            t.startsWith("npub1") -> HavenBridge.decodeNpub(t)?.let { pk -> load { browser.byAuthor(pk) } }
                ?: run { _browse.value = BrowseState(note = "That npub isn't valid.") }
            t.length == 64 && t.all { it in '0'..'9' || it in 'a'..'f' } -> load { browser.byAuthor(t) }
            else -> _browse.value = BrowseState(note = "Paste an naddr (one set) or an npub (their sets).")
        }
    }

    private fun load(body: suspend () -> List<EmojiSetBrowser.Found>) {
        _browse.value = BrowseState(loading = true)
        viewModelScope.launch {
            val found = runCatching { body() }.getOrDefault(emptyList())
            nostrService.fetchMissingProfiles(found.map { it.event.pubkey }.distinct())
            _browse.value = BrowseState(found = found, note = if (found.isEmpty()) "No sets found." else null)
        }
    }
}
