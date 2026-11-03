package com.nostrvault.service

import com.nostrvault.service.shareportal.handlers.BookmarkShareHandler.Outcome
import com.nostrvault.service.shareportal.handlers.BookmarkShareTags
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Save for later from the Share Portal: one `r` tag added to [author]'s kind 10003, publicly or in the private part,
 * on the newest list the account's own relays agree on ([publishMergedList], the path [publishBookmarkImpl] uses).
 * Every other tag and private entry goes back as it was; a private part this device can't open, or can't encrypt
 * again, leaves the list untouched. Twin of iOS BookmarkShareHandler.save.
 */
internal suspend fun NostrService.publishSharedBookmarkImpl(
    url: String,
    privately: Boolean,
    author: String,
    forceOwner: Boolean,
): Outcome {
    if (author.isBlank()) return Outcome.Failed(null)
    val done = CompletableDeferred<Outcome>()
    // Set by build, read by onUnchanged: both run in turn on publishMergedList's coroutine.
    var why: Outcome? = null
    publishMergedList(
        BookmarkShareTags.KIND, author, forceOwner,
        onRefused = { done.complete(Outcome.Failed(it)) },
        onSigned = { done.complete(Outcome.Saved(privately)) },
        onUnchanged = { done.complete(why ?: Outcome.Failed(null)) },
        onNotSigned = { done.complete(Outcome.Failed("your signer didn't sign")) },
    ) { published ->
        val tags = published?.tags.orEmpty()
        val content = published?.content.orEmpty()
        val privateTags = if (content.isEmpty()) emptyList() else {
            val plain = runCatching { decryptOwnList(author, content, content.contains("?iv=")) }.getOrNull()
            plain?.let(BookmarkShareTags::privateTags) ?: run {
                why = Outcome.Failed("your private bookmarks couldn't be opened here, so nothing was changed")
                return@publishMergedList null
            }
        }
        when (val change = BookmarkShareTags.adding(url, tags, privateTags, privately)) {
            BookmarkShareTags.Change.AlreadyPublic -> { why = Outcome.AlreadyPublic; null }
            BookmarkShareTags.Change.AlreadyPrivate -> { why = Outcome.AlreadyPrivate; null }
            is BookmarkShareTags.Change.PublicTags -> change.tags to content
            is BookmarkShareTags.Change.PrivateTags -> {
                // NIP-44 to self, as every app's list merge saves a private part.
                val sealed = runCatching { encryptOwnList(author, BookmarkShareTags.json(change.tags), nip04 = false) }.getOrNull()
                    ?: run {
                        why = Outcome.Failed("your signer couldn't encrypt the private bookmark, so nothing was changed")
                        return@publishMergedList null
                    }
                tags to sealed
            }
        }
    }
    return withTimeoutOrNull(60_000) { done.await() } ?: Outcome.Failed(null)
}
