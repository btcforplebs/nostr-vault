package com.nostrvault.service

import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.model.NwcBackup
import com.nostrvault.relay.HavenBridge
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Reads, saves and removes the wallet string kept on the active account (see
 * [NwcBackup] for the format). The string is only ever published NIP-44
 * encrypted to the account's own key, and never logged. iOS twin:
 * `NWCBackupService`.
 */
@Singleton
class NwcBackupService @Inject constructor(
    private val configStore: ConfigStore,
    private val nostrService: NostrService,
    private val amberSignerService: AmberSignerService,
) {
    data class Saved(val uri: String, val savedAt: Long) {
        /** The wallet string is a spending secret: never in a log or crash report. */
        override fun toString(): String = "Saved(uri=<redacted>, savedAt=$savedAt)"
    }

    /**
     * The wallet saved on the active account, or null when there is none, it
     * was removed, or this device can't decrypt it (no key, signer refused).
     */
    suspend fun fetchSaved(): Saved? {
        val me = nostrService.activeHexPubkey
        if (me.isEmpty()) return null
        val config = configStore.config.value
        val alsoAsk = config.writeRelays + config.readRelays + nostrService.outboxRelays.value[me].orEmpty()
        val event = nostrService.lookupNewestReplaceable(NwcBackup.KIND, me, alsoAsk, dTag = NwcBackup.D_TAG).event
            ?: return null
        if (!NwcBackup.isBackup(event.kind, event.tags) || NwcBackup.isCleared(event.content, event.tags)) return null
        val plaintext = decryptFromSelf(event.content, me) ?: return null
        val uri = NwcBackup.walletString(plaintext) ?: return null
        return Saved(uri, event.createdAt)
    }

    /** Publishes [uri] encrypted to the active account's own key. Null on success, else why not. */
    suspend fun save(uri: String): String? {
        val plaintext = NwcBackup.plaintextForSaving(uri) ?: return "That isn't a nostr+walletconnect:// link."
        val me = nostrService.activeHexPubkey
        if (me.isEmpty()) return NO_KEY
        val encrypted = encryptToSelf(plaintext, me) ?: return "Couldn't encrypt the wallet. Nothing was saved."
        // Never publish anything that is not ciphertext.
        if (!NwcBackup.isCiphertext(encrypted)) return "Couldn't encrypt the wallet. Nothing was saved."
        return publish(encrypted, NwcBackup.TAGS)
    }

    /** Takes the saved wallet off the account: same slot, empty content. */
    suspend fun clear(): String? = publish("", NwcBackup.CLEARED_TAGS)

    private suspend fun publish(content: String, tags: List<List<String>>): String? {
        val event = try {
            nostrService.signEventAsync(kind = NwcBackup.KIND, content = content, tags = tags)
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            null
        } ?: return "Couldn't sign with this account."
        nostrService.postEvent(event)
        return null
    }

    // ── NIP-44 to self: local key, Amber, or the account's bunker ──

    private suspend fun encryptToSelf(plaintext: String, me: String): String? = try {
        when (configStore.config.value.activeSigningMode()) {
            "amber" -> amberSignerService.nip44Encrypt(plaintext, me)
            "nip46" -> if (bunkerReady(me)) NIP46Service.nip44Encrypt(me, plaintext) else null
            else -> nostrService.resolveSecretKey(forceOwner = false)?.let { sk ->
                withContext(Dispatchers.Default) { HavenBridge.encryptNIP44(plaintext, me, sk) }
            }
        }
    } catch (e: CancellationException) {
        throw e
    } catch (_: Exception) {
        null
    }

    private suspend fun decryptFromSelf(ciphertext: String, me: String): String? = try {
        when (configStore.config.value.activeSigningMode()) {
            // Silent only: opening the wallet screen must not pop Amber's
            // approval screen each time. Without a standing grant, no offer.
            "amber" -> amberSignerService.nip44Decrypt(ciphertext, me, silentOnly = true)
            "nip46" -> if (bunkerReady(me)) NIP46Service.nip44Decrypt(me, ciphertext) else null
            else -> nostrService.resolveSecretKey(forceOwner = false)?.let { sk ->
                withContext(Dispatchers.Default) { HavenBridge.decryptNIP44(ciphertext, me, sk) }
            }
        }
    } catch (e: CancellationException) {
        throw e
    } catch (_: Exception) {
        null
    }

    /** The active account's bunker is connected, connecting it if needed (as DMs do). */
    private suspend fun bunkerReady(me: String): Boolean {
        if (NIP46Service.isConnected.value && NIP46Service.connectedPubkey == me) return true
        val config = configStore.config.value
        val bunker = config.bunkerConfig(config.activeOrOwnerNpub()) ?: return false
        return NIP46Service.connectForAccount(bunker, me) != null
    }

    private companion object {
        const val NO_KEY = "This account has no key on this device to encrypt with."
    }
}
