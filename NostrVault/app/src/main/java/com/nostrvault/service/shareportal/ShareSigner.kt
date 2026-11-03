package com.nostrvault.service.shareportal

import com.nostrvault.data.local.ConfigStore
import com.nostrvault.service.NostrEvent
import com.nostrvault.data.model.PostingAccount
import com.nostrvault.service.NostrService
import com.nostrvault.shareportal.ShareIntent
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Signs and sends one review card's event as the intent's account, locked
 * like HighlightShareHandler: a switch while the signer is busy returns
 * [Outcome.WrongAccount] instead of posting as someone else. The caller passes
 * the sign call itself so each publisher keeps a literal kind
 * (UserListSignGuardTest).
 */
@Singleton
class ShareSigner @Inject constructor(
    private val nostrService: NostrService,
    private val configStore: ConfigStore,
) {
    enum class Outcome { Published, WrongAccount, NotSigned }

    fun accountNpub(intent: ShareIntent): String = intent.account ?: configStore.config.value.activeOrOwnerNpub()

    fun needsAccountSwitch(intent: ShareIntent): Boolean {
        val wanted = intent.account ?: return false
        return wanted != configStore.config.value.activeOrOwnerNpub()
    }

    /** The account's hex key, the composer drafts' account key. */
    fun accountHex(intent: ShareIntent): String? = nostrService.npubToHex(accountNpub(intent))

    suspend fun send(intent: ShareIntent, sign: suspend NostrService.(PostingAccount.Lock) -> NostrEvent?): Outcome {
        if (needsAccountSwitch(intent)) return Outcome.WrongAccount
        val npub = accountNpub(intent)
        val hex = nostrService.npubToHex(npub) ?: return Outcome.NotSigned
        val event = try {
            nostrService.sign(PostingAccount.Lock(npub = npub, hex = hex))
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
