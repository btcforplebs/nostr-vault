package com.nostrvault.service

import android.util.Log
import com.nostrvault.data.model.MuteList
import com.nostrvault.relay.HavenBridge
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import com.nostrvault.service.NostrService.Companion.PROFILE_RELAYS
import com.nostrvault.service.NostrService.Companion.TAG

    // ══════════════════════════════════════════════════════════════════
    // Mute list (kind 10000)
    // ══════════════════════════════════════════════════════════════════

    /**
     * Loads the active account's mute list at launch and on each switch.
     * Nothing asked for it before: it was only applied if it happened to
     * arrive with other events, so after a login people blocked in another
     * client still showed.
     */
    internal fun NostrService.observeMuteList() {
        scope.launch {
            configStore.activeAccountHexPubkey
                .filter { it.isNotEmpty() }
                .distinctUntilChanged()
                .collectLatest { hex ->
                    try {
                        syncMuteList(hex)
                    } catch (e: CancellationException) {
                        throw e
                    } catch (e: Exception) {
                        Log.w(TAG, "Mute list sync failed: ${e.message}")
                    }
                }
        }
    }

    /** The newest kind 10000 for [hex] from its own relays, the read relays and the profile relays. */
    internal suspend fun NostrService.syncMuteList(hex: String) {
        val config = configStore.config.value
        val ask = (relayLists.value[hex].orEmpty() + config.readRelays + PROFILE_RELAYS).distinct()
        val event = lookupNewestReplaceable(10000, hex, ask).event ?: return
        applyMuteList(hex, event.tags, event.content, event.createdAt)
    }

    /**
     * Applies [hex]'s mute list, if it is not older than the one applied: the
     * public "p" entries, and the private ones when this device can open the
     * encrypted content. When it can't (a read-only account, a signer that
     * isn't connected), the private entries already known are kept.
     */
    internal suspend fun NostrService.applyMuteList(hex: String, tags: List<List<String>>, content: String, createdAt: Long) {
        val key = "10000:$hex"
        val seen = replaceableNewest[key]
        if (seen != null && createdAt < seen) return
        replaceableNewest.merge(key, createdAt) { a, b -> maxOf(a, b) }
        val npub = hexToNpub(hex) ?: return

        val entries = MuteList.entries(tags, content) { ciphertext, nip04 -> decryptOwnList(hex, ciphertext, nip04) }
        // A newer list landed while this one was being opened.
        if (replaceableNewest[key] != createdAt) return
        val public = entries.public.mapNotNull { hexToNpub(it) }
        val private = entries.private?.mapNotNull { hexToNpub(it) }
        configStore.update { config ->
            val isOwner = npub == config.ownerNpub
            config.copy(
                blockedNpubs = if (isOwner) public else config.blockedNpubs,
                blockedNpubsPerAccount = config.blockedNpubsPerAccount + (npub to public),
                privateBlockedNpubsPerAccount = if (private == null) config.privateBlockedNpubsPerAccount
                    else config.privateBlockedNpubsPerAccount + (npub to private),
            )
        }
    }

    /**
     * [hex]'s own encrypted list content, opened with its key, or null when
     * this device can't. Amber is asked silently only, so a launch never
     * raises its approval screen; a bunker only when already connected.
     */
    private suspend fun NostrService.decryptOwnList(hex: String, ciphertext: String, nip04: Boolean): String? {
        val config = configStore.config.value
        val npub = hexToNpub(hex) ?: return null
        val isActive = hex == activeHexPubkey
        return when (config.effectiveSigningMode(npub)) {
            "amber" -> if (!isActive) null
                else if (nip04) amberSignerService.nip04Decrypt(ciphertext, hex, silentOnly = true)
                else amberSignerService.nip44Decrypt(ciphertext, hex, silentOnly = true)
            "nip46" -> if (!isActive || !NIP46Service.isConnected.value || NIP46Service.connectedPubkey != hex) null
                else if (nip04) NIP46Service.nip04Decrypt(hex, ciphertext)
                else NIP46Service.nip44Decrypt(hex, ciphertext)
            else -> {
                val forceOwner = when {
                    isActive -> false
                    hex == ownerHexPubkey -> true
                    else -> return null
                }
                val sk = resolveSecretKey(forceOwner) ?: return null
                withContext(Dispatchers.Default) {
                    if (nip04) HavenBridge.decryptNIP04(ciphertext, hex, sk) else HavenBridge.decryptNIP44(ciphertext, hex, sk)
                }
            }
        }
    }
