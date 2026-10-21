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
    private const val HEALTH_PREFS = "nostrvault_credentials_open"
    private const val FAILED_LAST_LAUNCH = "failed-last-launch"

    /**
     * Opens the store, retrying a few times. A store that still can't be
     * opened stays closed for this launch: reads find nothing and writes
     * fail, but the app starts and nothing is deleted. Only if it failed on
     * the launch before as well (a keyset the keystore no longer has a key
     * for, as after some OS updates or a restore) is it set aside and opened
     * fresh. Synchronized: Hilt (main) and ConfigStore (IO) both call it.
     */
    @Synchronized
    fun init(context: Context) {
        if (::prefs.isInitialized || openFailed) return
        val app = context.applicationContext
        val health = app.getSharedPreferences(HEALTH_PREFS, Context.MODE_PRIVATE)
        val opened = openRecovering(
            open = { open(app) },
            setAside = { setAside(app) },
            failedBefore = health.getBoolean(FAILED_LAST_LAUNCH, false),
        )
        health.edit().putBoolean(FAILED_LAST_LAUNCH, opened == null).commit()
        if (opened == null) {
            openFailed = true
            return
        }
        prefs = opened
        repairSwappedKeychainPasswords()
    }

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
     * Copies the unreadable file next to itself, then deletes it through
     * [Context.deleteSharedPreferences], which also drops the copy the
     * process has cached (a plain rename would leave the bad keyset loaded).
     */
    private fun setAside(context: Context) {
        val file = File(context.filesDir.parentFile, "shared_prefs/$PREFS_NAME.xml")
        if (file.exists()) {
            file.copyTo(File(file.parentFile, "$PREFS_NAME.unreadable-${System.currentTimeMillis()}.xml"), overwrite = true)
        }
        context.deleteSharedPreferences(PREFS_NAME)
    }

    /**
     * [open], tried [attempts] times. If every try fails and [failedBefore]
     * (the last launch couldn't open it either), [setAside] and one fresh
     * [open]. Null when the store stays closed.
     */
    internal fun <T> openRecovering(
        open: () -> T,
        setAside: () -> Unit,
        failedBefore: Boolean,
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
        if (!failedBefore) return null
        return try {
            Log.e(TAG, "Failed on two launches; setting the store aside")
            setAside()
            open()
        } catch (e: Exception) {
            Log.e(TAG, "Failed to open a fresh EncryptedSharedPreferences: ${e.message}")
            null
        }
    }

    /** Deletes the copies [setAside] kept (factory reset). */
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
