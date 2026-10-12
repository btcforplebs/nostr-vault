package com.nostrvault.service

import android.util.Log
import com.nostrvault.BuildConfig
import com.nostrvault.relay.HavenBridge
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.sync.withPermit
import kotlinx.serialization.json.*
import com.nostrvault.service.NostrService.Companion.TAG

    // ══════════════════════════════════════════════════════════════════
    // Event signing
    // ══════════════════════════════════════════════════════════════════

    /**
     * Sign in the active signing mode (local key, NIP-46 bunker or Amber) and
     * publish, off the caller's thread. Every event goes through signEventAsync:
     * a separate local-only signer let reactions, reposts, lists and deletes skip
     * the bunker — silently doing nothing for bunker-only accounts.
     */
    fun NostrService.signAndPost(
        kind: Int,
        content: String,
        tags: List<List<String>> = emptyList(),
        forceOwner: Boolean = false,
    ) {
        scope.launch(Dispatchers.IO) {
            val event = try {
                signEventAsync(kind = kind, content = content, tags = tags, forceOwner = forceOwner)
            } catch (e: Exception) {
                Log.e(TAG, "signAndPost: kind $kind not signed: ${e.message}")
                null
            }
            event?.let { postEvent(it) }
        }
    }

    internal suspend fun NostrService.signEventRouted(
        kind: Int,
        content: String,
        tags: List<List<String>>,
        forceOwner: Boolean,
        silentOnly: Boolean = false,
    ): NostrEvent? = withContext(Dispatchers.IO) {
        val signingMode = configStore.config.value.activeSigningMode()
        if (BuildConfig.DEBUG) Log.d(TAG, "signEventAsync: kind=$kind signingMode=$signingMode bridgeLoaded=${com.nostrvault.relay.HavenBridge.isLoaded}")

        // Owner-forced events while another account is active go to the
        // OWNER's own signer (#168 parity), never the active account's.
        val route = SignerRouting.route(configStore.config.value, forceOwner, ownerHexPubkey, activeHexPubkey)
        when (route) {
            is SignerRoute.Unavailable -> throw IllegalStateException(route.reason)
            is SignerRoute.BunkerSession -> {
                val eventJson = EventPublisher.buildUnsignedEvent(
                    kind = kind, content = content,
                    tags = EventPublisher.appendClientTag(tags, kind), pubkey = ownerHexPubkey,
                )
                val signed = gatedIfBackground(kind) { NIP46Service.signEventWith(route.signerPubkey, eventJson) }
                    ?: throw IllegalStateException("The owner's signer is not connected")
                return@withContext requireSignedAsRequested(eventJson, parseSignedEvent(signed), "NIP-46 signer (owner)")
            }
            is SignerRoute.Amber -> if (route.asOwner) {
                val eventJson = EventPublisher.buildUnsignedEvent(
                    kind = kind, content = content,
                    tags = EventPublisher.appendClientTag(tags, kind), pubkey = ownerHexPubkey,
                )
                val signed = amberSignerService.signEvent(eventJson, asOwner = true, silentOnly = silentOnly)
                    ?: throw IllegalStateException("Amber signer failed")
                return@withContext requireSignedAsRequested(eventJson, parseSignedEvent(signed), "Amber (owner)")
            }
            is SignerRoute.Local -> if (route.asOwner && signingMode != "local") {
                return@withContext signLocally(kind, content, tags, forceOwner = true)
            }
            SignerRoute.ActiveBunker -> Unit
        }

        when (signingMode) {
            "nip46" -> {
                val finalTags = EventPublisher.appendClientTag(tags, kind)
                val eventJson = EventPublisher.buildUnsignedEvent(
                    kind = kind,
                    content = content,
                    tags = finalTags,
                    pubkey = if (forceOwner) ownerHexPubkey else activeHexPubkey,
                )
                ensureBunkerConnected()
                val signed = gatedIfBackground(kind) {
                    NIP46Service.signEvent(eventJson, userInitiated = kind in NIP46Service.userActionKinds)
                }
                    ?: throw IllegalStateException("NIP-46 remote signer failed")
                return@withContext requireSignedAsRequested(eventJson, parseSignedEvent(signed), "NIP-46 signer")
            }
            "amber" -> {
                val finalTags = EventPublisher.appendClientTag(tags, kind)
                val eventJson = EventPublisher.buildUnsignedEvent(
                    kind = kind,
                    content = content,
                    tags = finalTags,
                    pubkey = if (forceOwner) ownerHexPubkey else activeHexPubkey,
                )
                val signed = amberSignerService.signEvent(eventJson, silentOnly = silentOnly)
                    ?: throw IllegalStateException("Amber signer failed")
                return@withContext requireSignedAsRequested(eventJson, parseSignedEvent(signed), "Amber")
            }
            else -> {
                // Local signing
                signLocally(kind, content, tags, forceOwner)
            }
        }
    }

    /** Signs with the local key of the owner ([forceOwner]) or the active account. */
    internal fun NostrService.signLocally(kind: Int, content: String, tags: List<List<String>>, forceOwner: Boolean): NostrEvent {
        if (!com.nostrvault.relay.HavenBridge.isLoaded) {
            throw IllegalStateException("Native library not loaded")
        }
        val secretKey = resolveSecretKey(forceOwner)
            ?: throw IllegalStateException("No signing key available (ownerHexKey=${configStore.config.value.ownerHexKey != null}, ownerNpub=${configStore.config.value.ownerNpub.take(8)})")
        val finalTags = EventPublisher.appendClientTag(tags, kind)
        val pubkey = if (forceOwner) ownerHexPubkey else activeHexPubkey
        val eventJson = EventPublisher.buildUnsignedEvent(
            kind = kind, content = content, tags = finalTags, pubkey = pubkey,
        )

        // Apply NIP-13 proof of work if enabled for this event kind
        val powDifficulty = powPreferences.difficultyForKind(kind)
        val signed = if (powDifficulty > 0) {
            EventPublisher.mineAndSignWithGoBackend(eventJson, secretKey, powDifficulty)
                ?: EventPublisher.signWithGoBackend(eventJson, secretKey) // fallback
        } else {
            EventPublisher.signWithGoBackend(eventJson, secretKey)
        }
            ?: throw IllegalStateException("Go signEvent failed (pubkey=${pubkey.take(8)}, keyLen=${secretKey.length})")
        return parseSignedEvent(signed)
            ?: throw IllegalStateException("Failed to parse signed event")
    }

    /**
     * Sign with NIP-13 proof of work.
     */
    fun NostrService.mineAndSignEvent(
        kind: Int,
        content: String,
        tags: List<List<String>> = emptyList(),
        difficulty: Int = 0,
        maxAttempts: Int = 10_000_000,
        password: String? = null,
        forceOwner: Boolean = false,
    ): NostrEvent? {
        val finalTags = EventPublisher.appendClientTag(tags, kind)
        val secretKey = resolveSecretKey(forceOwner) ?: return null

        val eventJson = EventPublisher.buildUnsignedEvent(
            kind = kind,
            content = content,
            tags = finalTags,
            pubkey = if (forceOwner) ownerHexPubkey else activeHexPubkey,
        )

        val signed = EventPublisher.mineAndSignWithGoBackend(
            eventJson, secretKey, difficulty, maxAttempts
        ) ?: return null
        return parseSignedEvent(signed)
    }

    internal fun NostrService.resolveSecretKey(forceOwner: Boolean): String? {
        val config = configStore.config.value
        return if (forceOwner || config.activeAccountNpub == null) {
            // Owner key — try config hex key first, then NIP-49 decrypt, then credential store fallback
            config.ownerHexKey
                ?: config.ownerNcryptsec?.let { ncryptsec ->
                    val npub = config.ownerNpub.ifEmpty { return@let null }
                    val password = credentialStore.getKeychainPassword(npub) ?: return@let null
                    NIP49Service.decrypt(ncryptsec, password)
                }
                ?: credentialStore.getNsec(ownerHexPubkey.ifEmpty { return null })
        } else {
            // Non-owner account key: stored hex key, or nsec keyed by hex pubkey.
            val npub = config.activeAccountNpub!!
            credentialStore.getCredentialHexKey(npub)
                ?: com.nostrvault.relay.HavenBridge.decodeNpub(npub)?.let { credentialStore.getNsec(it) }
        }
    }

    /**
     * The Go bunker session only exists in this process: after a restart nothing
     * reconnected it until the user switched accounts, so every signature failed.
     * Reconnect with the active account's stored bunker config, and refuse a
     * signer that answers for a different account.
     */
    private suspend fun NostrService.ensureBunkerConnected() {
        val cfg = configStore.config.value
        val bunker = cfg.bunkerConfig(cfg.activeOrOwnerNpub())
            ?: throw IllegalStateException("No bunker configured for this account")
        // The connect/ensure decision runs under NIP46Service's lock and checks
        // the signer's key; a wrong-key signer is dropped, not kept.
        NIP46Service.connectForAccount(bunker, activeHexPubkey)
            ?: throw IllegalStateException(NIP46Service.lastError.value ?: "Could not reach the bunker")
    }

    private suspend fun <T> NostrService.gatedIfBackground(kind: Int, block: suspend () -> T): T =
        if (kind in backgroundSignerKinds) backgroundSignerGate.withPermit { block() } else block()

    /**
     * An external signer's answer is only accepted if it is the event we asked
     * for, under the pubkey we asked for. A valid signature proves nothing about
     * identity: a signer paired to another account signs happily as that account.
     */
    private fun NostrService.requireSignedAsRequested(requestJson: String, signed: NostrEvent?, signer: String): NostrEvent {
        if (signed == null) throw IllegalStateException("$signer returned an unreadable event")
        val req = this.json.parseToJsonElement(requestJson).jsonObject
        val wantPubkey = req["pubkey"]?.jsonPrimitive?.contentOrNull
        val wantTags = req["tags"]?.jsonArray?.map { t -> t.jsonArray.map { it.jsonPrimitive.contentOrNull ?: "" } }
        if (signed.pubkey != wantPubkey) {
            throw IllegalStateException("$signer signed as ${signed.pubkey.take(8)}…, not this account (${wantPubkey?.take(8)}…)")
        }
        if (signed.kind != req["kind"]?.jsonPrimitive?.intOrNull ||
            signed.createdAt != req["created_at"]?.jsonPrimitive?.longOrNull ||
            signed.content != req["content"]?.jsonPrimitive?.contentOrNull ||
            signed.tags != wantTags
        ) {
            throw IllegalStateException("$signer changed the event it was asked to sign")
        }
        return signed
    }

    internal fun NostrService.parseSignedEvent(json: String): NostrEvent? {
        return try {
            val obj = this.json.parseToJsonElement(json).jsonObject
            NostrEvent(
                id = obj["id"]?.jsonPrimitive?.contentOrNull ?: return null,
                pubkey = obj["pubkey"]?.jsonPrimitive?.contentOrNull ?: return null,
                createdAt = obj["created_at"]?.jsonPrimitive?.longOrNull ?: return null,
                kind = obj["kind"]?.jsonPrimitive?.intOrNull ?: return null,
                tags = obj["tags"]?.jsonArray?.map { tagArr ->
                    tagArr.jsonArray.map { it.jsonPrimitive.contentOrNull ?: "" }
                } ?: emptyList(),
                content = obj["content"]?.jsonPrimitive?.contentOrNull ?: "",
                sig = obj["sig"]?.jsonPrimitive?.contentOrNull ?: return null,
            )
        } catch (e: Exception) {
            Log.w(TAG, "Failed to parse signed event: ${e.message}")
            null
        }
    }
