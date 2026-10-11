package com.nostrvault.service

import android.util.Log
import com.nostrvault.BuildConfig
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.serialization.json.*
import java.io.File
import com.nostrvault.service.DMService.Companion.CACHE_SAVE_DEBOUNCE_MS
import com.nostrvault.service.DMService.Companion.TAG

    // ══════════════════════════════════════════════════════════════════
    // Persistence
    // ══════════════════════════════════════════════════════════════════

    internal fun DMService.loadCachedConversations() {
        val key = currentCacheKey()
        loadedCacheKey = key
        scope.launch(Dispatchers.IO) {
            try {
                deleteOldKeyCaches()
                if (key == null) return@launch // no account: nothing to load
                val dir = configStore.config.value.appSupportDir ?: run { if (BuildConfig.DEBUG) Log.w(TAG, "DBG: loadCache appSupportDir NULL"); return@launch }
                val file = File(dir, "dm_cache_$key.json")
                if (!file.exists()) { if (BuildConfig.DEBUG) Log.w(TAG, "DBG: loadCache no file key=$key"); return@launch }

                val content = file.readText()
                val rawConvos = json.decodeFromString<List<DMConversation>>(content)

                // One-time repair: earlier builds decrypted inbound NIP-17 gift
                // wraps with a SINGLE nip44 decrypt and stored the still-encrypted
                // seal content (NIP-44 v2 ciphertext) as the message body. Drop
                // those corrupted entries and DO NOT seed their ids, so the live/
                // catch-up subscriptions re-deliver them and the two-layer unwrap
                // decrypts them correctly. NIP-04 messages were never affected.
                var repaired = 0
                val convos = rawConvos.mapNotNull { conv ->
                    val good = conv.messages.filterNot { msg ->
                        (!msg.isNIP04 && looksLikeNip44Ciphertext(msg.content)).also { if (it) repaired++ }
                    }
                    if (good.isEmpty()) null else conv.copy(messages = good)
                }
                if (BuildConfig.DEBUG) Log.w(TAG, "DBG: loadCache key=$key convos=${convos.size} msgs=${convos.sumOf { it.messages.size }} repairedDropped=$repaired")

                // Seed dedup set with the messages we KEPT (the dropped ones must be
                // allowed to re-decrypt).
                for (conv in convos) {
                    for (msg in conv.messages) {
                        seenGiftWrapIds.add(msg.id)
                    }
                }

                withContext(Dispatchers.Main.immediate) {
                    // A switch while this was reading: the file belongs to the old account.
                    if (loadedCacheKey == key) _conversations.value = convos
                }

                if (repaired > 0) {
                    // Persist the cleaned cache and pull the dropped wraps back so
                    // they decrypt with the fixed path.
                    writeCacheNow()
                    fetchFromExternalRelays()
                }
            } catch (e: Exception) {
                Log.w(TAG, "DM cache load failed: ${e.message}")
            }
        }
    }

    /**
     * Debounced cache save. addMessageToConversation() fires this on every
     * message add; during a backlog burst that would otherwise serialize the
     * ENTIRE conversation history to disk N times. Coalesce into a single write
     * ~500 ms after the burst settles. Cancelling the prior job is safe — the
     * write always serializes the latest _conversations snapshot.
     */
    internal fun DMService.saveCachedConversations() {
        saveJob?.cancel()
        saveJob = scope.launch(Dispatchers.IO) {
            delay(CACHE_SAVE_DEBOUNCE_MS)
            writeCacheNow()
        }
    }

    private fun DMService.writeCacheNow() {
        val key = loadedCacheKey ?: return
        writeCache(key, _conversations.value)
    }

    internal fun DMService.writeCache(key: String, conversations: List<DMConversation>) {
        try {
            val dir = configStore.config.value.appSupportDir ?: return
            val dirFile = File(dir)
            if (!dirFile.exists()) dirFile.mkdirs()

            val file = File(dir, "dm_cache_$key.json")
            file.writeText(json.encodeToString(
                kotlinx.serialization.builtins.ListSerializer(DMConversation.serializer()),
                conversations
            ))
        } catch (e: Exception) {
            Log.w(TAG, "DM cache save failed: ${e.message}")
        }
    }

    /**
     * The full hex pubkey of the active account, or null with none (then
     * nothing is cached). The old key was the npub's first 12 characters
     * ("npub1" plus 7), which two accounts could share.
     */
    private fun DMService.currentCacheKey(): String? =
        configStore.activeAccountHexPubkey.value.ifEmpty { null }

    /**
     * Deletes caches written under the old keys (truncated npub or hex,
     * "default"). Some hold another account's DMs (written across a switch),
     * and none is read again; the inbox refetches from the relays, so nothing
     * is lost.
     */
    private fun DMService.deleteOldKeyCaches() {
        val dir = configStore.config.value.appSupportDir ?: return
        File(dir).listFiles { f -> DMCacheFiles.isOldKeyCache(f.name) }?.forEach { it.delete() }
    }
