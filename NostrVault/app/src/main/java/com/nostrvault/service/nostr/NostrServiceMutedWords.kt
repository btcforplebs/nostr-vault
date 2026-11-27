package com.nostrvault.service

import android.util.Log
import com.nostrvault.data.model.MutedThings
import com.nostrvault.data.model.PostingAccount
import com.nostrvault.service.NostrService.Companion.TAG
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.sync.withLock

/**
 * Muted words on the active account's kind 10000 (NIP-51 `word` tags), a list
 * other clients edit too. Only that one word changes on the newest list:
 * people, hashtags, threads, other words and the rest of the encrypted part
 * are kept, the same way a block is ([publishMuteListChangeImpl]).
 * iOS: ConfigService+MutedWords.swift; web: muted-words.js.
 */
object MutedWords {
    /** Longest word or phrase taken: a muted paragraph is a mistake. */
    const val MAX_LENGTH = 100

    /** [input] as it is stored and matched: trimmed, lowercased, inner spaces folded; null when unusable. */
    fun normalize(input: String): String? {
        val word = input.trim().lowercase().replace(Regex("\\s+"), " ")
        return word.takeIf { it.isNotEmpty() && it.length <= MAX_LENGTH }
    }

    /**
     * The word an add or unmute works on. An add is [normalize]d; an unmute
     * takes the stored row as it is, only trimmed and lowercased the way rows
     * are read (MutedThings.from), so a word another app saved with other
     * spacing or past [MAX_LENGTH] still comes off (Tron #2669 F1).
     */
    fun changed(add: String?, remove: String?): String? = when {
        add != null -> normalize(add)
        remove != null -> remove.trim().lowercase().takeIf { it.isNotEmpty() }
        else -> null
    }
}

/**
 * Mutes ([add]) or unmutes ([remove]) one word on [accountNpub]'s kind 10000.
 * [privately]: an added word goes in the encrypted part only, and out of the
 * public tags. An unmute takes it out of both. Nothing is kept on this device
 * first: the word shows once the published list is read back. Returns what to
 * tell the person, or null when it was published (or there was nothing to do).
 */
internal suspend fun NostrService.publishMutedWordChange(
    accountNpub: String,
    add: String? = null,
    remove: String? = null,
    privately: Boolean = true,
): String? {
    if (add == null && remove == null) return null
    // One kind 10000 edit at a time, shared with blocks: two edits built on the
    // same base would drop the earlier one (Tron #2669 F2).
    return muteListPublishMutex.withLock { publishMutedWordChangeLocked(accountNpub, add, remove, privately) }
}

private suspend fun NostrService.publishMutedWordChangeLocked(
    accountNpub: String,
    add: String?,
    remove: String?,
    privately: Boolean,
): String? {
    val word = MutedWords.changed(add, remove) ?: return "That word can't be muted."
    val adding = add != null
    val notSaved = if (adding) "Muted word not saved" else "Unmute not saved"
    val switched = "$notSaved: the account changed before your mute list was published."
    val forceOwner = forceOwnerFor(accountNpub) ?: return switched
    val author = npubToHex(accountNpub) ?: ownerHexPubkey
    if (author.isBlank()) return null
    // Locked before the lookup, which can wait 6 s (as publishMuteListChangeImpl).
    val lock = lockPostingAccount()
    if (!lock.hex.equals(author, ignoreCase = true)) return switched
    val cfg = configStore.config.value
    val own = ownListRelays(author)
    val ask = (own + cfg.writeRelays + relayLists.value[author].orEmpty() + cfg.readRelays + NostrService.PROFILE_RELAYS).distinct()
    val lookup = runCatching { lookupNewestReplaceable(10000, author, ask) }
        .getOrElse { NostrService.ReplaceableLookup(null, 0, 0) }
    val editBase = ListMerge.editBase(lookup, heldMuteList(author), own)
    val (baseTags, baseContent) = when (editBase) {
        is ListMerge.EditBase.Found -> editBase.event.tags to editBase.event.content
        // No list anywhere: this device's public blocks start it, as a block would.
        ListMerge.EditBase.None -> cfg.publicBlockedFor(accountNpub).mapNotNull { npubToHex(it) }.map { listOf("p", it) } to ""
        is ListMerge.EditBase.Unknown -> {
            Log.w(TAG, "kind 10000: list not known (${lookup.answered}/${lookup.asked} relays answered); word not published")
            if (editBase.why == ListMerge.NO_RELAY_LIST) return "$notSaved. ${ListMerge.NO_RELAY_LIST}"
            return "$notSaved: your relays didn't send your mute list, " +
                "and publishing without it would erase what other apps muted. Try again later."
        }
    }
    val knownPrivate = cfg.privateMutedPerAccount[accountNpub]
    val privateEdit = ListMerge.editingPrivateTags(
        baseContent, "word",
        add = if (adding && privately) listOf(word) else emptyList(),
        remove = if (adding) emptyList() else listOf(word),
        mayBePrivate = knownPrivate == null || word in knownPrivate.words,
        decrypt = { text, nip04 -> decryptOwnList(author, text, nip04) },
        encrypt = { text, nip04 -> encryptOwnList(author, text, nip04) },
    )
    val content = when (privateEdit) {
        ListMerge.PrivateEdit.Failed -> return "$notSaved: your private muted words couldn't be opened. Is your signer connected?"
        is ListMerge.PrivateEdit.Done -> privateEdit.content
    }
    val tags = when {
        adding && privately -> ListMerge.edit("word", baseTags, emptyList(), listOf(word))
        adding -> ListMerge.edit("word", baseTags, listOf(word), emptyList())
        else -> ListMerge.edit("word", baseTags, emptyList(), listOf(word))
    }
    if (editBase is ListMerge.EditBase.Found && tags == baseTags && content == baseContent) return null
    val event = try {
        signEventAsync(
            kind = 10000, content = content, tags = tags, forceOwner = forceOwner, lockedTo = lock,
            notBefore = ListMerge.notBefore((editBase as? ListMerge.EditBase.Found)?.event),
        )
    } catch (e: CancellationException) {
        throw e
    } catch (e: PostingAccount.AccountChangedException) {
        return switched
    } catch (e: Exception) {
        Log.e(TAG, "kind 10000 (word) not signed: ${e.message}")
        null
    } ?: return "$notSaved: your signer didn't answer"
    if (!event.pubkey.equals(author, ignoreCase = true)) return switched
    postEvent(event)
    applyMuteList(author, event.id, event.tags, event.content, event.createdAt)
    return null
}

/**
 * The active account's muted words with whether each is private; private
 * first wins when a word is in both. iOS: MutedWordsSettingsView rows.
 */
data class MutedWordRow(val word: String, val private: Boolean)

fun mutedWordRows(public: MutedThings?, private: MutedThings?): List<MutedWordRow> {
    val priv = private?.words.orEmpty()
    return (priv.map { MutedWordRow(it, true) } + public?.words.orEmpty().filter { it !in priv }.map { MutedWordRow(it, false) })
        .sortedBy { it.word }
}
