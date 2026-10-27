package com.nostrvault.data.local

import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import java.io.File

/**
 * Encrypted credential storage -- port of CredentialStore.swift.
 *
 * iOS uses Keychain Services; Android uses EncryptedSharedPreferences
 * backed by AndroidKeyStore (AES-256-GCM).
 *
 * All methods are thread-safe (SharedPreferences handles synchronization).
 */
object CredentialStore {

    private const val TAG = "CredentialStore"
    private const val PREFS_NAME = "nostrvault_credentials"
    private const val OWNER_ACCOUNT = "owner-key-password"

    @Volatile private lateinit var prefs: SharedPreferences
    private var openFailed = false

    private val _unreadable = kotlinx.coroutines.flow.MutableStateFlow(false)

    /**
     * True while the store could not be opened this launch. The app then
     * shows the recovery screen instead of carrying on as if no key had
     * ever been saved.
     */
    val unreadable: kotlinx.coroutines.flow.StateFlow<Boolean> = _unreadable

    /**
     * Opens the store, retrying a few times. A store that still can't be
     * opened stays closed: reads find nothing and writes fail, but the app
     * starts and nothing is deleted, however many launches in a row it fails
     * (a keyset the keystore lost a key for, as after some OS updates or a
     * restore). It used to be set aside and opened empty on the second such
     * launch, which dropped every saved key and the mesh key with it; now
     * only the person can do that, from the recovery screen ([startFresh]).
     * Synchronized: Hilt (main) and ConfigStore (IO) both call it.
     */
    @Synchronized
    fun init(context: Context) {
        if (::prefs.isInitialized || openFailed) return
        val app = context.applicationContext
        // A Start fresh the app was killed in the middle of: the old store goes back first.
        val swap = swap(app)
        if (swap.recover()) Log.w(TAG, "an unfinished Start fresh was undone; the old store is back")
        if (swap.pending.exists()) {
            // The old store couldn't be put back; opening now would silently start an empty one.
            Log.e(TAG, "an unfinished Start fresh could not be undone; the old store is still at ${swap.pending.name}")
            openFailed = true
            _unreadable.value = true
            return
        }
        val opened = openRecovering(open = { open(app) })
        if (opened == null) {
            openFailed = true
            _unreadable.value = true
            return
        }
        prefs = opened
        repairSwappedKeychainPasswords()
    }

    /** The recovery screen's Try again: true when the store opened this time. */
    @Synchronized
    fun retryOpen(context: Context): Boolean {
        if (::prefs.isInitialized) return true
        val opened = openRecovering(open = { open(context.applicationContext) }) ?: return false
        prefs = opened
        openFailed = false
        _unreadable.value = false
        repairSwappedKeychainPasswords()
        return true
    }

    /**
     * The recovery screen's Start fresh, after the person confirmed: an empty
     * store replaces the unreadable one, which is kept on disk (never deleted
     * here). Saved passwords, account keys and the mesh key are gone from the
     * app after this. The old store stays the live one until the fresh one
     * has opened and taken a write ([FreshStoreSwap]); if that fails, or the
     * app is killed first, the old store is put back. True when the fresh
     * store is in.
     */
    @Synchronized
    fun startFresh(context: Context): Boolean {
        val app = context.applicationContext
        val opened = try {
            swap(app).run(
                openFresh = {
                    open(app).takeIf { it.edit().putLong(FRESH_SINCE, System.currentTimeMillis()).commit() }
                },
                keepAs = File(storeFile(app).parentFile, "$PREFS_NAME.unreadable-${System.currentTimeMillis()}.xml"),
            )
        } catch (e: Exception) {
            Log.e(TAG, "Start fresh failed: ${e.message}")
            swap(app).recover()
            null
        }
        if (opened == null) {
            Log.e(TAG, "Failed to open a fresh EncryptedSharedPreferences; the old store is back")
            return false
        }
        prefs = opened
        openFailed = false
        _unreadable.value = false
        return true
    }

    /** When Start fresh put this store in; also its proof that the fresh store takes writes. */
    private const val FRESH_SINCE = "fresh-store-since"

    private fun storeFile(context: Context) = File(context.filesDir.parentFile, "shared_prefs/$PREFS_NAME.xml")

    /** [Context.deleteSharedPreferences] also drops the copy the process cached (a plain delete would leave it loaded). */
    private fun swap(context: Context) =
        FreshStoreSwap(storeFile(context), deleteLive = { context.deleteSharedPreferences(PREFS_NAME) })

    private fun open(context: Context): SharedPreferences {
        val masterKey = MasterKey.Builder(context)
            .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
            .build()
        return EncryptedSharedPreferences.create(
            context,
            PREFS_NAME,
            masterKey,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
        )
    }

    /**
     * [open], tried [attempts] times. Null when the store stays closed; it is
     * never set aside here.
     */
    internal fun <T> openRecovering(
        open: () -> T,
        attempts: Int = 3,
        pause: (Int) -> Unit = { Thread.sleep(150L * it) },
    ): T? {
        for (attempt in 1..attempts) {
            try {
                return open()
            } catch (e: Exception) {
                Log.e(TAG, "Failed to open EncryptedSharedPreferences (try $attempt): ${e.message}")
            }
            if (attempt < attempts) pause(attempt)
        }
        return null
    }

    /** Deletes the copies [startFresh] kept (factory reset). */
    fun deleteSetAside(context: Context) {
        File(context.filesDir.parentFile, "shared_prefs").listFiles()
            ?.filter { it.name.startsWith("$PREFS_NAME.unreadable-") }
            ?.forEach { it.delete() }
    }

    /**
     * Setup used to call storeKeychainPassword(npub, password), arguments
     * swapped, so the npub was saved under "keychain-<password>" and the
     * password lookups found nothing. Moves each such entry to where it
     * belongs. Runs on every launch; a no-op once nothing is left to move.
     */
    private fun repairSwappedKeychainPasswords() {
        val all = try { prefs.all } catch (e: Exception) { return }
        for ((badKey, npub, password) in swappedKeychainEntries(all)) {
            if (getKeychainPassword(npub) == null) storeKeychainPassword(password = password, npub = npub)
            delete(badKey)
            Log.i(TAG, "moved a keychain password stored under the wrong key")
        }
    }

    /** (wrong key, npub, password) for every entry the swapped call wrote. */
    internal fun swappedKeychainEntries(entries: Map<String, *>): List<Triple<String, String, String>> =
        entries.mapNotNull { (key, value) ->
            val suffix = key.removePrefix(KEYCHAIN_PREFIX)
            if (key.startsWith(KEYCHAIN_PREFIX) && value is String && value.startsWith("npub1") &&
                !suffix.startsWith("npub1") && suffix.isNotEmpty()
            ) Triple(key, value, suffix) else null
        }

    private fun accountId(npub: String): String = "account-key-password-$npub"

    // ---- Owner (global) credential ----

    fun storeOwnerPassword(password: String): Boolean =
        store(password, OWNER_ACCOUNT)

    fun getOwnerPassword(): String? =
        get(OWNER_ACCOUNT)

    fun deleteOwnerPassword(): Boolean =
        delete(OWNER_ACCOUNT)

    fun hasOwnerPassword(): Boolean =
        getOwnerPassword() != null

    // ---- Per-account credentials ----

    fun storePassword(password: String, forNpub: String): Boolean =
        store(password, accountId(forNpub))

    fun getPassword(forNpub: String): String? =
        get(accountId(forNpub))

    fun deletePassword(forNpub: String): Boolean =
        delete(accountId(forNpub))

    // ---- nsec storage (hex secret key keyed by hex pubkey) ----

    private fun nsecKey(hexPubkey: String): String = "nsec-hex-$hexPubkey"

    fun saveNsec(hexSeckey: String, hexPubkey: String): Boolean =
        store(hexSeckey, nsecKey(hexPubkey))

    fun getNsec(hexPubkey: String): String? =
        get(nsecKey(hexPubkey))

    fun deleteNsec(hexPubkey: String): Boolean =
        delete(nsecKey(hexPubkey))

    // ---- Keychain password (NIP-49 passphrase, keyed by npub) ----

    private const val KEYCHAIN_PREFIX = "keychain-"
    private fun keychainKey(npub: String): String = "$KEYCHAIN_PREFIX$npub"

    fun storeKeychainPassword(password: String, npub: String): Boolean =
        store(password, keychainKey(npub))

    fun getKeychainPassword(npub: String): String? =
        get(keychainKey(npub))

    fun deleteKeychainPassword(npub: String): Boolean =
        delete(keychainKey(npub))

    // ---- Whitelisted account hex keys ----

    private fun credHexKey(npub: String): String = "cred-hex-$npub"

    fun storeCredentialHexKey(hexKey: String, npub: String): Boolean =
        store(hexKey, credHexKey(npub))

    fun getCredentialHexKey(npub: String): String? =
        get(credHexKey(npub))

    fun deleteCredentialHexKey(npub: String): Boolean =
        delete(credHexKey(npub))

    // ---- FIPS mesh network identity ----
    //
    // Deliberately not one of the account keys above: the mesh address should
    // be rotatable without touching the social identity, and vice versa. One
    // per install, not per account.

    private const val MESH_IDENTITY = "fips-mesh-nsec"

    fun storeMeshNsec(nsec: String): Boolean =
        store(nsec, MESH_IDENTITY)

    fun getMeshNsec(): String? =
        get(MESH_IDENTITY)

    /**
     * The saved mesh nsec, or null when none is saved. Unlike [getMeshNsec] a
     * store that is closed or a value that will not decrypt throws, so the
     * caller can tell "never made" from "could not read" and does not mint a
     * new mesh address over one it merely failed to read (Mac/iOS, #1122).
     */
    fun readMeshNsec(): String? = prefs.getString(MESH_IDENTITY, null)

    fun deleteMeshNsec(): Boolean =
        delete(MESH_IDENTITY)

    // ---- Private helpers ----

    private fun store(password: String, account: String): Boolean = try {
        prefs.edit().putString(account, password).commit()
    } catch (e: Exception) {
        Log.e(TAG, "Failed to store credential for $account: ${e.message}")
        false
    }

    private fun get(account: String): String? = try {
        prefs.getString(account, null)
    } catch (e: Exception) {
        Log.e(TAG, "Failed to retrieve credential for $account: ${e.message}")
        null
    }

    private fun delete(account: String): Boolean = try {
        prefs.edit().remove(account).commit()
    } catch (e: Exception) {
        Log.e(TAG, "Failed to delete credential for $account: ${e.message}")
        false
    }
}
