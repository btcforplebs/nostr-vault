package com.nostrvault.util

import com.nostrvault.data.model.FeedProfile
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

/**
 * Accounts whose secret key is public: a profile the app already fetched
 * shows a valid nsec, and the key's own public key goes here. Anyone can post
 * as these accounts, so their profile says so and the web of trust counts
 * them as outside your web. Twin of Apple `PublicKeyRegistry.swift`.
 *
 * Memory only, never saved: it holds public keys, never the secret ones, and
 * is refilled from profiles as they load. No relay is asked for this.
 */
object PublicKeyRegistry {

    /** The profile line for one of these accounts. */
    const val LABEL = "Key is public. Anyone can post as this account"

    private val _keys = MutableStateFlow<Set<String>>(emptySet())

    /** Hex public keys (lowercase) whose secret key is public. */
    val keys: StateFlow<Set<String>> = _keys.asStateFlow()

    fun isPublic(pubkey: String): Boolean = pubkey.lowercase() in _keys.value

    /**
     * Records every account whose nsec is in [text] (a kind 0's content, or
     * one profile field). [derive] is [SecretKeyLeak.derivedPubkeys]'s.
     */
    fun noteText(text: String?, derive: ((String) -> String?)? = null) {
        if (text.isNullOrEmpty() || !text.contains("nsec1", ignoreCase = true)) return
        val found = if (derive != null) SecretKeyLeak.derivedPubkeys(text, derive) else SecretKeyLeak.derivedPubkeys(text)
        add(found)
    }

    /** [noteText] over each profile's text fields (profiles read back from disk keep no raw content). */
    fun noteProfiles(profiles: Collection<FeedProfile>, derive: ((String) -> String?)? = null) {
        for (p in profiles) {
            for (field in listOf(p.name, p.displayName, p.about, p.nip05, p.lud16, p.lud06, p.website, p.pictureURL, p.bannerURL)) {
                noteText(field, derive)
            }
        }
    }

    /**
     * [web] without the accounts whose key is public, except [own] (this
     * device's accounts, asked only when there is something to remove): your
     * own notes stay in your feeds even if your own key is public.
     */
    fun withoutPublic(web: Set<String>, own: () -> Set<String> = { emptySet() }): Set<String> {
        val public = _keys.value
        if (public.isEmpty() || web.isEmpty() || web.none { it in public }) return web
        val keep = own().mapTo(HashSet()) { it.lowercase() }
        return web.filterTo(LinkedHashSet()) { it !in public || it.lowercase() in keep }
    }

    private fun add(found: List<String>) {
        if (found.isEmpty()) return
        _keys.update { current -> if (current.containsAll(found)) current else current + found }
    }

    internal fun clearForTest() { _keys.value = emptySet() }
}
