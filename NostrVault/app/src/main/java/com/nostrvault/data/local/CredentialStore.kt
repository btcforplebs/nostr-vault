package com.nostrvault.data.local

import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey

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

    private lateinit var prefs: SharedPreferences

    fun init(context: Context) {
        if (::prefs.isInitialized) return

        try {
            val masterKey = MasterKey.Builder(context.applicationContext)
                .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
                .build()
            prefs = EncryptedSharedPreferences.create(
                context.applicationContext,
                PREFS_NAME,
                masterKey,
                EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
            )
        } catch (e: Exception) {
            Log.e(TAG, "Failed to create EncryptedSharedPreferences: ${e.message}")
            throw e
        }
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

    // ---- Keychain password (NIP-49 passphrase, keyed by npub) ----

    private fun keychainKey(npub: String): String = "keychain-$npub"

    fun storeKeychainPassword(password: String, npub: String): Boolean =
        store(password, keychainKey(npub))

    fun getKeychainPassword(npub: String): String? =
        get(keychainKey(npub))

    // ---- Whitelisted account hex keys ----

    private fun credHexKey(npub: String): String = "cred-hex-$npub"

    fun storeCredentialHexKey(hexKey: String, npub: String): Boolean =
        store(hexKey, credHexKey(npub))

    fun getCredentialHexKey(npub: String): String? =
        get(credHexKey(npub))

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
