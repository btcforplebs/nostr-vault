package com.nostrvault.service

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.util.Log
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.relay.HavenBridge
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeoutOrNull
import java.util.UUID
import javax.inject.Inject
import javax.inject.Singleton

/**
 * NIP-55 Android Signer Application protocol implementation.
 * Communicates with Amber (or any NIP-55 signer) via intents and content providers.
 *
 * - Intent-based: launches signer Activity, user approves, result returns via ActivityResult
 * - ContentProvider-based: silent background signing after user checks "remember my choice"
 */
@Singleton
class AmberSignerService @Inject constructor(
    @ApplicationContext private val context: Context,
    private val configStore: ConfigStore,
) {
    companion object {
        private const val TAG = "AmberSignerService"
        private const val DEFAULT_PACKAGE = "com.greenart7c3.nostrsigner"
        private const val INTENT_TIMEOUT_MS = 120_000L // 2 minutes for user interaction
    }

    /**
     * Serializes all signer round-trips. Amber funnels signing through a single
     * activity / content-provider and silently drops requests that arrive while
     * another is in flight. Concurrent callers (e.g. mirroring many blobs at
     * once) must queue, or signatures are lost ("Amber ignored it, moved too fast").
     */
    private val signerLock = Mutex()

    /** Set once we've asked Amber for background-signing permission this session.
     *  AtomicBoolean so a concurrent decrypt burst fires only ONE request. */
    private val backgroundPermissionRequested = java.util.concurrent.atomic.AtomicBoolean(false)

    /** Cached after first successful get_public_key call. */
    var cachedPubkey: String? = null
        private set

    /** Amber's package name, updated from the get_public_key response. */
    var signerPackage: String = DEFAULT_PACKAGE
        private set

    init {
        restoreCachedPubkey()
    }

    /** Restore the cached pubkey from config so signing works after app restart. */
    private fun restoreCachedPubkey() {
        if (cachedPubkey != null) return
        val config = configStore.config.value
        if (config.signingMode != "amber") return

        val npub = config.ownerNpub
        val hex = when {
            npub.isEmpty() -> null
            npub.startsWith("npub1") -> HavenBridge.decodeNpub(npub)
            npub.length == 64 && npub.all { it in '0'..'9' || it in 'a'..'f' } -> npub
            else -> null
        }
        if (hex != null) {
            cachedPubkey = hex
            Log.d(TAG, "Restored cachedPubkey from config: ${hex.take(12)}...")
        }
        config.amberSignerPackage.takeIf { it.isNotEmpty() }?.let { signerPackage = it }
    }

    // ══════════════════════════════════════════════════════════════════
    // Detection
    // ══════════════════════════════════════════════════════════════════

    /** Check whether Amber (or any NIP-55 signer) is installed. */
    fun isAmberInstalled(): Boolean {
        return try {
            context.packageManager.getPackageInfo(DEFAULT_PACKAGE, 0)
            true
        } catch (_: PackageManager.NameNotFoundException) {
            // Also try a generic query for nostrsigner: scheme
            val intent = Intent(Intent.ACTION_VIEW, Uri.parse("nostrsigner:"))
            val resolved = context.packageManager.queryIntentActivities(intent, 0)
            resolved.isNotEmpty()
        }
    }

    // ══════════════════════════════════════════════════════════════════
    // Public key
    // ══════════════════════════════════════════════════════════════════

    /** Get the user's public key from the signer. First call also caches the package name. */
    suspend fun getPublicKey(): String? {
        // Try content provider first
        tryContentProvider("GET_PUBLIC_KEY")?.let { result ->
            cachedPubkey = result
            return result
        }

        // Intent fallback
        val requestId = UUID.randomUUID().toString()
        val intent = buildIntent("get_public_key", requestId).apply {
            // Request broad permissions for background signing
            val permsJson = """[{"type":"sign_event"},{"type":"nip04_encrypt"},{"type":"nip04_decrypt"},{"type":"nip44_encrypt"},{"type":"nip44_decrypt"}]"""
            putExtra("permissions", permsJson)
        }

        val result = withTimeoutOrNull(INTENT_TIMEOUT_MS) {
            AmberResultBridge.launchAndAwait(intent, requestId)
        } ?: return null

        if (!result.rejected && result.resultCode == android.app.Activity.RESULT_OK) {
            cachedPubkey = result.pubkey
            result.packageName?.let { signerPackage = it }
            Log.i(TAG, "Got pubkey from Amber: ${result.pubkey?.take(12)}...")
            return result.pubkey
        }

        Log.w(TAG, "Amber get_public_key rejected")
        return null
    }

    // ══════════════════════════════════════════════════════════════════
    // Event signing
    // ══════════════════════════════════════════════════════════════════

    /** Sign an event. Returns the full signed event JSON, or null on failure. */
    suspend fun signEvent(unsignedEventJson: String): String? {
        if (cachedPubkey == null) restoreCachedPubkey()
        val currentUser = cachedPubkey
        if (currentUser == null) {
            Log.e(TAG, "signEvent: cachedPubkey is null, cannot sign (ownerNpub=${configStore.config.value.ownerNpub.take(12)}, bridgeLoaded=${HavenBridge.isLoaded})")
            return null
        }

        // Serialize: concurrent signs race Amber's single activity and get dropped.
        return signerLock.withLock {
            // Try content provider first (silent background signing)
            tryContentProviderSign(unsignedEventJson, currentUser)?.let { return@withLock it }

            // Intent fallback (launches Amber for approval)
            val requestId = UUID.randomUUID().toString()
            val intent = buildIntent("sign_event", requestId).apply {
                data = Uri.parse("nostrsigner:$unsignedEventJson")
                putExtra("current_user", currentUser)
            }

            val result = withTimeoutOrNull(INTENT_TIMEOUT_MS) {
                AmberResultBridge.launchAndAwait(intent, requestId)
            }

            when {
                result == null -> {
                    Log.w(TAG, "Amber sign_event timed out")
                    null
                }
                !result.rejected && result.resultCode == android.app.Activity.RESULT_OK -> result.event
                else -> {
                    Log.w(TAG, "Amber sign_event rejected")
                    null
                }
            }
        }
    }

    // ══════════════════════════════════════════════════════════════════
    // Encryption / decryption
    // ══════════════════════════════════════════════════════════════════

    suspend fun nip04Encrypt(plaintext: String, recipientPubkey: String): String? =
        cryptoOp("nip04_encrypt", "NIP04_ENCRYPT", plaintext, recipientPubkey)

    suspend fun nip04Decrypt(ciphertext: String, senderPubkey: String): String? =
        cryptoOp("nip04_decrypt", "NIP04_DECRYPT", ciphertext, senderPubkey)

    suspend fun nip44Encrypt(plaintext: String, recipientPubkey: String): String? =
        cryptoOp("nip44_encrypt", "NIP44_ENCRYPT", plaintext, recipientPubkey)

    suspend fun nip44Decrypt(ciphertext: String, senderPubkey: String): String? =
        cryptoOp("nip44_decrypt", "NIP44_DECRYPT", ciphertext, senderPubkey)

    /**
     * Force a get_public_key Intent carrying the full permissions list so Amber
     * registers background (ContentProvider) signing access for this app. After
     * the user approves once, decrypt/sign content-resolver queries return
     * results silently — no per-message approval dialog. Amber persists the grant
     * across launches, so this only prompts until granted.
     */
    private suspend fun requestBackgroundPermission(): Boolean = signerLock.withLock {
        val requestId = UUID.randomUUID().toString()
        val intent = buildIntent("get_public_key", requestId).apply {
            val permsJson = """[{"type":"sign_event"},{"type":"nip04_encrypt"},{"type":"nip04_decrypt"},{"type":"nip44_encrypt"},{"type":"nip44_decrypt"},{"type":"decrypt_zap_event"}]"""
            putExtra("permissions", permsJson)
        }
        val result = withTimeoutOrNull(INTENT_TIMEOUT_MS) {
            AmberResultBridge.launchAndAwait(intent, requestId)
        }
        val ok = result != null && !result.rejected &&
            result.resultCode == android.app.Activity.RESULT_OK
        if (ok) result.pubkey?.let { if (it.isNotEmpty()) cachedPubkey = it }
        Log.w(TAG, "DBG: requestBackgroundPermission ok=$ok")
        ok
    }

    // ══════════════════════════════════════════════════════════════════
    // Internal helpers
    // ══════════════════════════════════════════════════════════════════

    private suspend fun cryptoOp(
        intentType: String,
        contentProviderType: String,
        payload: String,
        pubkey: String,
    ): String? {
        // Self-heal like signEvent(): if the pubkey wasn't cached at init (config
        // / bridge not ready), restore it now — otherwise every decrypt silently
        // no-ops (no prompt, no content query) and DMs never decrypt.
        if (cachedPubkey == null) restoreCachedPubkey()
        val currentUser = cachedPubkey ?: run {
            Log.w(TAG, "DBG: cryptoOp $intentType cachedPubkey NULL after restore → null")
            return null
        }

        // Try content provider first (silent, concurrency-safe).
        tryContentProvider(contentProviderType, payload, currentUser, pubkey)?.let {
            Log.w(TAG, "DBG: cryptoOp $intentType via ContentProvider OK len=${it.length}")
            return it
        }

        // ContentProvider missed → Amber likely hasn't granted this app
        // background-signing permission. Request it ONCE per session (one prompt),
        // then retry the silent path so a backlog of DMs doesn't flood the signer
        // with one approval dialog per message.
        if (backgroundPermissionRequested.compareAndSet(false, true)) {
            requestBackgroundPermission()
            tryContentProvider(contentProviderType, payload, currentUser, pubkey)?.let {
                Log.w(TAG, "DBG: cryptoOp $intentType via ContentProvider OK after grant len=${it.length}")
                return it
            }
        }
        Log.w(TAG, "DBG: cryptoOp $intentType ContentProvider miss → Intent fallback")

        // Serialize the Intent fallback: AmberResultBridge has a single
        // activeRequestId, so concurrent crypto Intents clobber each other and
        // all-but-one get dropped (this is why a batch of DMs failed to decrypt).
        return signerLock.withLock {
            // A concurrent requestBackgroundPermission() may have just granted
            // background access while we waited for the lock — prefer the silent
            // path so a whole burst doesn't fall through to per-message prompts.
            tryContentProvider(contentProviderType, payload, currentUser, pubkey)?.let {
                Log.w(TAG, "DBG: cryptoOp $intentType via ContentProvider OK (post-lock) len=${it.length}")
                return@withLock it
            }

            val requestId = UUID.randomUUID().toString()
            val intent = buildIntent(intentType, requestId).apply {
                data = Uri.parse("nostrsigner:$payload")
                putExtra("current_user", currentUser)
                putExtra("pubkey", pubkey)
            }

            val result = withTimeoutOrNull(INTENT_TIMEOUT_MS) {
                AmberResultBridge.launchAndAwait(intent, requestId)
            } ?: run {
                Log.w(TAG, "DBG: cryptoOp $intentType Intent TIMEOUT/null")
                return@withLock null
            }

            // NIP-55 returns encrypt/decrypt output in the "signature" extra
            // (bridge → result.signature), NOT the "result" extra (→ pubkey).
            // Reading result.pubkey was why decrypts returned null despite OK.
            val output = result.signature ?: result.pubkey ?: result.event
            Log.w(TAG, "DBG: cryptoOp $intentType Intent rejected=${result.rejected} code=${result.resultCode} sig=${result.signature?.length} res=${result.pubkey?.length} evt=${result.event?.length}")

            if (!result.rejected && result.resultCode == android.app.Activity.RESULT_OK) {
                output
            } else null
        }
    }

    private fun buildIntent(type: String, requestId: String): Intent {
        return Intent(Intent.ACTION_VIEW, Uri.parse("nostrsigner:")).apply {
            `package` = signerPackage
            putExtra("type", type)
            putExtra("id", requestId)
        }
    }

    /** Attempt content provider query for background operations. */
    private fun tryContentProvider(
        method: String,
        payload: String? = null,
        currentUser: String? = null,
        pubkey: String? = null,
    ): String? {
        return try {
            val uri = Uri.parse("content://$signerPackage.$method")
            val selectionArgs = buildList {
                add(payload ?: "")
                add(pubkey ?: "")
                add(currentUser ?: cachedPubkey ?: "")
            }.toTypedArray()

            val cursor = context.contentResolver.query(uri, null, null, selectionArgs, null)
            if (cursor == null) {
                // Null cursor = Amber hasn't granted this app background (content
                // resolver) permission for this op. Fall back to the Intent path.
                Log.w(TAG, "DBG: CP $method NULL cursor (permission not granted?)")
                return null
            }
            cursor.use {
                if (!it.moveToFirst()) {
                    Log.w(TAG, "DBG: CP $method empty cursor")
                    return null
                }
                Log.w(TAG, "DBG: CP $method columns=${it.columnNames.joinToString(",")}")
                // Reject column means the user denied the op.
                val rejIdx = it.getColumnIndex("rejected")
                if (rejIdx >= 0 && it.getString(rejIdx) == "true") {
                    Log.w(TAG, "DBG: CP $method rejected")
                    return null
                }
                // Amber returns crypto output under varying column names across
                // versions — accept whichever is present.
                for (col in listOf("result", "signature", "event")) {
                    val idx = it.getColumnIndex(col)
                    if (idx >= 0) {
                        val v = it.getString(idx)
                        if (!v.isNullOrEmpty()) {
                            Log.w(TAG, "DBG: CP $method OK via column=$col len=${v.length}")
                            return v
                        }
                    }
                }
                Log.w(TAG, "DBG: CP $method no usable column")
                null
            }
        } catch (e: Exception) {
            Log.w(TAG, "DBG: CP $method exception: ${e.message}")
            null
        }
    }

    /** Content provider specifically for sign_event (returns "event" column). */
    private fun tryContentProviderSign(eventJson: String, currentUser: String): String? = try {
        val uri = Uri.parse("content://$signerPackage.SIGN_EVENT")
        val selectionArgs = arrayOf(eventJson, "", currentUser)

        val cursor = context.contentResolver.query(uri, null, null, selectionArgs, null)
        cursor?.use {
            if (it.moveToFirst()) {
                // Check for rejection
                val rejectedIdx = it.getColumnIndex("rejected")
                if (rejectedIdx >= 0) return@use null

                val eventIdx = it.getColumnIndex("event")
                if (eventIdx >= 0) it.getString(eventIdx) else null
            } else null
        }
    } catch (e: Exception) {
        Log.d(TAG, "ContentProvider SIGN_EVENT not available: ${e.message}")
        null
    }
}
