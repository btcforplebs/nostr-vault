package com.nostrvault.service

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.util.Log
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.relay.HavenBridge
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
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

    /**
     * Sign an event. Returns the full signed event JSON, or null on failure.
     *
     * Amber is currently owner-only by design: [cachedPubkey] is a single global
     * value seeded from config.ownerNpub, and there's no per-account Amber
     * identity/permission tracking. AccountSettingsScreen's add-account flow only
     * offers "local"/"nip46" for secondary accounts, so this path shouldn't be
     * reachable with a non-owner account active — but if it ever is (e.g. a future
     * bug elsewhere), fail loudly here instead of silently signing as the owner
     * while purporting to act for a different account.
     */
    /**
     * @param asOwner signing an owner-forced event (relay AUTH, owner lists)
     *   while another account is active. Amber holds the owner's key, so that
     *   is allowed; the caller still checks the result's pubkey.
     */
    suspend fun signEvent(unsignedEventJson: String, asOwner: Boolean = false): String? {
        val config = configStore.config.value
        val activeNpub = config.activeAccountNpub
        if (!asOwner && !activeNpub.isNullOrEmpty() && activeNpub != config.ownerNpub) {
            Log.e(TAG, "signEvent: refusing to sign — active account ($activeNpub) is not the owner, and Amber has no per-account identity to sign as")
            return null
        }

        if (cachedPubkey == null) restoreCachedPubkey()
        val currentUser = cachedPubkey
        if (currentUser == null) {
            Log.e(TAG, "signEvent: cachedPubkey is null, cannot sign (ownerNpub=${configStore.config.value.ownerNpub.take(12)}, bridgeLoaded=${HavenBridge.isLoaded})")
            return null
        }

        // Serialize: concurrent signs race Amber's single activity and get dropped.
        return signerLock.withLock {
            // Try content provider first (silent background signing). Blocking
            // binder call → off the caller's dispatcher onto IO.
            withContext(Dispatchers.IO) {
                tryContentProviderSign(unsignedEventJson, currentUser)
            }?.let { return@withLock it }

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
                    // The user saw the prompt and did not approve it. Distinct from
                    // every other failure here (Amber unreachable, no launcher,
                    // timeout), which callers may retry — an answer of "no" must not
                    // be re-asked.
                    Log.w(TAG, "Amber sign_event rejected")
                    throw SignerRejectedException()
                }
            }
        }
    }

    // ══════════════════════════════════════════════════════════════════
    // Encryption / decryption
    // ══════════════════════════════════════════════════════════════════

    suspend fun nip04Encrypt(plaintext: String, recipientPubkey: String): String? =
        cryptoOp("nip04_encrypt", "NIP04_ENCRYPT", plaintext, recipientPubkey)

    /**
     * @param silentOnly when true, only the silent ContentProvider path is tried;
     *   the interactive Intent fallback is skipped and null is returned instead.
     *   Bulk callers (e.g. decrypting a backlog of DMs) MUST set this — firing one
     *   approval Intent per message floods and times out the signer.
     */
    suspend fun nip04Decrypt(ciphertext: String, senderPubkey: String, silentOnly: Boolean = false): String? =
        cryptoOp("nip04_decrypt", "NIP04_DECRYPT", ciphertext, senderPubkey, silentOnly)

    suspend fun nip44Encrypt(plaintext: String, recipientPubkey: String): String? =
        cryptoOp("nip44_encrypt", "NIP44_ENCRYPT", plaintext, recipientPubkey)

    /** @param silentOnly see [nip04Decrypt]. */
    suspend fun nip44Decrypt(ciphertext: String, senderPubkey: String, silentOnly: Boolean = false): String? =
        cryptoOp("nip44_decrypt", "NIP44_DECRYPT", ciphertext, senderPubkey, silentOnly)

    /**
     * Force a get_public_key Intent carrying the full permissions list so Amber
     * registers background (ContentProvider) signing access for this app. After
     * the user approves once, decrypt/sign content-resolver queries return
     * results silently — no per-message approval dialog. Amber persists the grant
     * across launches, so this only prompts until granted.
     *
     * MUST be called while already holding [signerLock] (cryptoOp invokes it
     * inside its critical section). Does NOT re-acquire the lock — re-entrant
     * Mutex acquisition would deadlock, and a backlog of decrypts must not race
     * each other into separate permission prompts.
     */
    private suspend fun requestBackgroundPermission(): Boolean {
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
        return ok
    }

    // ══════════════════════════════════════════════════════════════════
    // Internal helpers
    // ══════════════════════════════════════════════════════════════════

    private suspend fun cryptoOp(
        intentType: String,
        contentProviderType: String,
        payload: String,
        pubkey: String,
        silentOnly: Boolean = false,
    ): String? {
        // Amber is owner-only by design — see signEvent()'s doc comment.
        val config = configStore.config.value
        val activeNpub = config.activeAccountNpub
        if (!activeNpub.isNullOrEmpty() && activeNpub != config.ownerNpub) {
            Log.e(TAG, "cryptoOp $intentType: refusing — active account ($activeNpub) is not the owner, and Amber has no per-account identity to act as")
            return null
        }

        // Self-heal like signEvent(): if the pubkey wasn't cached at init (config
        // / bridge not ready), restore it now — otherwise every decrypt silently
        // no-ops (no prompt, no content query) and DMs never decrypt.
        if (cachedPubkey == null) restoreCachedPubkey()
        val currentUser = cachedPubkey ?: run {
            Log.w(TAG, "DBG: cryptoOp $intentType cachedPubkey NULL after restore → null")
            return null
        }

        // Serialize the ENTIRE signer round-trip — content-provider query,
        // one-time permission request, AND Intent fallback — under a single lock.
        // Amber funnels every request through one pipeline and silently drops any
        // that arrive while another is in flight (see signerLock doc). Running the
        // silent ContentProvider path concurrently (as before) let a backlog of
        // DMs storm Amber with simultaneous content-resolver queries → dropped
        // decrypts and per-message prompt floods. One lock == one Amber request at
        // a time, which is the only thing Amber actually handles.
        return signerLock.withLock {
            // Try content provider first (silent background signing). Blocking
            // binder call → off the caller's dispatcher onto IO.
            withContext(Dispatchers.IO) {
                tryContentProvider(contentProviderType, payload, currentUser, pubkey)
            }?.let {
                Log.w(TAG, "DBG: cryptoOp $intentType via ContentProvider OK len=${it.length}")
                return@withLock it
            }

            // ContentProvider missed → Amber likely hasn't granted this app
            // background-signing permission. Request it ONCE per session (one
            // prompt) while holding the lock so the whole backlog waits behind a
            // single grant, then retry the silent path. Because we hold the lock,
            // no other decrypt can race ahead into a per-message Intent prompt.
            if (backgroundPermissionRequested.compareAndSet(false, true)) {
                requestBackgroundPermission()
                withContext(Dispatchers.IO) {
                    tryContentProvider(contentProviderType, payload, currentUser, pubkey)
                }?.let {
                    Log.w(TAG, "DBG: cryptoOp $intentType via ContentProvider OK after grant len=${it.length}")
                    return@withLock it
                }
            } else {
                // The grant was already requested by an earlier caller; it has now
                // completed (we hold the lock it was requested under). Retry the
                // silent path before ever considering a per-message prompt.
                withContext(Dispatchers.IO) {
                    tryContentProvider(contentProviderType, payload, currentUser, pubkey)
                }?.let {
                    Log.w(TAG, "DBG: cryptoOp $intentType via ContentProvider OK (post-grant) len=${it.length}")
                    return@withLock it
                }
            }
            // Silent-only callers (bulk DM backlog drains) must NOT fall through to
            // the interactive Intent. Firing one approval Intent per queued message
            // machine-guns the signer — dozens of activity launches that Amber
            // auto-cancels ("too many requests" / "signer timed out"). Bail to null;
            // the caller leaves the item queued for a later, silent retry.
            if (silentOnly) {
                Log.w(TAG, "DBG: cryptoOp $intentType silent-only, CP unavailable → null (no Intent)")
                return@withLock null
            }

            Log.w(TAG, "DBG: cryptoOp $intentType ContentProvider miss → Intent fallback")

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

    /** npub form of [hexPubkey], required by Amber's ContentProvider for the
     *  current_user operand (it returns a null cursor for a bare hex key). */
    private fun asNpub(hexPubkey: String?): String {
        val hex = hexPubkey ?: cachedPubkey ?: return ""
        if (hex.startsWith("npub1")) return hex
        return HavenBridge.encodeNpub(hex) ?: hex
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
            // NIP-55: Amber reads the operands from the PROJECTION array (2nd arg),
            // NOT selectionArgs. Passing them as selectionArgs (as before) made the
            // provider return a null cursor every time → silent signing never worked
            // and everything fell to the per-message Intent flood. Order is
            // [data, peerPubkey(hex), current_user(npub)]. (Matches dark-wisp.)
            val projection = arrayOf(
                payload ?: "",
                pubkey ?: "",
                asNpub(currentUser),
            )

            val cursor = context.contentResolver.query(uri, projection, null, null, null)
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
        // Operands go in the PROJECTION array (see tryContentProvider). Order is
        // [eventJson, "", current_user(npub)].
        val projection = arrayOf(eventJson, "", asNpub(currentUser))

        val cursor = context.contentResolver.query(uri, projection, null, null, null)
        cursor?.use {
            if (it.moveToFirst()) {
                // "rejected" == "true" means the user denied it; the column merely
                // existing does not (it may be present and false).
                val rejectedIdx = it.getColumnIndex("rejected")
                if (rejectedIdx >= 0 && it.getString(rejectedIdx) == "true") return@use null

                val eventIdx = it.getColumnIndex("event")
                if (eventIdx >= 0) it.getString(eventIdx) else null
            } else null
        }
    } catch (e: Exception) {
        Log.d(TAG, "ContentProvider SIGN_EVENT not available: ${e.message}")
        null
    }
}

/**
 * The signer prompt was shown and the user did not approve it.
 *
 * Subclasses [IllegalStateException] so existing call sites — which already see
 * that type thrown by `NostrService.signEventAsync` when a signer fails — behave
 * exactly as before. Callers that retry a failed signature check for this type
 * and stop, so a declined prompt is never re-shown.
 */
class SignerRejectedException(
    message: String = "Amber signing request was rejected",
) : IllegalStateException(message)
