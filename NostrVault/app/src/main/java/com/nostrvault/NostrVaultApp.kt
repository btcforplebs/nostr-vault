package com.nostrvault

import android.app.Application
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.ComponentCallbacks2
import android.util.Log
import coil.ImageLoader
import coil.ImageLoaderFactory
import coil.imageLoader
import com.nostrvault.data.local.ProfileRepository
import com.nostrvault.di.ApplicationScope
import com.nostrvault.relay.RelayForegroundService
import com.nostrvault.service.MediaCacheService
import com.nostrvault.service.ProfilePicturePrefetcher
import com.nostrvault.ui.theme.Motion
import dagger.hilt.android.HiltAndroidApp
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import javax.inject.Inject
import javax.inject.Provider

@HiltAndroidApp
class NostrVaultApp : Application(), ImageLoaderFactory {

    @Inject
    lateinit var imageLoaderProvider: Provider<ImageLoader>

    @Inject
    lateinit var mediaCacheService: MediaCacheService

    @Inject
    lateinit var profilePicturePrefetcher: ProfilePicturePrefetcher

    @Inject
    @ApplicationScope
    lateinit var applicationScope: CoroutineScope

    @Inject
    lateinit var configStore: com.nostrvault.data.local.ConfigStore

    override fun onCreate() {
        super.onCreate()
        ProfileRepository.init(this)
        com.nostrvault.service.music.MusicPlayer.init(this)
        com.nostrvault.ui.screens.music.MusicFeedState.init(this)
        com.nostrvault.data.model.FeedMenuSettings.init(this)
        com.nostrvault.tutorials.TutorialCenter.init(this)
        com.nostrvault.tutorials.TutorialCenter.walletLinked = { !configStore.config.value.nwcURI.isNullOrBlank() }
        com.nostrvault.vaultguide.FillYourVaultCoordinator.init(this)
        Motion.install(this)
        createNotificationChannels()
        // GIFs downloaded for "Save to my Blossom" that a crash left behind.
        applicationScope.launch(kotlinx.coroutines.Dispatchers.IO) {
            com.nostrvault.data.gif.GifCache.sweep(cacheDir)
        }
        profilePicturePrefetcher.start(applicationScope)
        applicationScope.launch {
            configStore.config.collect {
                com.nostrvault.service.LocalBlossomCache.enabled = it.useLocalBlossomCache
            }
        }
    }

    override fun newImageLoader(): ImageLoader = imageLoaderProvider.get()

    @Suppress("DEPRECATION")
    override fun onTrimMemory(level: Int) {
        super.onTrimMemory(level)
        when {
            level >= ComponentCallbacks2.TRIM_MEMORY_COMPLETE -> {
                Log.w("NostrVaultApp", "Critical memory pressure (level=$level), evicting all caches")
                mediaCacheService.evictMemoryCaches()
                imageLoader.memoryCache?.clear()
            }
            level >= ComponentCallbacks2.TRIM_MEMORY_MODERATE -> {
                Log.w("NostrVaultApp", "Moderate memory pressure (level=$level), trimming caches")
                mediaCacheService.trimMemoryCaches()
                // Proportional eviction instead of full clear — preserves hot avatars
                imageLoader.memoryCache?.trimMemory(level)
            }
            level >= ComponentCallbacks2.TRIM_MEMORY_BACKGROUND -> {
                // Intentionally no-op for Coil. On 3GB devices Android sends this
                // callback frequently on app switch. Preserving the memory cache
                // across brief backgrounding prevents avatar reload flash on return.
                Log.d("NostrVaultApp", "Background memory pressure (level=$level), preserving Coil cache")
            }
        }
    }

    private fun createNotificationChannels() {
        val relayChannel = NotificationChannel(
            RelayForegroundService.CHANNEL_ID,
            getString(R.string.relay_notification_channel),
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "Persistent notification for the Nostr Vault relay service"
            setShowBadge(false)
        }

        val notificationManager = getSystemService(NotificationManager::class.java)
        notificationManager.createNotificationChannel(relayChannel)
    }
}
