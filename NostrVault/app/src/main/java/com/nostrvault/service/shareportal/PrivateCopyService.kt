package com.nostrvault.service.shareportal

import android.content.Context
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.model.PostingAccount
import com.nostrvault.relay.HavenBridge
import com.nostrvault.relay.RelayForegroundService
import com.nostrvault.service.AmberSignerService
import com.nostrvault.service.BlossomService
import com.nostrvault.service.NIP46Service
import com.nostrvault.service.NostrEvent
import com.nostrvault.service.NostrService
import com.nostrvault.service.VaultSocket
import com.nostrvault.service.resolveSecretKey
import com.nostrvault.service.saveToLocalRelay
import com.nostrvault.service.shareportal.handlers.PrivateCopyRecord
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.util.UUID
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Keeps a private copy (see [PrivateCopyRecord]): seals the file on this
 * device, puts the sealed blob in this device's vault only (its Blossom, no
 * mirrors, no outside server), and keeps the key in a kind 30078 record,
 * NIP-44 encrypted to the account's own key, sent only to the vault's
 * auth-gated `/private` endpoint (where drafts live). Lists, opens and
 * deletes them again. Twin: PrivateCopyService.swift.
 */
@Singleton
class PrivateCopyService @Inject constructor(
    @ApplicationContext private val context: Context,
    private val configStore: ConfigStore,
    private val nostrService: NostrService,
    private val blossomService: BlossomService,
    private val amberSignerService: AmberSignerService,
) {
    /** One copy in the list. [record] is null until its record was decrypted. */
    data class Entry(val id: String, val event: NostrEvent, val record: PrivateCopyRecord.Record?)

    /** Null on success, else why not. */
    suspend fun save(
        plain: ByteArray,
        name: String,
        mime: String,
        source: String?,
        title: String?,
        lock: PostingAccount.Lock,
    ): String? {
        if (plain.size > PrivateCopyRecord.MAX_BYTES) return TOO_BIG
        val privateUrl = privateUrl() ?: return NO_VAULT
        if (lock.hex.isEmpty() || nostrService.activeHexPubkey != lock.hex) return ACCOUNT_CHANGED
        val sealed = withContext(Dispatchers.Default) { PrivateCopyRecord.seal(plain) }
        // The sealed bytes only, and only to this device's vault.
        val stored = withContext(Dispatchers.IO) {
            blossomService.saveToLocalRelay(sealed.blob, sealed.x, "application/octet-stream")
        }
        if (!stored) return "Your vault didn't take the file. Nothing was saved."
        val record = PrivateCopyRecord.Record(
            name = name, mime = mime, size = plain.size, x = sealed.x, ox = sealed.ox,
            key = sealed.key, nonce = sealed.nonce, source = source, title = title,
            savedAt = System.currentTimeMillis() / 1000,
        )
        val encrypted = encryptToSelf(PrivateCopyRecord.encode(record), lock.hex)
            ?: return dropBlob(sealed.x, "Couldn't encrypt the key. Nothing was saved.")
        // Never publish anything that is not ciphertext.
        if (!PrivateCopyRecord.isCiphertext(encrypted)) return dropBlob(sealed.x, "Couldn't encrypt the key. Nothing was saved.")
        if (nostrService.activeHexPubkey != lock.hex) return dropBlob(sealed.x, ACCOUNT_CHANGED)
        val id = UUID.randomUUID().toString()
        val event = sign(encrypted, PrivateCopyRecord.tags(id), lock) ?: return dropBlob(sealed.x, "Couldn't sign with this account.")
        val sent = VaultSocket.publish(privateUrl, event, { signAuth(privateUrl, it) })
        return if (sent) null else dropBlob(sealed.x, "Your vault didn't take the record. Nothing was saved.")
    }

    /** This account's copies on the vault, newest first, cleared ones left out. Null when the vault didn't answer. */
    suspend fun list(): List<NostrEvent>? {
        val url = privateUrl() ?: return null
        val hex = configStore.activeAccountHexPubkey.value.ifEmpty { return null }
        val filter = "{\"kinds\":[${PrivateCopyRecord.KIND}],\"authors\":[\"$hex\"]}"
        val events = runCatching { VaultSocket.query(url, filter, { signAuth(url, it) }) }.getOrNull() ?: return null
        return events
            .filter { it.pubkey == hex && PrivateCopyRecord.id(it.kind, it.tags) != null }
            // Newest version of each slot only.
            .groupBy { PrivateCopyRecord.id(it.kind, it.tags) }
            .mapNotNull { (_, versions) -> versions.maxByOrNull { it.createdAt } }
            .filterNot { PrivateCopyRecord.isCleared(it.content, it.tags) }
            .sortedByDescending { it.createdAt }
    }

    /** Whether reading records would ask a remote signer (bunker) or Amber's approval screen. */
    fun readsNeedATap(): Boolean = configStore.config.value.activeSigningMode() in setOf("nip46", "amber")

    /** The record in [event], decrypted with the active account. [silentOnly]: Amber without its approval screen. */
    suspend fun read(event: NostrEvent, silentOnly: Boolean): PrivateCopyRecord.Record? {
        if (nostrService.activeHexPubkey != event.pubkey) return null
        if (silentOnly && configStore.config.value.activeSigningMode() == "nip46") return null
        val plain = decryptFromSelf(event.content, event.pubkey, silentOnly) ?: return null
        return PrivateCopyRecord.decode(plain)
    }

    /**
     * The file back, written where the app's FileProvider shares from
     * (cache/exports/private-copies/), for a view or share intent. Null when
     * the blob is gone from this vault or doesn't open with the record.
     */
    suspend fun open(record: PrivateCopyRecord.Record): File? = withContext(Dispatchers.IO) {
        val blob = localBlob(record.x)?.takeIf { it.length() <= PrivateCopyRecord.MAX_BYTES + 16L }?.readBytes()
            ?: return@withContext null
        val plain = runCatching { PrivateCopyRecord.open(blob, record) }.getOrNull() ?: return@withContext null
        val dir = File(context.cacheDir, "exports/private-copies").apply { deleteRecursively(); mkdirs() }
        File(dir, record.name).apply { writeBytes(plain) }
    }

    /** Takes [event]'s copy off: the record slot emptied on /private, the sealed blob deleted. Null on success. */
    suspend fun delete(event: NostrEvent, record: PrivateCopyRecord.Record?, lock: PostingAccount.Lock): String? {
        val id = PrivateCopyRecord.id(event.kind, event.tags) ?: return "That isn't a private copy."
        val url = privateUrl() ?: return NO_VAULT
        if (lock.hex.isEmpty() || nostrService.activeHexPubkey != lock.hex || event.pubkey != lock.hex) return ACCOUNT_CHANGED
        val cleared = sign("", PrivateCopyRecord.clearedTags(id), lock) ?: return "Couldn't sign with this account."
        if (!VaultSocket.publish(url, cleared, { signAuth(url, it) })) return "Your vault didn't answer. Nothing was deleted."
        record?.let { withContext(Dispatchers.IO) { blossomService.deleteFromLocal(it.x) } }
        return null
    }

    // ── Vault ──

    /** The vault's /private endpoint; null with an outside relay (no /private there) or a relay not running. */
    private fun privateUrl(): String? {
        val config = configStore.config.value
        if (config.useExternalRelay || !RelayForegroundService.readyForConnections.value) return null
        return config.localRelayURL("private")
    }

    /** The sealed blob in the vault's Blossom folder (named by hash, with or without an extension). */
    private fun localBlob(sha256: String): File? {
        val config = configStore.config.value
        val dir = config.relayDataDir?.let { File(it, config.blossomPath) } ?: return null
        File(dir, sha256).takeIf { it.isFile }?.let { return it }
        return dir.listFiles { f -> f.isFile && f.nameWithoutExtension == sha256 && f.extension != "corrupt" }?.firstOrNull()
    }

    private suspend fun dropBlob(sha256: String, message: String): String {
        withContext(Dispatchers.IO) { blossomService.deleteFromLocal(sha256) }
        return message
    }

    /** /private asks for NIP-42 AUTH, signed by the owner as DraftService does. */
    private suspend fun signAuth(url: String, challenge: String): NostrEvent? = runCatching {
        nostrService.signEventAsync(
            kind = 22242,
            content = "",
            tags = listOf(listOf("relay", url), listOf("challenge", challenge)),
            forceOwner = true,
        )
    }.getOrNull()

    private suspend fun sign(content: String, tags: List<List<String>>, lock: PostingAccount.Lock): NostrEvent? = try {
        // A literal kind: UserListSignGuardTest flags a signer whose kind is a variable.
        nostrService.signEventAsync(kind = 30078, content = content, tags = tags, lockedTo = lock)
            ?.also { nostrService.requireStillPostingAs(lock, it.pubkey) }
    } catch (e: CancellationException) {
        throw e
    } catch (_: Exception) {
        null
    }

    // ── NIP-44 to self: local key, Amber, or the account's bunker (as NwcBackupService) ──

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

    private suspend fun bunkerReady(me: String): Boolean {
        if (NIP46Service.isConnected.value && NIP46Service.connectedPubkey == me) return true
        val config = configStore.config.value
        val bunker = config.bunkerConfig(config.activeOrOwnerNpub()) ?: return false
        return NIP46Service.connectForAccount(bunker, me) != null
    }

    companion object {
        const val ACCOUNT_CHANGED = "The account changed. Nothing was saved; try again."
        const val NO_VAULT = "Your vault isn't running on this device, so there's nowhere private to keep it."
        const val TOO_BIG = "Too big for a private copy (100 MB at most)."
    }
}
