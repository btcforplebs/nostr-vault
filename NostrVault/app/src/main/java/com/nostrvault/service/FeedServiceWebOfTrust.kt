package com.nostrvault.service

import android.os.FileObserver
import com.nostrvault.data.model.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.serialization.json.*
import com.nostrvault.service.FeedService.Companion.WOT_CACHE_FILE

    internal fun FeedService.watchWotCache(relayDataDir: String) {
        if (wotCacheObserver != null) return
        wotCacheObserver = object : FileObserver(relayDataDir, CLOSE_WRITE or MOVED_TO) {
            override fun onEvent(event: Int, path: String?) {
                if (path == WOT_CACHE_FILE) loadWotPubkeys()
            }
        }.also { it.startWatching() }
    }
