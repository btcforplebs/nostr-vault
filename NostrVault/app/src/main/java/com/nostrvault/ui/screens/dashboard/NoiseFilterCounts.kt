package com.nostrvault.ui.screens.dashboard

import com.nostrvault.relay.HavenConfig

/**
 * The Feed Dashboard's Noise Filtering numbers (iOS FeedDashboardSheet
 * blockedUsersSummary).
 *
 * [blocked] is the active account's block list, the one the feed hides.
 * [blacklisted] is everyone blocked on any account on this device: iOS counts
 * its legacy `blacklistedNpubs` field, which Android never had, and the union
 * is what iOS's relay-level blacklist (`allBlockedNpubsAcrossAccounts`) holds.
 */
data class NoiseFilterCounts(val blocked: Int, val blacklisted: Int) {
    companion object {
        fun of(config: HavenConfig): NoiseFilterCounts {
            val all = buildSet {
                config.blockedNpubsPerAccount.values.forEach { addAll(it) }
                // The legacy flat list is the owner's, mirrored from their mute
                // list; it only counts where the owner has no per-account list,
                // the same fallback blockedForActiveAccount uses.
                if (config.ownerNpub !in config.blockedNpubsPerAccount) {
                    config.blockedNpubs?.let { addAll(it) }
                }
            }
            return NoiseFilterCounts(
                blocked = config.blockedForActiveAccount().toSet().size,
                blacklisted = all.size,
            )
        }
    }
}
