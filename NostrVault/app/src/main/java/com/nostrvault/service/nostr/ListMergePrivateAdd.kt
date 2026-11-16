package com.nostrvault.service

import com.nostrvault.data.model.MuteList
import kotlinx.coroutines.CancellationException
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonPrimitive

/**
 * The private part of a kind 10000 with people put in: the decrypted
 * [plaintext] with a "p" entry for each of [add] (hex) it doesn't hold yet, as
 * JSON again. Null when it is not exactly a JSON array of string arrays:
 * writing it back would then lose what it holds. iOS: ListMerge.privateAdded.
 */
internal fun ListMerge.privateAdded(plaintext: String, add: List<String>): String? {
    val array = runCatching { Json.parseToJsonElement(plaintext) as? JsonArray }.getOrNull() ?: return null
    val tags = array.map { item ->
        val tag = item as? JsonArray ?: return null
        tag.map { value -> (value as? JsonPrimitive)?.takeIf { it.isString }?.content ?: return null }
    }
    val edited = edit("p", tags, add, emptyList())
    return JsonArray(edited.map { tag -> JsonArray(tag.map(::JsonPrimitive)) }).toString()
}

/**
 * [content] with [add] (hex) put in its encrypted "p" entries: a private
 * block. It is encrypted again with the scheme it came in (NIP-04 when it has
 * "?iv=", else NIP-44); an empty content starts a NIP-44 one. Fails when there
 * is no one to add, when the content can't be opened (a new one would lose
 * what it holds), or when the new content doesn't open again to the edited
 * part in the same scheme, as in [ListMerge.removingPrivate].
 * iOS: ListMerge.addingPrivate.
 */
internal suspend fun ListMerge.addingPrivate(
    content: String,
    add: List<String>,
    decrypt: suspend (String, Boolean) -> String?,
    encrypt: suspend (String, Boolean) -> String?,
): ListMerge.PrivateEdit {
    if (add.isEmpty()) return ListMerge.PrivateEdit.Failed
    val ciphertext = content.trim()
    val nip04 = ciphertext.isNotEmpty() && MuteList.isNip04(ciphertext)
    val plaintext = if (ciphertext.isEmpty()) "[]"
    else privateAddAttempt { decrypt(ciphertext, nip04) } ?: return ListMerge.PrivateEdit.Failed
    val edited = privateAdded(plaintext, add) ?: return ListMerge.PrivateEdit.Failed
    val encrypted = privateAddAttempt { encrypt(edited, nip04) }
    if (encrypted.isNullOrBlank() || MuteList.isNip04(encrypted) != nip04) return ListMerge.PrivateEdit.Failed
    return if (privateAddAttempt { decrypt(encrypted, nip04) } == edited) ListMerge.PrivateEdit.Done(encrypted)
    else ListMerge.PrivateEdit.Failed
}

/** [block]'s result, or null when it throws; cancellation still cancels. */
private suspend fun privateAddAttempt(block: suspend () -> String?): String? = try {
    block()
} catch (e: CancellationException) {
    throw e
} catch (e: Exception) {
    null
}
