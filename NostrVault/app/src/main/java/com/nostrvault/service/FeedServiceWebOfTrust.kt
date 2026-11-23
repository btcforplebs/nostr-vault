package com.nostrvault.service

import android.os.FileObserver
import com.nostrvault.data.model.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.serialization.json.*
import com.nostrvault.service.FeedService.Companion.WOT_CACHE_FILE
import android.util.Log
import com.nostrvault.BuildConfig
import com.nostrvault.service.FeedService.Companion.TAG
import java.io.File
import com.nostrvault.relay.reachAccountNpub
import com.nostrvault.relay.reachFor

    internal fun FeedService.watchWotCache(relayDataDir: String) {
        if (wotCacheObserver != null) return
        wotCacheObserver = object : FileObserver(relayDataDir, CLOSE_WRITE or MOVED_TO) {
            override fun onEvent(event: Int, path: String?) {
                // The links file is swapped in just after the cache: the open
                // account's web is counted from it (AccountWeb). Its own pair
                // (wot_cache_<hex>.json) counts too (WotFeedFiles).
                if (WotFeedFiles.isFeedFile(path, nostrService.activeHexPubkey)) loadWotPubkeys()
            }
        }.also { it.startWatching() }
    }

    /**
     * The one rule every Global view follows: your Web of Trust unless the
     * shield is set to Everyone. Null means everyone. Fails closed like the
     * Global feed: with no graph yet, nobody passes.
     */
    /**
     * Who counts as inside your network in the Relay tab: the relay's trust
     * graph plus your current follows. The graph is rebuilt about once a day,
     * so without the follows someone you just followed stayed "outside".
     * Empty while the graph isn't loaded, which counts nobody as outside.
     */
    internal fun FeedService.relayTabTrustedPubkeysImpl(): Set<String> {
        if (_wotPubkeys.value.isEmpty()) loadWotPubkeys()
        return com.nostrvault.util.PublicKeyRegistry.withoutPublic(
            TrustMap.withoutBlocked(TrustMap.web(_wotPubkeys.value, feedAuthorSet()), blockedHexForActiveAccount()),
        ) { ownAccountHexes() }
    }

    /** Every account on this device (and the open one): never counted outside for a public key. */
    internal fun FeedService.ownAccountHexes(): Set<String> =
        configStore.config.value.allAccountNpubs().mapNotNullTo(HashSet()) { com.nostrvault.relay.HavenBridge.decodeNpub(it) }
            .apply { nostrService.activeHexPubkey.takeIf { it.isNotEmpty() }?.let { add(it) } }

    internal fun FeedService.globalTrustSetImpl(): Set<String>? {
        if (configStore.config.value.globalShowsEveryone) return null
        if (_wotPubkeys.value.isEmpty()) loadWotPubkeys()
        // Your follows too, so someone you just followed passes right away.
        // Someone you blocked (in public or privately) is out of your web, whoever vouches for them.
        // So is an account whose secret key is public: anyone can post as it.
        return com.nostrvault.util.PublicKeyRegistry.withoutPublic(
            TrustMap.withoutBlocked(TrustMap.web(_wotPubkeys.value, feedAuthorSet()), blockedHexForActiveAccount()),
        ) { ownAccountHexes() }
    }

    internal fun FeedService.loadWotPubkeysImpl() {
        // One run at a time (Tron #2012 follow-up): ~20 callers ask while the
        // web is empty, and throwing away the run in progress on each ask kept
        // it empty. A call during a run is answered by one more run after it, so
        // a cache write, links write or follow change mid-read is still seen.
        if (wotLoadGate.tryStart()) launchWotLoad()
    }

    /** One WoT load; started only through [wotLoadGate], which it releases or reruns at the end. */
    @Suppress("DEPRECATION") // FileObserver(File) needs API 29; minSdk is 26.
    private fun FeedService.launchWotLoad() {
        scope.launch(Dispatchers.IO) {
            try {
                val config = configStore.config.value
                config.relayDataDir?.let { watchWotCache(it) }
                val dir = config.relayDataDir?.let { File(it) }
                if (dir != null) {
                    val owner = nostrService.activeHexPubkey
                    val pooledFile = File(dir, WOT_CACHE_FILE)
                    // Other accounts are still judged by the pooled web (trustedPubkeysFor).
                    val pooled = if (pooledFile.exists()) pooledFile.inputStream().use { WotCacheFile.read(it, owner) } else null
                    // The feed reads the open account's own web; the pooled one only while that is missing.
                    val files = WotFeedFiles.forAccount(dir, owner)
                    val parsed = if (files.perAccount) files.cache.inputStream().use { WotCacheFile.read(it, owner) } else pooled
                    if (parsed == null) {
                        if (files.cache.exists()) Log.w(TAG, "WoT cache unreadable: ${files.cache}")
                        return@launch
                    }
                    // The pooled web is every device account's; keep the open account's part.
                    // Its own file is already that, and narrowing it again changes nothing.
                    val minFollowers = config.reachFor(config.reachAccountNpub).minFollowers
                    val loaded = accountWeb(parsed.pubkeys, files.links, parsed.depth, minFollowers)
                    val loose = accountLoose(parsed.pubkeys, loaded, files.links, parsed.depth, minFollowers)
                    val vouches = parsed.vouches
                    if (BuildConfig.DEBUG) Log.d(TAG, "WoT loaded: ${loaded.size} pubkeys (${if (files.perAccount) "account" else "pooled"})")
                    withContext(Dispatchers.Main.immediate) {
                        // An unreadable pooled file keeps the last one; never the open account's own web.
                        (pooled ?: parsed.takeUnless { files.perAccount })?.let { _pooledWotPubkeys.value = it.pubkeys }
                        _wotCacheRead.value = true
                        // Before the graph: its collectors read the vouches straight away.
                        _wotVouches.value = vouches
                        val looseChanged = loose != _wotLoosePubkeys.value
                        _wotLoosePubkeys.value = loose
                        if (loaded != _wotPubkeys.value) {
                            val reask = graphArrivalReasksGlobal(
                                _wotPubkeys.value, loaded, _feedMode.value,
                                configStore.config.value.globalShowsEveryone,
                            )
                            _wotPubkeys.value = loaded
                            // Global is filtered against this set; notes
                            // already on screen have to be re-judged.
                            recomputeFilteredNotes()
                            if (reask) resubscribePrimaryToConnected()
                        } else if (looseChanged) {
                            recomputeFilteredNotes()
                        }
                    }
                }
            } catch (e: Exception) {
                Log.w(TAG, "WoT load failed: ${e.message}")
            } finally {
                if (wotLoadGate.finish()) launchWotLoad()
            }
        }
    }

/**
 * [saved] narrowed to the open account ([AccountWeb]): its follows, and anyone
 * Min Followers of them follow, not anyone the device's accounts together do.
 */
internal fun FeedService.accountWeb(saved: Set<String>, links: File, depth: Int?, minFollowers: Int): Set<String> {
    val follows = followedPubkeySet()
    val keep = deviceAccountHexes()
    return if (depth != 3 || !links.exists()) AccountWeb.narrow(saved, null, depth, follows, keep, minFollowers)
    else links.bufferedReader().use { AccountWeb.narrow(saved, it, depth, follows, keep, minFollowers) }
}

/**
 * Whether Global asks its relays again as the trust graph loads: its REQ
 * went out while the web was empty, so it named nobody, and a new account
 * stayed blank until the next refresh (iOS #824 `resubscribeGlobalForNewGraph`).
 */
internal fun graphArrivalReasksGlobal(old: Set<String>, new: Set<String>, mode: FeedMode, everyone: Boolean): Boolean =
    old.isEmpty() && new.isNotEmpty() && mode == FeedMode.GLOBAL && !everyone
