package com.nostrvault.service

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.util.Log
import coil.ImageLoader
import coil.request.CachePolicy
import coil.request.ImageRequest
import com.nostrvault.BuildConfig
import com.nostrvault.data.local.ConfigStore
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.first
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Background prefetcher that warms Coil's disk cache with followed users' profile pictures.
 *
 * Runs after relay connects and contacts load. Downloads avatars in small batches
 * on Wi-Fi/unmetered connections so they're instant when the user scrolls the feed.
 *
 * Design choices for low-end devices (3GB Moto G Play):
 * - Batches of 5 (not 10) to limit peak memory
 * - 1 second inter-batch delay to avoid starving relay WebSocket connections
 * - size(128) matches AvatarImage composable — cache in the format we'll display
 * - 12-hour debounce between full runs
 * - Stops immediately if network changes to metered
 */
@Singleton
class ProfilePicturePrefetcher @Inject constructor(
    @ApplicationContext private val context: Context,
    private val feedService: FeedService,
    private val nostrService: NostrService,
    private val configStore: ConfigStore,
    private val imageLoader: ImageLoader,
) {
    companion object {
        private const val TAG = "AvatarPrefetch"
        private const val BATCH_SIZE = 15
        private const val BATCH_DELAY_MS = 300L
        private const val DEBOUNCE_MS = 12L * 60 * 60 * 1000 // 12 hours
        private const val STARTUP_DELAY_MS = 10_000L // Wait for contacts to load
        private const val PROFILE_FETCH_WAIT_MS = 5_000L // Wait for Kind 0 metadata
        private const val METADATA_CHUNK_SIZE = 100 // Follows per metadata REQ
        private const val METADATA_CHUNK_DELAY_MS = 750L // Breathing room between them
        private const val PREFS_NAME = "avatar_prefetch"
        private const val PREF_LAST_RUN = "last_run_timestamp"
    }

    private val prefs by lazy { context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE) }

    @Volatile
    private var isRunning = false

    @Volatile
    private var isUnmeteredNetwork = false

    private var networkCallback: ConnectivityManager.NetworkCallback? = null
    private var prefetchJob: Job? = null

    /**
     * Start monitoring network and schedule prefetch.
     * Call from Application.onCreate() after DI is ready.
     */
    fun start(scope: CoroutineScope) {
        registerNetworkCallback()

        scope.launch {
            // Wait for relay to be ready and contacts to load
            delay(STARTUP_DELAY_MS)
            runIfEligible()
        }

        // Also react to follow list changes
        scope.launch {
            var previousSize = 0
            feedService.followedPubkeys.collect { pubkeys ->
                if (pubkeys.size > previousSize && previousSize > 0) {
                    // New follows added — prefetch their avatars immediately
                    val newPubkeys = pubkeys.drop(previousSize)
                    if (BuildConfig.DEBUG) Log.d(TAG, "Follow list grew by ${newPubkeys.size}, prefetching new avatars")
                    prefetchForPubkeys(newPubkeys)
                }
                previousSize = pubkeys.size
            }
        }
    }

    fun stop() {
        prefetchJob?.cancel()
        prefetchJob = null
        unregisterNetworkCallback()
    }

    private suspend fun runIfEligible() {
        val config = configStore.config.value
        if (!config.prefetchAvatars) {
            if (BuildConfig.DEBUG) Log.d(TAG, "Prefetch disabled in config")
            return
        }

        if (!isUnmeteredNetwork) {
            if (BuildConfig.DEBUG) Log.d(TAG, "Not on unmetered network, skipping")
            return
        }

        val lastRun = prefs.getLong(PREF_LAST_RUN, 0L)
        if (System.currentTimeMillis() - lastRun < DEBOUNCE_MS) {
            if (BuildConfig.DEBUG) Log.d(TAG, "Last run was within 12 hours, skipping")
            return
        }

        prefetchAllAvatars()
    }

    private suspend fun prefetchAllAvatars() {
        if (isRunning) return
        isRunning = true

        try {
            val pubkeys = feedService.followedPubkeys.value
            if (pubkeys.isEmpty()) {
                if (BuildConfig.DEBUG) Log.d(TAG, "No followed pubkeys, skipping")
                return
            }

            if (BuildConfig.DEBUG) Log.d(TAG, "Starting avatar prefetch for ${pubkeys.size} followed accounts")

            // Fetch missing profile metadata first, paced. Handing the whole
            // follow list over at once became a single metadata REQ for every
            // follow, and the kind-0 flood it answered with landed on the feed
            // while the user was scrolling it. Chunking spreads that over the
            // sweep instead; the avatars are wanted eventually, not this second.
            val profiles = nostrService.profiles.value
            val missingProfiles = pubkeys.filter { profiles[it] == null }
            if (missingProfiles.isNotEmpty()) {
                if (BuildConfig.DEBUG) Log.d(TAG, "Fetching ${missingProfiles.size} missing profiles")
                for (chunk in missingProfiles.chunked(METADATA_CHUNK_SIZE)) {
                    nostrService.fetchMissingProfiles(chunk)
                    delay(METADATA_CHUNK_DELAY_MS)
                }
                delay(PROFILE_FETCH_WAIT_MS)
            }

            // Build URL list from resolved profiles
            val updatedProfiles = nostrService.profiles.value
            val urls = pubkeys.mapNotNull { pk ->
                updatedProfiles[pk]?.pictureURL
            }.distinct()

            // Filter to uncached URLs (check Coil disk cache)
            val uncached = urls.filter { url ->
                val key = coil.memory.MemoryCache.Key(url)
                imageLoader.memoryCache?.get(key) == null && !isDiskCached(url)
            }

            if (BuildConfig.DEBUG) Log.d(TAG, "URLs: ${urls.size} total, ${uncached.size} uncached")

            if (uncached.isEmpty()) {
                prefs.edit().putLong(PREF_LAST_RUN, System.currentTimeMillis()).apply()
                return
            }

            // Batch download
            var downloaded = 0
            for (batch in uncached.chunked(BATCH_SIZE)) {
                if (!isUnmeteredNetwork) {
                    if (BuildConfig.DEBUG) Log.d(TAG, "Lost unmetered network, stopping after $downloaded downloads")
                    break
                }

                coroutineScope {
                    batch.map { url ->
                        async {
                            try {
                                val request = ImageRequest.Builder(context)
                                    .data(url)
                                    .size(128)
                                    .memoryCachePolicy(CachePolicy.ENABLED)
                                    .diskCachePolicy(CachePolicy.ENABLED)
                                    .allowHardware(true)
                                    .build()
                                imageLoader.execute(request)
                                downloaded++
                            } catch (e: Exception) {
                                if (BuildConfig.DEBUG) Log.d(TAG, "Failed to prefetch $url: ${e.message}")
                            }
                        }
                    }.awaitAll()
                }

                delay(BATCH_DELAY_MS)
            }

            prefs.edit().putLong(PREF_LAST_RUN, System.currentTimeMillis()).apply()
            if (BuildConfig.DEBUG) Log.d(TAG, "Prefetch complete: $downloaded/${uncached.size} avatars cached")

        } finally {
            isRunning = false
        }
    }

    /**
     * Prefetch avatars for a specific set of pubkeys (e.g., newly followed users).
     * Runs immediately without debounce.
     */
    private suspend fun prefetchForPubkeys(pubkeys: List<String>) {
        if (!isUnmeteredNetwork) return
        if (!configStore.config.value.prefetchAvatars) return

        // Ensure we have metadata
        nostrService.fetchMissingProfiles(pubkeys)
        delay(PROFILE_FETCH_WAIT_MS)

        val profiles = nostrService.profiles.value
        val urls = pubkeys.mapNotNull { profiles[it]?.pictureURL }

        for (url in urls) {
            try {
                val request = ImageRequest.Builder(context)
                    .data(url)
                    .size(128)
                    .memoryCachePolicy(CachePolicy.ENABLED)
                    .diskCachePolicy(CachePolicy.ENABLED)
                    .allowHardware(true)
                    .build()
                imageLoader.execute(request)
            } catch (_: Exception) { }
        }
    }

    @OptIn(coil.annotation.ExperimentalCoilApi::class)
    private fun isDiskCached(url: String): Boolean {
        // Coil uses the URL as the disk cache key by default
        val snapshot = imageLoader.diskCache?.openSnapshot(url)
        return if (snapshot != null) {
            snapshot.close()
            true
        } else {
            false
        }
    }

    private fun registerNetworkCallback() {
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val request = NetworkRequest.Builder()
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .build()

        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) {
                isUnmeteredNetwork = caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)
            }

            override fun onLost(network: Network) {
                isUnmeteredNetwork = false
            }
        }

        cm.registerNetworkCallback(request, callback)
        networkCallback = callback

        // Check current state
        val activeNetwork = cm.activeNetwork
        val activeCaps = activeNetwork?.let { cm.getNetworkCapabilities(it) }
        isUnmeteredNetwork = activeCaps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED) == true
    }

    private fun unregisterNetworkCallback() {
        networkCallback?.let {
            val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            try { cm.unregisterNetworkCallback(it) } catch (_: Exception) { }
        }
        networkCallback = null
    }
}
