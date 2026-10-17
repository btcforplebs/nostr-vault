package com.nostrvault.service

import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.model.NwcBackup
import com.nostrvault.data.model.PostingAccount
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
    /**
     * What [account]'s slot holds. With [askSigner] false the signer is not
     * asked to approve anything: a bunker is not asked at all, and Amber only
     * through its silent path. Opening the wallet screen must not send the
     * secret to a signer, so such a slot shows as [NwcBackup.Status.NeedsSigner]
     * until the user taps to load it.
     */
    suspend fun status(account: String, askSigner: Boolean): NwcBackup.Status {
        if (account.isEmpty()) return NwcBackup.Status.Unknown
        val config = configStore.config.value
        val alsoAsk = config.writeRelays + config.readRelays + nostrService.outboxRelays.value[account].orEmpty()
        val lookup = nostrService.lookupNewestReplaceable(NwcBackup.KIND, account, alsoAsk, dTag = NwcBackup.D_TAG)
        val event = lookup.event?.takeIf { NwcBackup.isBackup(it.kind, it.tags) }
            ?: return NwcBackup.status(null, lookup.answered > 0, NwcBackup.Read.NotTried)
        val slot = NwcBackup.Slot(event.content, event.tags, event.createdAt)
        if (NwcBackup.isCleared(event.content, event.tags)) return NwcBackup.status(slot, true, NwcBackup.Read.NotTried)
        // Only the account that is still active can decrypt its own slot.
        if (nostrService.activeHexPubkey != account) return NwcBackup.Status.Unknown
        val mode = configStore.config.value.activeSigningMode()
        val read = when {
            mode == "nip46" && !askSigner -> NwcBackup.Read.NotTried
            else -> decryptFromSelf(event.content, account, silentOnly = !askSigner)
                ?.let { NwcBackup.Read.Plaintext(it) }
                // Amber without a standing grant: not a failure, it just needs the tap.
                ?: if (mode == "amber" && !askSigner) NwcBackup.Read.NotTried else NwcBackup.Read.Failed
        }
        return NwcBackup.status(slot, true, read)
    }

    /**
     * Publishes [uri] encrypted to [lock]'s own key. Null on success, else why
     * not. Refuses if the active account is no longer [lock]'s at any step.
     */
    suspend fun save(uri: String, lock: PostingAccount.Lock): String? {
        val plaintext = NwcBackup.plaintextForSaving(uri) ?: return "That isn't a nostr+walletconnect:// link."
        if (lock.hex.isEmpty() || nostrService.activeHexPubkey != lock.hex) return ACCOUNT_CHANGED
        val mode = configStore.config.value.activeSigningMode()
        if (mode != "amber" && mode != "nip46" && nostrService.resolveSecretKey(forceOwner = false) == null) return NO_KEY
        val encrypted = encryptToSelf(plaintext, lock.hex) ?: return "Couldn't encrypt the wallet. Nothing was saved."
        // Never publish anything that is not ciphertext.
        if (!NwcBackup.isCiphertext(encrypted)) return "Couldn't encrypt the wallet. Nothing was saved."
        // Encrypted with whichever key was active: still the locked account?
        if (nostrService.activeHexPubkey != lock.hex) return ACCOUNT_CHANGED
        return publish(encrypted, NwcBackup.TAGS, lock)
    }

    /** Takes the saved wallet off [lock]'s account: same slot, empty content. No decryption needed. */
    suspend fun clear(lock: PostingAccount.Lock): String? {
        if (lock.hex.isEmpty() || nostrService.activeHexPubkey != lock.hex) return ACCOUNT_CHANGED
        return publish("", NwcBackup.CLEARED_TAGS, lock)
    }

    private suspend fun publish(content: String, tags: List<List<String>>, lock: PostingAccount.Lock): String? {
        val event = try {
            nostrService.signEventAsync(kind = NwcBackup.KIND, content = content, tags = tags, lockedTo = lock)
                ?.also { nostrService.requireStillPostingAs(lock, it.pubkey) }
        } catch (e: CancellationException) {
            throw e
        } catch (_: PostingAccount.AccountChangedException) {
            return ACCOUNT_CHANGED
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

    private suspend fun decryptFromSelf(ciphertext: String, me: String, silentOnly: Boolean): String? = try {
        when (configStore.config.value.activeSigningMode()) {
            "amber" -> amberSignerService.nip44Decrypt(ciphertext, me, silentOnly = silentOnly)
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
        const val ACCOUNT_CHANGED = "The account changed. Nothing was published; check again."
        const val NO_KEY = "This account has no key on this device to encrypt with."
    }
}
