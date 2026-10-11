package com.nostrvault.ui.screens

import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.lifecycle.viewModelScope
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.service.NostrService
import com.nostrvault.ui.components.NostrMentions
import com.nostrvault.ui.theme.*
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch

    /**
     * Finds the @query at the caret and populates [mentionResults]. Scans backwards
     * from the caret to the `@` that begins the token currently being edited, so
     * mentions work mid-message and not only at the end.
     */
    internal fun ComposeNoteViewModel.updateMentionQuery(text: String, caret: Int) {
        val safeCaret = caret.coerceIn(0, text.length)

        var atIndex = -1
        var i = safeCaret
        while (i > 0) {
            val ch = text[i - 1]
            if (ch == '@') { atIndex = i - 1; break }
            // A mention token can't contain whitespace/newline.
            if (ch == ' ' || ch == '\n' || ch == '\t') break
            i--
        }

        if (atIndex < 0) { clearMention(); return }

        // The `@` must start a word (preceded by start-of-text or whitespace) so
        // email addresses like foo@bar.com don't trigger the picker.
        if (atIndex > 0) {
            val before = text[atIndex - 1]
            if (before != ' ' && before != '\n' && before != '\t') { clearMention(); return }
        }

        val query = text.substring(atIndex + 1, safeCaret)
        mentionStartOffset = atIndex
        mentionEndOffset = safeCaret
        currentMentionQuery = query
        filterMentionResults(query)
        searchMentionProfiles(query)
    }

    private fun ComposeNoteViewModel.filterMentionResults(query: String) {
        val profilesMap = nostrService.profiles.value
        val followed = feedService.followedPubkeys.value
        val self = nostrService.activeHexPubkey

        // Thread participants are valid mention targets when replying, even if
        // you don't follow them.
        val parent = replyToNoteId?.let { feedService.findNote(it) }
        val threadPubkeys = LinkedHashSet<String>()
        if (parent != null) {
            threadPubkeys.add(parent.pubkey)
            parent.tags.filter { it.size >= 2 && it[0] == "p" }.forEach { threadPubkeys.add(it[1]) }
        }
        threadPubkeys.remove(self)

        val results: List<FeedProfile> = if (query.isEmpty()) {
            // Just typed `@`: thread participants first, then followed.
            val threadProfiles = threadPubkeys.mapNotNull { profilesMap[it] }
            val followedProfiles = followed.asSequence()
                .filter { it != self }
                .mapNotNull { profilesMap[it] }
                .filter { p -> threadProfiles.none { it.pubkey == p.pubkey } }
            (threadProfiles + followedProfiles).take(8)
        } else {
            // Search the entire profile cache (feed authors, search results, etc.),
            // not just follows, ranking thread participants, follows, then the
            // rest of the Web of Trust first.
            val lower = query.lowercase()
            val followedSet = followed.toHashSet()
            val wotSet = feedService.webOfTrustForRanking()
            profilesMap.values.asSequence()
                .filter { it.pubkey != self }
                .filter { p ->
                    p.bestName.lowercase().contains(lower) ||
                        (p.name?.lowercase()?.contains(lower) == true) ||
                        (p.displayName?.lowercase()?.contains(lower) == true) ||
                        (p.nip05?.lowercase()?.contains(lower) == true)
                }
                .sortedWith(
                    compareByDescending<FeedProfile> { threadPubkeys.contains(it.pubkey) }
                        .thenByDescending { followedSet.contains(it.pubkey) }
                        .thenByDescending { wotSet.contains(it.pubkey) }
                        .thenByDescending { it.bestName.lowercase().startsWith(lower) }
                        .thenBy { it.bestName.length }
                )
                .take(8)
                .toList()
        }

        _mentionResults.value = results
    }

    /**
     * Debounced NIP-50 relay search so you can @-mention people who aren't followed
     * and whose profile isn't cached yet. Discovered profiles are merged into the
     * cache by [NostrService.globalSearch]; we re-filter when results arrive.
     */
    private fun ComposeNoteViewModel.searchMentionProfiles(query: String) {
        mentionSearchJob?.cancel()
        if (query.length < 2) return
        mentionSearchJob = viewModelScope.launch {
            delay(350)
            nostrService.globalSearch(query, NostrService.SearchCaller.MENTION) {
                if (currentMentionQuery == query) {
                    filterMentionResults(query)
                }
            }
        }
    }

    internal fun ComposeNoteViewModel.clearMention() {
        mentionStartOffset = null
        mentionEndOffset = null
        currentMentionQuery = null
        mentionSearchJob?.cancel()
        _mentionResults.value = emptyList()
    }

    /** Display token shown in the editor for a mention (e.g. "@Alice"). */
    internal fun ComposeNoteViewModel.mentionToken(name: String, pubkey: String): String {
        val clean = name.replace('\n', ' ').trim()
        return "@" + clean.ifEmpty { pubkey.take(8) }
    }

    /**
     * Converts `nostr:npub1…`/`nostr:nprofile1…` references to readable `@name`
     * tokens for editing, rebuilding [mentionMap]. Used when restoring a draft.
     */
    internal fun ComposeNoteViewModel.convertNostrToMentions(text: String): String {
        val profilesMap = nostrService.profiles.value
        return NostrMentions.MENTION_REGEX.replace(text) { match ->
            val pubkey = NostrMentions.resolvePubkey(match.groupValues[1]) ?: return@replace match.value
            val token = mentionToken(profilesMap[pubkey]?.bestName ?: "", pubkey)
            mentionMap[token] = pubkey
            token
        }
    }

    /**
     * Converts `@name` display tokens back to canonical `nostr:npub…` references for
     * publishing and draft persistence. Longest tokens first so a shorter name that is
     * a prefix of another doesn't clobber it; a trailing word-boundary guards against
     * partial matches inside other words.
     */
    internal fun ComposeNoteViewModel.convertMentionsToNostr(text: String): String {
        if (mentionMap.isEmpty()) return text
        var result = text
        for ((token, pubkey) in mentionMap.entries.sortedByDescending { it.key.length }) {
            val npub = nostrService.hexToNpub(pubkey) ?: continue
            val pattern = Regex(Regex.escape(token) + """(?![\p{L}\p{N}_])""")
            result = pattern.replace(result) { "nostr:$npub" }
        }
        return result
    }
