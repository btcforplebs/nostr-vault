package com.nostrvault.service

import com.nostrvault.data.model.AccountWeb
import com.nostrvault.relay.AccountReach
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
        return pooled(dir)
    }

    fun pooled(dir: File) = Pair(File(dir, FeedService.WOT_CACHE_FILE), File(dir, AccountWeb.LINKS_FILE), perAccount = false)

    /**
     * The account's file was built at [reach], held to what the relay runs
     * (haven-go reachOf: level 1-3, bar 0 or more). The relay's
     * loadAccountWebs skips a file built at another level or bar and gates
     * from the pooled web until its rebuild lands; the feed does the same
     * (Tron 2472 low 2). A field the file leaves out is not held against it.
     */
    fun builtAt(parsed: WotCacheFile.Parsed, reach: AccountReach): Boolean {
        if (parsed.depth != null && parsed.depth != reach.depth.coerceIn(1, 3)) return false
        if (parsed.minFollowers != null && parsed.minFollowers != reach.minFollowers.coerceAtLeast(0)) return false
        return true
    }

    /** A write to [name] can change the open account's feed web. */
    fun isFeedFile(name: String?, hex: String): Boolean {
        if (name == null) return false
        if (name == FeedService.WOT_CACHE_FILE || name == AccountWeb.LINKS_FILE) return true
        return isHex(hex) && (name == accountCacheName(hex) || name == accountLinksName(hex))
    }

    private fun isHex(hex: String) = hex.length == 64 && hex.all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' }
}

/**
 * The pooled wot_cache.json, parsed again only when it is rewritten (Tron 2472
 * low 3): every load reads it for the other accounts, and one rebuild writes
 * four watched files. An unreadable read is not kept, so the next load tries
 * again. Keyed by path, date, size and owner (the owner rules "usable").
 */
class PooledWotMemo {
    private data class Key(val path: String, val modified: Long, val size: Long, val owner: String)
    private var key: Key? = null
    private var value: WotCacheFile.Parsed? = null

    /** Parse count, for tests. */
    var reads = 0
        private set

    @Synchronized
    fun read(file: File, owner: String): WotCacheFile.Parsed? {
        if (!file.isFile) return null
        val now = Key(file.path, file.lastModified(), file.length(), owner.lowercase())
        if (now == key) return value
        reads++
        val parsed = file.inputStream().use { WotCacheFile.read(it, owner) }
        key = if (parsed == null) null else now
        value = parsed
        return parsed
    }
}
