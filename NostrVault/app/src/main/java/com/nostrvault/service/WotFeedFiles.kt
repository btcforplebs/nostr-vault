package com.nostrvault.service

import com.nostrvault.data.model.AccountWeb
import java.io.File

/**
 * Which trust files the feed reads for the open account.
 *
 * The relay saves each account's own web beside the pooled `wot_cache.json`:
 * `wot_cache_<hex>.json` and, at Follow Distance 3, `wot_links_<hex>.json`
 * (haven-go pkg/wot/account_cache.go, same shape as the pooled pair). The feed
 * reads that pair for the open account, so it is judged at that account's own
 * depth and bar and not the device's pooled web. The pooled pair is the
 * fallback only while the account's file is missing (an older relay, or
 * before its first build). Other accounts' alerts and rows still read the
 * pooled web. iOS twin: `WotFiles.feedCacheURL`.
 */
object WotFeedFiles {
    const val ACCOUNT_CACHE_PREFIX = "wot_cache_"
    const val ACCOUNT_LINKS_PREFIX = "wot_links_"

    data class Pair(val cache: File, val links: File, val perAccount: Boolean)

    fun accountCacheName(hex: String) = "$ACCOUNT_CACHE_PREFIX${hex.lowercase()}.json"
    fun accountLinksName(hex: String) = "$ACCOUNT_LINKS_PREFIX${hex.lowercase()}.json"

    /** The open account's pair when its cache exists, else the pooled pair. */
    fun forAccount(dir: File, hex: String): Pair {
        if (isHex(hex)) {
            val cache = File(dir, accountCacheName(hex))
            if (cache.isFile) return Pair(cache, File(dir, accountLinksName(hex)), perAccount = true)
        }
        return Pair(File(dir, FeedService.WOT_CACHE_FILE), File(dir, AccountWeb.LINKS_FILE), perAccount = false)
    }

    /** A write to [name] can change the open account's feed web. */
    fun isFeedFile(name: String?, hex: String): Boolean {
        if (name == null) return false
        if (name == FeedService.WOT_CACHE_FILE || name == AccountWeb.LINKS_FILE) return true
        return isHex(hex) && (name == accountCacheName(hex) || name == accountLinksName(hex))
    }

    private fun isHex(hex: String) = hex.length == 64 && hex.all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' }
}
