package com.nostrvault.ui.screens.shareportal

import android.content.Context
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.service.DMService
import com.nostrvault.service.NostrService
import com.nostrvault.shareportal.ShareContactsSnapshot
import com.nostrvault.shareportal.ShareIntent
import dagger.hilt.android.lifecycle.HiltViewModel
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import javax.inject.Inject

/**
 * Send privately's review card: recipient search and the send itself,
 * as the share's account only. Twin: DMShareHandler.swift.
 */
@HiltViewModel
class DMReviewViewModel @Inject constructor(
    @ApplicationContext private val context: Context,
    private val dmService: DMService,
    private val nostrService: NostrService,
    private val configStore: ConfigStore,
) : ViewModel() {
    private val _busy = MutableStateFlow(false)
    val busy: StateFlow<Boolean> = _busy.asStateFlow()
    private val _error = MutableStateFlow<String?>(null)
    val error: StateFlow<String?> = _error.asStateFlow()

    val profiles: StateFlow<Map<String, FeedProfile>> get() = nostrService.profiles

    fun account(intent: ShareIntent): String = intent.account ?: configStore.config.value.activeOrOwnerNpub()

    fun npubToHex(npub: String): String? = nostrService.npubToHex(npub)
    fun hexToNpub(hex: String): String? = nostrService.hexToNpub(hex)

    /** Empty query: recent share recipients, then recent conversations. Else names on this device, or a pasted npub. */
    fun candidates(intent: ShareIntent, query: String): List<String> {
        val q = query.trim()
        if (q.lowercase().startsWith("npub1")) return listOfNotNull(nostrService.npubToHex(q))
        if (q.length >= 2) {
            val lower = q.lowercase()
            return nostrService.profiles.value.filterValues { it.bestName.lowercase().contains(lower) }.keys.sorted().take(10)
        }
        val recent = ShareContactsSnapshot.read(ShareContactsSnapshot.file(context))
            ?.contacts(account(intent)).orEmpty().mapNotNull { nostrService.npubToHex(it.npub) }
        return (recent + dmService.conversations.value.take(8).map { it.id }).distinct()
    }

    /** Sends as the share's account only; on success records the recipient for the share sheet. */
    fun send(intent: ShareIntent, message: String, toHex: String, onSent: () -> Unit) {
        if (_busy.value) return
        val text = message.trim()
        if (text.isEmpty()) return
        _busy.value = true
        _error.value = null
        viewModelScope.launch {
            try {
                val npub = account(intent)
                val toNpub = nostrService.hexToNpub(toHex)
                when {
                    toHex.length != 64 || toNpub == null -> _error.value = "That isn't someone a message can go to."
                    npub != configStore.config.value.activeOrOwnerNpub() ||
                        nostrService.npubToHex(npub)?.lowercase() != nostrService.activeHexPubkey.lowercase() ->
                        _error.value = "The account changed, so nothing was sent."
                    else -> {
                        dmService.sendDM(text, toHex)
                        record(npub, toNpub, toHex)
                        onSent()
                    }
                }
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: Exception) {
                _error.value = e.message ?: "Not sent."
            } finally {
                _busy.value = false
            }
        }
    }

    private suspend fun record(account: String, toNpub: String, toHex: String) = withContext(Dispatchers.IO) {
        val profile = nostrService.profiles.value[toHex]
        val file = ShareContactsSnapshot.file(context)
        val current = ShareContactsSnapshot.read(file) ?: ShareContactsSnapshot()
        val keep = configStore.config.value.allAccountNpubs().toSet()
        ShareContactsSnapshot.write(
            file,
            current.recording(ShareContactsSnapshot.Contact(toNpub, profile?.bestName.orEmpty(), profile?.pictureURL), account)
                .keeping(keep),
        )
    }
}
