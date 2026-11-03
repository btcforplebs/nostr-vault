package com.nostrvault.service.shareportal.handlers

import com.nostrvault.data.local.ConfigStore
import com.nostrvault.service.BookmarkService
import com.nostrvault.service.NostrService
import com.nostrvault.service.forceOwnerFor
import com.nostrvault.service.publishSharedBookmarkImpl
import com.nostrvault.shareportal.ShareAction
import com.nostrvault.shareportal.ShareClassifier
import com.nostrvault.shareportal.ShareInput
import com.nostrvault.shareportal.ShareIntent

/**
 * Save for later (kind 10003): a shared link goes on the account's Bookmarks list, publicly or privately. Written
 * through the Bookmarks store's own merged-list path (`publishMergedList`, as [com.nostrvault.service.publishBookmarkImpl]),
 * never a list of its own: the newest list the account's relays agree on is fetched at the tap, only this one `r`
 * tag is added, and a private part this device can't open is never written over. Private entries are encrypted to
 * the account itself: NIP-44, or NIP-04 when the list's private part already is (as the mute list path). Tron review (private bookmarks). Twin: BookmarkShareHandler.swift.
 */
object BookmarkShareHandler : ShareHandler {
    override val action = ShareAction.BOOKMARK
    override val isReady = true

    sealed interface Outcome {
        data class Saved(val privately: Boolean) : Outcome
        data object AlreadyPublic : Outcome
        data object AlreadyPrivate : Outcome
        /** The signer hasn't answered in 60 s but may still sign (Amber, a bunker): the save may still go out. */
        data object MayStillGoOut : Outcome
        /** Not signed or not sent; [why] is said on the card. */
        data class Failed(val why: String?) : Outcome
    }

    /** The link the share saves, if it named one. */
    fun url(intent: ShareIntent): String? =
        BookmarkShareTags.url(ShareClassifier.webUrl(ShareInput(url = intent.source.url, text = intent.source.text)))

    /** Adds [url] to the active account's bookmarks. The card only offers this for the account the share was meant
     *  for, once it is the active one. */
    suspend fun save(
        nostrService: NostrService,
        configStore: ConfigStore,
        bookmarkService: BookmarkService,
        url: String,
        privately: Boolean,
    ): Outcome {
        if (!bookmarkService.canSign) return Outcome.Failed("This account is read-only here.")
        val hex = configStore.activeAccountHexPubkey.value
        val forceOwner = nostrService.forceOwnerFor(configStore.config.value.activeOrOwnerNpub())
            ?: return Outcome.Failed("Switch to that account first.")
        if (hex.isEmpty()) return Outcome.Failed("No account is signed in.")
        val outcome = nostrService.publishSharedBookmarkImpl(url, privately, hex, forceOwner)
        // The Bookmarks page and the note menus read the new list.
        if (outcome is Outcome.Saved) bookmarkService.refresh(force = true)
        return outcome
    }
}
