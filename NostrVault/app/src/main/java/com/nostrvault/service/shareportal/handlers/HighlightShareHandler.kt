package com.nostrvault.service.shareportal.handlers

import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.model.PostingAccount
import com.nostrvault.service.NostrService
import com.nostrvault.shareportal.ShareAction
import com.nostrvault.shareportal.ShareClassifier
import com.nostrvault.shareportal.ShareInput
import com.nostrvault.shareportal.ShareIntent
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Publishes a shared highlight (kind 9802) after the review card's Publish
 * tap, signed by whatever signer the active account uses. Twin:
 * HighlightShareHandler.swift.
 */
@Singleton
class HighlightShareHandler @Inject constructor(
    private val nostrService: NostrService,
    private val configStore: ConfigStore,
) : ShareHandler {
    override val action = ShareAction.HIGHLIGHT
    override val isReady = true

    sealed interface Outcome {
        data object Published : Outcome
        /** The intent names another account than the active one; switch first. */
        data object WrongAccount : Outcome
        data object NotSigned : Outcome
        data object Empty : Outcome
    }

    /** The page the highlight came from, if the share named one. */
    fun sourceUrl(intent: ShareIntent): String? = ShareClassifier.webUrl(
        ShareInput(url = intent.source.url, text = intent.source.text),
    )

    /** The passage the review card starts from: the form's, else the selection, else the text. */
    fun initialPassage(intent: ShareIntent): String =
        intent.form["passage"]?.takeIf { it.isNotBlank() }
            ?: intent.source.selection?.takeIf { it.isNotBlank() }
            ?: intent.source.text?.takeIf { sourceUrl(intent) == null }.orEmpty()

    /** True when [intent] is for an account other than the one that would sign. */
    fun needsAccountSwitch(intent: ShareIntent): Boolean {
        val wanted = intent.account ?: return false
        return wanted != configStore.config.value.activeOrOwnerNpub()
    }

    suspend fun publish(intent: ShareIntent, passage: String, comment: String): Outcome {
        if (passage.isBlank()) return Outcome.Empty
        if (needsAccountSwitch(intent)) return Outcome.WrongAccount
        val tags = HighlightShareTags.tags(sourceUrl(intent), passage, comment)
        // Locked to the account, like iOS's lockedTo: a switch while the
        // signer is busy throws instead of posting as someone else.
        val npub = intent.account ?: configStore.config.value.activeOrOwnerNpub()
        val hex = nostrService.npubToHex(npub) ?: return Outcome.NotSigned
        val lock = PostingAccount.Lock(npub = npub, hex = hex)
        val event = try {
            // A literal kind: UserListSignGuardTest flags a signer whose kind is a variable.
            nostrService.signEventAsync(kind = 9802, content = passage.trim(), tags = tags, lockedTo = lock)
        } catch (e: PostingAccount.AccountChangedException) {
            return Outcome.WrongAccount
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Exception) {
            null
        } ?: return Outcome.NotSigned
        nostrService.postEvent(event)
        return Outcome.Published
    }
}
