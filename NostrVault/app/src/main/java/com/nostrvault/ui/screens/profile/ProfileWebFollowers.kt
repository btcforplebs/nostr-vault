package com.nostrvault.ui.screens.profile

import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.model.FollowerSnapshot
import com.nostrvault.data.model.TrustLinks
import com.nostrvault.data.model.VaultContentFilter
import com.nostrvault.relay.HavenBridge
import com.nostrvault.service.FeedService
import com.nostrvault.service.NostrService
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File

/**
 * Where a profile's Followers number comes from, counted only inside your
 * web (Logen 2026-11-27: "followers counted only inside your web, on other
 * people's profiles too"). Relay COUNTs and Vertex count everyone, so the
 * header no longer shows them.
 */
internal class ProfileWebFollowers(
    private val feedService: FeedService,
    private val nostrService: NostrService,
    private val configStore: ConfigStore,
) {
    /**
     * Your own: the relay's ledger (spam and blocked left out) judged by the
     * rule the Vault's Followers tab uses, so the header matches its
     * default web-only list. Null when the ledger can't be read.
     */
    suspend fun own(pk: String): Int? = withContext(Dispatchers.IO) {
        val ledger = runCatching { FollowerSnapshot.parse(HavenBridge.getFollowers(pk)) }.getOrNull()
            ?: return@withContext null
        feedService.followersJudged(ledger.without(feedService.blockedHexForActiveAccount()), pk)
            .current.count { !it.outside }
    }

    /** Your follows who follow [pk], from the relay's links file; empty when it has no entry. */
    suspend fun linked(pk: String): List<String> = withContext(Dispatchers.IO) {
        val dir = configStore.config.value.relayDataDir ?: return@withContext emptyList()
        val text = runCatching { File(dir, TrustLinks.FILE_NAME).readText() }.getOrNull() ?: return@withContext emptyList()
        TrustLinks.bridges(text, pk, nostrService.activeHexPubkey, feedService.followedPubkeys.value.toSet()).orEmpty()
    }

    /** Someone else's: [linked] plus [sampled] followers, those outside [trusted] (your web) left out. */
    fun others(linked: Collection<String>, sampled: Collection<String>, trusted: Set<String>): Int? {
        val me = nostrService.activeHexPubkey
        val whitelist = configStore.config.value.whitelistedNpubs?.mapNotNull { nostrService.npubToHex(it) }?.toSet().orEmpty()
        return ProfileWebRules.followersInWeb(linked, sampled, { VaultContentFilter.isOutside(it, me, whitelist, trusted) }, trusted.isNotEmpty())
    }
}
