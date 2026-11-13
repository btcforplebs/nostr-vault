package com.nostrvault.data.local

import android.content.Context
import dagger.hilt.android.qualifiers.ApplicationContext
import javax.inject.Inject
import javax.inject.Singleton

/**
 * When each owner last looked at the Relay tab's Followers list (epoch seconds).
 * Follows the ledger watched happen after this light the red dot. iOS keeps the
 * same value in UserDefaults as `followersSeenAt.<owner hex>`.
 */
@Singleton
class FollowersSeenStore @Inject constructor(
    @ApplicationContext context: Context,
) {
    private val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    fun seenAt(ownerHex: String): Long = prefs.getLong(key(ownerHex), 0L)

    fun markSeen(ownerHex: String, nowSeconds: Long = System.currentTimeMillis() / 1000) {
        if (ownerHex.isEmpty()) return
        prefs.edit().putLong(key(ownerHex), nowSeconds).apply()
    }

    private fun key(ownerHex: String) = "followersSeenAt.$ownerHex"

    /**
     * When each owner last left or arrived at the Vault tab's "Vault" list
     * (epoch seconds): lines newer than it carry the since-last-visit dot.
     * iOS keeps it in UserDefaults as `vaultActivitySeenAt.<owner hex>`.
     */
    fun activitySeenAt(ownerHex: String): Long = prefs.getLong(activityKey(ownerHex), 0L)

    fun markActivitySeen(ownerHex: String, nowSeconds: Long = System.currentTimeMillis() / 1000) {
        if (ownerHex.isEmpty()) return
        prefs.edit().putLong(activityKey(ownerHex), nowSeconds).apply()
    }

    private fun activityKey(ownerHex: String) = "vaultActivitySeenAt.$ownerHex"

    /**
     * When [ownerHex] last had [list] (a VaultMode name) on screen, epoch
     * seconds, or null: the Vault tab's dot lights only for something newer
     * (iOS keeps `vaultNewsLastVisit.<owner hex>`).
     */
    fun newsVisit(ownerHex: String, list: String): Long? =
        prefs.getLong(newsKey(ownerHex, list), -1L).takeIf { it >= 0 }

    fun markNewsVisit(ownerHex: String, lists: Collection<String>, nowSeconds: Long = System.currentTimeMillis() / 1000) {
        if (ownerHex.isEmpty() || lists.isEmpty()) return
        val edit = prefs.edit()
        lists.forEach { edit.putLong(newsKey(ownerHex, it), nowSeconds) }
        edit.apply()
    }

    private fun newsKey(ownerHex: String, list: String) = "vaultNewsLastVisit.${ownerHex.lowercase()}.$list"

    private companion object {
        const val PREFS_NAME = "relay_followers"
    }
}
