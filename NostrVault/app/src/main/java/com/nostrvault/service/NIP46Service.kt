package com.nostrvault.service

import android.util.Log
import com.nostrvault.relay.AccountBunkerConfig
import com.nostrvault.relay.HavenBridge
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.util.concurrent.atomic.AtomicInteger

/**
 * Port of NIP46Service / cshared.go NIP-46 bridge -- remote signer protocol.
 * All operations delegate to the Go FFI bridge which manages the bunker
 * client lifecycle, WebSocket subscriptions, and RPC timeouts.
 *
 * The Go core (#168) keeps one live bunker session per signer; one of them is
 * active. Switching back to an account whose session is alive re-activates it
 * with no round trip to the signer instead of logging in again (#229 parity).
 */
object NIP46Service {

    private const val TAG = "NIP46Service"

    /** The bunker calls this service makes, so tests can stand in for the native bridge. */
    interface Bridge {
        fun connect(clientSecretKey: String, bunkerUrl: String): String?
        fun activate(signerPubkey: String): String?
        fun drop(signerPubkey: String)
        fun ping(): Int
    }

    private object NativeBridge : Bridge {
        override fun connect(clientSecretKey: String, bunkerUrl: String) = HavenBridge.nip46Connect(clientSecretKey, bunkerUrl)
        override fun activate(signerPubkey: String) = HavenBridge.nip46Activate(signerPubkey)
        override fun drop(signerPubkey: String) = HavenBridge.nip46Drop(signerPubkey)
        override fun ping() = HavenBridge.nip46Ping()
    }

    @Volatile internal var bridge: Bridge = NativeBridge

    /**
     * Guards the connect / ensure decision only, so two callers cannot both
     * log in (the second used to tear down, or cancel, the first). It is never
     * held across a sign request: one hung bunker must not freeze every sign.
     */
    private val connectMutex = Mutex()

    /** The user pubkey the active session answers for, when connected. */
    @Volatile var connectedPubkey: String? = null
        private set

    /** The Go-side key ([signerKey]) of the active session, when connected. */
    @Volatile internal var activeSignerKey: String? = null
        private set

    /** Kinds signed because the person did something (iOS `userActionKinds`). */
    val userActionKinds: Set<Int> = setOf(0, 1, 3, 5, 6, 7, 9, 13, 16, 20, 21, 22, 1111, 1984, 9734, 30023)

    /** Sign requests sent to the active session and not yet answered. */
    private val outstandingRequests = AtomicInteger(0)

    private val _lastError = MutableStateFlow<String?>(null)
    /** Why the last connect for an account failed (e.g. a signer answering as another key). */
    val lastError: StateFlow<String?> = _lastError.asStateFlow()

    private val _isConnected = MutableStateFlow(false)
    /** Whether a bunker session is currently connected (active account's signer). */
    val isConnected: StateFlow<Boolean> = _isConnected.asStateFlow()

    /**
     * Connect to a NIP-46 bunker.
     * @param clientSecretKey Hex secret key for the NIP-46 client session.
     * @param bunkerUrl Full bunker:// URL with relay, pubkey, and secret.
     * @return The signer's public key hex on success, null on failure.
     */
    suspend fun connect(clientSecretKey: String, bunkerUrl: String): String? =
        withContext(Dispatchers.IO) {
            try {
                val pubkey = HavenBridge.nip46Connect(clientSecretKey, bunkerUrl)
                connectedPubkey = pubkey
                activeSignerKey = if (pubkey != null) bunkerHost(bunkerUrl) else null
                _isConnected.value = pubkey != null
                pubkey
            } catch (e: Exception) {
                Log.e(TAG, "NIP-46 connect failed: ${e.message}")
                _isConnected.value = false
                null
            }
        }

    /**
     * Makes [expectedPubkey]'s bunker the active signer, under one lock:
     * re-activates its live session when there is one, else logs in. A
     * signer that answers for any other key is dropped and the account left
     * disconnected with an error; it is never kept as connected.
     * @return [expectedPubkey] on success, null otherwise.
     */
    suspend fun connectForAccount(cfg: AccountBunkerConfig, expectedPubkey: String): String? =
        connectMutex.withLock {
            withContext(Dispatchers.IO) {
                if (_isConnected.value && connectedPubkey == expectedPubkey) return@withContext expectedPubkey
                _isConnected.value = false
                connectedPubkey = null
                activeSignerKey = null
                val signer = signerKey(cfg)

                val reused = try {
                    if (signer.isEmpty()) null else bridge.activate(signer)
                } catch (e: Exception) { null }
                if (reused != null) {
                    // No ping first: the session's relay pool redials a dropped
                    // socket on its own, and a signer app asleep on the phone
                    // (Clave) misses a ping — which used to throw away a working
                    // session and log in from scratch (up to 90 s, often a fresh
                    // approval) on every switch. A session that really is dead
                    // is caught by [recheckSession] after a sign goes unanswered.
                    if (reused == expectedPubkey) return@withContext accept(expectedPubkey, signer)
                    bridge.drop(signer)
                }

                val pubkey = try {
                    bridge.connect(cfg.clientSecretKey, cfg.bunkerURI)
                } catch (e: Exception) {
                    Log.e(TAG, "NIP-46 connect failed: ${e.message}")
                    null
                }
                when {
                    pubkey == null -> {
                        _lastError.value = "Could not reach the bunker"
                        null
                    }
                    pubkey != expectedPubkey -> {
                        if (signer.isNotEmpty()) bridge.drop(signer)
                        _lastError.value = "This bunker signs as ${pubkey.take(8)}…, not this account"
                        Log.e(TAG, "NIP-46 connect rejected: signer answered as ${pubkey.take(8)}, expected ${expectedPubkey.take(8)}")
                        null
                    }
                    else -> accept(pubkey, signer)
                }
            }
        }

    /** Resets state between unit tests (no native call). */
    internal fun disconnectForTest() {
        _isConnected.value = false
        connectedPubkey = null
        activeSignerKey = null
        outstandingRequests.set(0)
        _lastError.value = null
        bridge = NativeBridge
    }

    private fun accept(pubkey: String, signer: String): String {
        connectedPubkey = pubkey
        activeSignerKey = signer.ifEmpty { null }
        _isConnected.value = true
        _lastError.value = null
        return pubkey
    }

    private fun bunkerHost(uri: String): String =
        runCatching { java.net.URI(uri).host }.getOrNull().orEmpty()

    /**
     * The key the Go core files a signer's session under: the bunker link's
     * host (the remote signer's key), else the stored signer key. The stored
     * `signerPubkey` is the account's own key, which differs from the remote
     * signer's for bunkers such as Clave, so it is only a fallback.
     */
    fun signerKey(cfg: AccountBunkerConfig): String =
        bunkerHost(cfg.bunkerURI).ifEmpty { cfg.signerPubkey }

    /**
     * The session to close when an account's bunker config goes from [old] to
     * [new] (null: removed). Pairing again over the same signer already
     * replaced its session in the Go core, so that one is left alone; a
     * different signer's old session would otherwise linger, live, unused.
     */
    fun sessionToClose(old: AccountBunkerConfig?, new: AccountBunkerConfig?): String? {
        val oldKey = old?.let { signerKey(it) }?.ifEmpty { null } ?: return null
        return if (new == null || signerKey(new) != oldKey) oldKey else null
    }

    /**
     * Closes one signer's Go session, e.g. when its account is removed or
     * paired again with another signer.
     */
    fun dropSession(signerKey: String) {
        if (signerKey.isEmpty()) return
        try {
            bridge.drop(signerKey)
        } catch (e: Exception) {
            Log.e(TAG, "NIP-46 drop failed: ${e.message}")
        }
        if (activeSignerKey == signerKey) detachForAccountSwitch()
    }

    /**
     * Stops treating the current session as this app's signer, leaving it
     * connected in the Go core. Used on account switch, so switching back is
     * instant instead of a fresh login.
     */
    fun detachForAccountSwitch() {
        _isConnected.value = false
        connectedPubkey = null
        activeSignerKey = null
    }

    /**
     * A post the signer never answered may mean a broken session: a relay can
     * close the reply subscription for good, or the reply listener can sit in
     * a long redial backoff after an outage. It may also just mean nobody
     * approved it in time. One ping tells them apart; only if that fails too
     * (and [sessionKey] is still the active session, with nothing else in
     * flight) is the session dropped, so the next request logs in afresh.
     */
    internal suspend fun recheckSession(sessionKey: String?) {
        if (sessionKey.isNullOrEmpty() || !stillOnSession(sessionKey)) return
        val alive = withContext(Dispatchers.IO) {
            try { bridge.ping() == 0 } catch (e: Exception) { false }
        }
        if (alive) return
        connectMutex.withLock {
            // Re-check: a switch or another request may have moved on meanwhile.
            if (!stillOnSession(sessionKey)) return
            try { bridge.drop(sessionKey) } catch (e: Exception) { Log.e(TAG, "NIP-46 drop failed: ${e.message}") }
            detachForAccountSwitch()
            _lastError.value = "The signer did not answer"
            Log.e(TAG, "NIP-46: signer did not answer a request or a ping; dropped the session, next request logs in again")
        }
    }

    private fun stillOnSession(sessionKey: String) =
        _isConnected.value && outstandingRequests.get() == 0 && activeSignerKey == sessionKey

    /**
     * Signs through [signerPubkey]'s live session without making it active and
     * without logging in (the owner's relay AUTH while another account is
     * active). Null when there is no live session for it.
     */
    suspend fun signEventWith(signerPubkey: String, eventJson: String): String? =
        withContext(Dispatchers.IO) {
            try {
                HavenBridge.nip46SignEventWith(signerPubkey, eventJson)
            } catch (e: Exception) {
                Log.e(TAG, "NIP-46 signWith failed: ${e.message}")
                null
            }
        }

    /** Disconnect from the NIP-46 bunker. */
    fun disconnect() {
        try {
            HavenBridge.nip46Disconnect()
        } catch (e: Exception) {
            Log.e(TAG, "NIP-46 disconnect failed: ${e.message}")
        } finally {
            _isConnected.value = false
            connectedPubkey = null
            activeSignerKey = null
        }
    }

    /**
     * Sign an event via the remote signer.
     * @param userInitiated Something the person did (a post, a reaction). Only
     *   then does a failure trigger [recheckSession]: background requests such
     *   as relay AUTH routinely go unanswered and say nothing about the session.
     * @return Signed event JSON string, or null on failure.
     */
    suspend fun signEvent(eventJson: String, userInitiated: Boolean = false): String? {
        // The session this request goes to, so a late failure can never drop
        // the session of an account switched to while it was waiting.
        val sessionKey = activeSignerKey
        val signed = withContext(Dispatchers.IO) {
            outstandingRequests.incrementAndGet()
            try {
                HavenBridge.nip46SignEvent(eventJson)
            } catch (e: Exception) {
                Log.e(TAG, "NIP-46 sign failed: ${e.message}")
                null
            } finally {
                outstandingRequests.decrementAndGet()
            }
        }
        if (signed == null && userInitiated) recheckSession(sessionKey)
        return signed
    }

    /** Get the signer's public key. */
    suspend fun getPublicKey(): String? =
        withContext(Dispatchers.IO) {
            try {
                HavenBridge.nip46GetPublicKey()
            } catch (e: Exception) {
                Log.e(TAG, "NIP-46 getPublicKey failed: ${e.message}")
                null
            }
        }

    /** Encrypt via NIP-44 through the remote signer. */
    suspend fun nip44Encrypt(targetPubkey: String, plaintext: String): String? =
        withContext(Dispatchers.IO) {
            try {
                HavenBridge.nip46NIP44Encrypt(targetPubkey, plaintext)
            } catch (e: Exception) {
                Log.e(TAG, "NIP-46 NIP44 encrypt failed: ${e.message}")
                null
            }
        }

    /** Decrypt via NIP-44 through the remote signer. */
    suspend fun nip44Decrypt(targetPubkey: String, ciphertext: String): String? =
        withContext(Dispatchers.IO) {
            try {
                HavenBridge.nip46NIP44Decrypt(targetPubkey, ciphertext)
            } catch (e: Exception) {
                Log.e(TAG, "NIP-46 NIP44 decrypt failed: ${e.message}")
                null
            }
        }

    /** Encrypt via NIP-04 through the remote signer. */
    suspend fun nip04Encrypt(targetPubkey: String, plaintext: String): String? =
        withContext(Dispatchers.IO) {
            try {
                HavenBridge.nip46NIP04Encrypt(targetPubkey, plaintext)
            } catch (e: Exception) {
                Log.e(TAG, "NIP-46 NIP04 encrypt failed: ${e.message}")
                null
            }
        }

    /** Decrypt via NIP-04 through the remote signer. */
    suspend fun nip04Decrypt(targetPubkey: String, ciphertext: String): String? =
        withContext(Dispatchers.IO) {
            try {
                HavenBridge.nip46NIP04Decrypt(targetPubkey, ciphertext)
            } catch (e: Exception) {
                Log.e(TAG, "NIP-46 NIP04 decrypt failed: ${e.message}")
                null
            }
        }

    /** Ping the remote signer. Returns true on success. */
    suspend fun ping(): Boolean =
        withContext(Dispatchers.IO) {
            try {
                HavenBridge.nip46Ping() == 0
            } catch (e: Exception) {
                Log.e(TAG, "NIP-46 ping failed: ${e.message}")
                false
            }
        }

    /** Get pending auth URL (consumed on read). */
    fun getPendingAuthUrl(): String? =
        try {
            HavenBridge.nip46GetPendingAuthUrl()
        } catch (e: Exception) {
            null
        }
}
