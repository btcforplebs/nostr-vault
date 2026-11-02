package com.nostrvault.service

import com.nostrvault.data.model.MuteList
import kotlinx.coroutines.CancellationException
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonPrimitive

/**
 * What a merged list (List backups › Merge) saves, on top of the one safe save
 * every new list version goes through ([ListVersionSave]: newest list re-read
 * and must be the one the merge was built on, undo copy in the vault first,
 * signed as the list's author after the one it replaces, account switch
 * refused). Pure for the tests. Web twin: web-vault/src/net/list-merge-save.js.
 */
object ListMergeSave {
    /**
     * Why the merge can't be saved at all, before anything is fetched or signed, or null.
     * [baseOpened]: the base's private part was read, so [privateTags] can hold all of it;
     * a base with a private part not read is refused (the new event replaces that part,
     * and entries never read would be wiped).
     */
    fun refusal(kind: Int, base: ListVersion?, baseOpened: Boolean, tags: List<List<String>>, privateTags: List<List<String>>): String? {
        if (ListVersionMerge.mergeKind(kind) == null) return "Not saved: this list can't be merged here."
        if (tags.none { it.isNotEmpty() && it[0] !in ListShrinkRule.metadataTags } && privateTags.isEmpty()) {
            return "Not saved: the merged list would be empty."
        }
        if (ListVersionMerge.hasPrivate(base) && !baseOpened) {
            return "Not saved: the private part of the list you have now couldn't be opened, so saving would wipe it. Nothing was changed."
        }
        return null
    }

    /**
     * Why a merge for [account]'s list is refused because a version it was built from
     * ([authors]: the current list and the ticked ones) belongs to another account, or null.
     * A page left open across an account switch must not sign one account's entries as another's list.
     */
    fun authorRefusal(account: String, authors: Set<String>): String? =
        if (account.isNotEmpty() && authors.isNotEmpty() && authors.all { it == account }) null
        else "This list belongs to another account. Switch to it first."

    /**
     * The new version, [tags] and its content, once the newest list is [current]: kind 3 keeps
     * its content (relay hints); otherwise the [privateTags] encrypted to self,
     * in the scheme the current private part uses (NIP-04 when it has "?iv=",
     * else NIP-44), and "" with none. The ciphertext is opened again and must
     * give back the same text in the same scheme, so a signer that echoes the
     * plaintext or uses another key never gets published (as [ListMerge.removingPrivate]).
     * [encrypt] / [decrypt] take the text and whether it is NIP-04, and return null when this device can't.
     * Refused when the private entries can't be encrypted and checked.
     */
    suspend fun build(
        kind: Int,
        current: NostrEvent?,
        tags: List<List<String>>,
        privateTags: List<List<String>>,
        encrypt: suspend (String, Boolean) -> String?,
        decrypt: suspend (String, Boolean) -> String?,
    ): ListVersionSave.Build = content(kind, current, tags, privateTags, encrypt, decrypt)
        ?: ListVersionSave.Build.Refuse("Not saved: this sign-in can't encrypt your private entries. Nothing was changed.")

    private suspend fun content(
        kind: Int,
        current: NostrEvent?,
        tags: List<List<String>>,
        privateTags: List<List<String>>,
        encrypt: suspend (String, Boolean) -> String?,
        decrypt: suspend (String, Boolean) -> String?,
    ): ListVersionSave.Build.Ready? {
        if (kind == 3) return ListVersionSave.Build.Ready(tags, current?.content.orEmpty())
        if (privateTags.isEmpty()) return ListVersionSave.Build.Ready(tags, "")
        val plaintext = JsonArray(privateTags.map { tag -> JsonArray(tag.map(::JsonPrimitive)) }).toString()
        val nip04 = current?.content?.let { MuteList.isNip04(it.trim()) } ?: false
        val encrypted = attempt { encrypt(plaintext, nip04) }
        if (encrypted.isNullOrBlank() || MuteList.isNip04(encrypted) != nip04) return null
        if (attempt { decrypt(encrypted, nip04) } != plaintext) return null
        return ListVersionSave.Build.Ready(tags, encrypted)
    }

    private suspend fun attempt(block: suspend () -> String?): String? = try {
        block()
    } catch (e: CancellationException) {
        throw e
    } catch (e: Exception) {
        null
    }
}
