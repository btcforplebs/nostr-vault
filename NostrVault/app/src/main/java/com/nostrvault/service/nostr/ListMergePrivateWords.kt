package com.nostrvault.service

import com.nostrvault.data.model.MuteList
import kotlinx.coroutines.CancellationException
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonPrimitive

/**
 * The private part of a kind 10000 with [name] entries put in ([add]) and
 * taken out ([remove]), every other entry kept as it is: a muted word made
 * or lifted privately. As JSON again, or null when [plaintext] is not exactly
 * a JSON array of string arrays (writing it back would lose what it holds).
 */
internal fun ListMerge.privateTagsEdited(plaintext: String, name: String, add: List<String>, remove: List<String>): String? {
    val array = runCatching { Json.parseToJsonElement(plaintext) as? JsonArray }.getOrNull() ?: return null
    val tags = array.map { item ->
        val tag = item as? JsonArray ?: return null
        tag.map { value -> (value as? JsonPrimitive)?.takeIf { it.isString }?.content ?: return null }
    }
    val edited = edit(name, tags, add, remove)
    return JsonArray(edited.map { tag -> JsonArray(tag.map(::JsonPrimitive)) }).toString()
}

/**
 * [content] with [name] entries added and removed in its encrypted part,
 * encrypted again with the scheme it came in (NIP-04 when it has "?iv=",
 * else NIP-44); an empty content starts a NIP-44 one when there is something
 * to add. Unchanged when the edit changes nothing. When the content can't be
 * opened: a removal that [mayBePrivate] says isn't held privately leaves it
 * as it is; anything else fails, since a new part would lose what it holds.
 * The new content must open again to the edited part, as in
 * [ListMerge.removingPrivate].
 */
internal suspend fun ListMerge.editingPrivateTags(
    content: String,
    name: String,
    add: List<String>,
    remove: List<String>,
    mayBePrivate: Boolean,
    decrypt: suspend (String, Boolean) -> String?,
    encrypt: suspend (String, Boolean) -> String?,
): ListMerge.PrivateEdit {
    val ciphertext = content.trim()
    if (add.isEmpty() && (remove.isEmpty() || ciphertext.isEmpty())) return ListMerge.PrivateEdit.Done(content)
    val nip04 = ciphertext.isNotEmpty() && MuteList.isNip04(ciphertext)
    val plaintext = if (ciphertext.isEmpty()) "[]"
    else privateTagsAttempt { decrypt(ciphertext, nip04) }
        ?: return if (add.isEmpty() && !mayBePrivate) ListMerge.PrivateEdit.Done(content) else ListMerge.PrivateEdit.Failed
    val edited = privateTagsEdited(plaintext, name, add, remove) ?: return ListMerge.PrivateEdit.Failed
    if (ciphertext.isNotEmpty() && MuteList.privateTags(edited) == MuteList.privateTags(plaintext)) return ListMerge.PrivateEdit.Done(content)
    val encrypted = privateTagsAttempt { encrypt(edited, nip04) }
    if (encrypted.isNullOrBlank() || MuteList.isNip04(encrypted) != nip04) return ListMerge.PrivateEdit.Failed
    return if (privateTagsAttempt { decrypt(encrypted, nip04) } == edited) ListMerge.PrivateEdit.Done(encrypted)
    else ListMerge.PrivateEdit.Failed
}

/** [block]'s result, or null when it throws; cancellation still cancels. */
private suspend fun privateTagsAttempt(block: suspend () -> String?): String? = try {
    block()
} catch (e: CancellationException) {
    throw e
} catch (e: Exception) {
    null
}
