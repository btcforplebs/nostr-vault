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

    private companion object {
        const val PREFS_NAME = "relay_followers"
    }
}
