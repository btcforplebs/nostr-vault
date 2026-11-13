package com.nostrvault.service.emoji

import android.util.Log
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.relay.vaultAuthRelayTag
import com.nostrvault.service.EmojiListRepository
import com.nostrvault.service.ListMerge
import com.nostrvault.service.ListVersionSave
import com.nostrvault.service.NostrEvent
import com.nostrvault.service.NostrService
import com.nostrvault.service.VaultSocket
import com.nostrvault.service.forceOwnerFor
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Add or Remove a set on the Emoji page: a new kind 10030 with one `a` tag more or less (Logen's pick 5), through the
 * one safe list save ([ListVersionSave]: newest list fetched again and must be the one shown, undo copy in the vault
 * first, signed after the one it replaces). Every other tag is kept ([EmojiCopyRules.listTags]). An added set's own
 * 30030 is sent on to the person's relays and kept in the vault ([EmojiVaultStore.keepSetEvents]).
 */
@Singleton
class EmojiListSave @Inject constructor(
    private val nostrService: NostrService,
    private val configStore: ConfigStore,
    private val emojiList: EmojiListRepository,
    private val store: EmojiVaultStore,
) {
    /** Null when saved, else what to tell the person. */
    suspend fun change(address: String, add: Boolean, setEvent: NostrEvent? = null): String? {
        val account = configStore.activeAccountHexPubkey.value
        if (account.isEmpty()) return "Sign in first."
        val forceOwner = nostrService.forceOwnerFor(configStore.config.value.activeOrOwnerNpub())
            ?: return "This list belongs to another account. Switch to it first."
        val vaultUrl = configStore.config.value.localRelayURL("") ?: return "Your vault isn't running. Nothing was changed."
        val shown = emojiList.listEvent
        val outcome = ListVersionSave(steps(account, forceOwner, vaultUrl)).save(account, KIND, shown?.id, if (add) "add" else "remove") { current ->
            val tags = EmojiCopyRules.listTags(current?.tags.orEmpty(), address, add)
                ?: return@save ListVersionSave.Build.Refuse(if (add) "That set is already in your emoji list." else "That set isn't in your emoji list.")
            ListVersionSave.Build.Ready(tags, current?.content.orEmpty())
        }
        return when (outcome) {
            is ListVersionSave.Outcome.Saved -> {
                if (add && setEvent != null) store.keepEvents(listOf(setEvent))
                emojiList.refresh(force = true, wide = true)
                null
            }
            is ListVersionSave.Outcome.Refused -> {
                if (outcome.changed) emojiList.refresh(force = true, wide = true)
                outcome.message
            }
        }
    }

    private fun steps(account: String, forceOwner: Boolean, vaultUrl: String) = object : ListVersionSave.Steps {
        override fun activeAccount() = configStore.activeAccountHexPubkey.value

        override suspend fun newest(): Result<NostrEvent?> {
            val own = nostrService.ownListRelays(account)
            val lookup = runCatching {
                nostrService.lookupNewestReplaceable(KIND, account, (own + configStore.config.value.readRelays.take(3)).distinct())
            }.getOrElse { NostrService.ReplaceableLookup(null, 0, 0) }
            return when (val base = ListMerge.editBase(lookup, null, own)) {
                is ListMerge.EditBase.Found -> Result.success(base.event)
                ListMerge.EditBase.None -> Result.success(null)
                is ListMerge.EditBase.Unknown -> Result.failure(IllegalStateException(base.why))
            }
        }

        override suspend fun keepUndoCopy(current: NostrEvent) = VaultSocket.publish(vaultUrl, current, ::signAuth)

        override suspend fun sign(kind: Int, content: String, tags: List<List<String>>, notBefore: Long) = try {
            nostrService.signEventAsync(kind = kind, content = content, tags = tags, forceOwner = forceOwner, notBefore = notBefore)
        } catch (e: Exception) {
            Log.e(TAG, "10030 not signed: ${e.message}")
            null
        }

        override suspend fun store(signed: NostrEvent) = VaultSocket.publish(vaultUrl, signed, ::signAuth)

        override suspend fun send(signed: NostrEvent) = nostrService.postEvent(signed)
    }

    private suspend fun signAuth(challenge: String): NostrEvent? {
        val url = configStore.config.value.localRelayURL("") ?: return null
        return runCatching {
            nostrService.signEventAsync(
                kind = 22242,
                content = "",
                tags = listOf(listOf("relay", configStore.config.value.vaultAuthRelayTag(url)), listOf("challenge", challenge)),
                forceOwner = true,
            )
        }.getOrNull()
    }

    private companion object {
        const val TAG = "EmojiListSave"
        const val KIND = 10030
    }
}
