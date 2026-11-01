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

    internal fun FeedService.watchWotCache(relayDataDir: String) {
        if (wotCacheObserver != null) return
        wotCacheObserver = object : FileObserver(relayDataDir, CLOSE_WRITE or MOVED_TO) {
            override fun onEvent(event: Int, path: String?) {
                if (path == WOT_CACHE_FILE) loadWotPubkeys()
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
        return TrustMap.web(_wotPubkeys.value, feedAuthorSet())
    }

    internal fun FeedService.globalTrustSetImpl(): Set<String>? {
        if (configStore.config.value.globalShowsEveryone) return null
        if (_wotPubkeys.value.isEmpty()) loadWotPubkeys()
        // Your follows too, so someone you just followed passes right away.
        return TrustMap.web(_wotPubkeys.value, feedAuthorSet())
    }

    @Suppress("DEPRECATION") // FileObserver(File) needs API 29; minSdk is 26.
    internal fun FeedService.loadWotPubkeysImpl() {
        scope.launch(Dispatchers.IO) {
            try {
                val config = configStore.config.value
                config.relayDataDir?.let { watchWotCache(it) }
                val wotCachePath = config.relayDataDir?.let { "$it/$WOT_CACHE_FILE" }
                if (wotCachePath != null) {
                    val file = File(wotCachePath)
                    if (file.exists()) {
                        // One streaming read for the graph and its vouches.
                        val parsed = file.inputStream().use { WotCacheFile.read(it, nostrService.activeHexPubkey) }
                        if (parsed == null) {
                            Log.w(TAG, "WoT cache unreadable: $wotCachePath")
                            return@launch
                        }
                        val loaded = parsed.pubkeys
                        val vouches = parsed.vouches
                        if (BuildConfig.DEBUG) Log.d(TAG, "WoT loaded: ${loaded.size} pubkeys")
                        withContext(Dispatchers.Main.immediate) {
                            _wotCacheRead.value = true
                            // Before the graph: its collectors read the vouches straight away.
                            _wotVouches.value = vouches
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
                            }
                        }
                    }
                }
            } catch (e: Exception) {
                Log.w(TAG, "WoT load failed: ${e.message}")
            }
        }
    }

/**
 * Whether Global asks its relays again as the trust graph loads: its REQ
 * went out while the web was empty, so it named nobody, and a new account
 * stayed blank until the next refresh (iOS #824 `resubscribeGlobalForNewGraph`).
 */
internal fun graphArrivalReasksGlobal(old: Set<String>, new: Set<String>, mode: FeedMode, everyone: Boolean): Boolean =
    old.isEmpty() && new.isNotEmpty() && mode == FeedMode.GLOBAL && !everyone
