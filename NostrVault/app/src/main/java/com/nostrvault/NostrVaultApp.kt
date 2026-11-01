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

    @Inject
    lateinit var deletedPostsStore: com.nostrvault.service.deleted.DeletedPostsStore

    override fun onCreate() {
        warmUpOffMain()
        super.onCreate()
        ProfileRepository.init(this)
        com.nostrvault.data.local.DeletedNotesStore.init(this)
        com.nostrvault.service.deleted.DeletedPostsStore.shared = deletedPostsStore
        com.nostrvault.service.music.MusicPlayer.init(this)
        com.nostrvault.ui.screens.music.MusicFeedState.init(this)
        com.nostrvault.data.model.FeedMenuSettings.init(this)
        com.nostrvault.tutorials.TutorialCenter.init(this)
        com.nostrvault.tutorials.TutorialCenter.walletLinked = { !configStore.config.value.nwcURI.isNullOrBlank() }
        com.nostrvault.vaultguide.FillYourVaultCoordinator.init(this)
        Motion.install(this)
        createNotificationChannels()
        // The relay pauses its screen-only work while no activity is visible.
        androidx.lifecycle.ProcessLifecycleOwner.get().lifecycle.addObserver(
            com.nostrvault.relay.AppForegroundReporter { on ->
                if (com.nostrvault.relay.HavenBridge.isLoaded) {
                    runCatching { com.nostrvault.relay.HavenBridge.setAppForeground(on) }
                }
                if (!on) trimGoMemory()
            },
        )
        // GIFs downloaded for "Save to my Blossom" that a crash left behind.
        applicationScope.launch(kotlinx.coroutines.Dispatchers.IO) {
            com.nostrvault.data.gif.GifCache.sweep(cacheDir)
        }
        profilePicturePrefetcher.start(applicationScope)
        // Widgets hear the relay start and stop, not only its 30 s tick.
        com.nostrvault.widget.WidgetPublisher.watchRelay(this, applicationScope)
        applicationScope.launch {
            configStore.config.collect {
                com.nostrvault.service.LocalBlossomCache.enabled = it.useLocalBlossomCache
            }
        }
    }

    /**
     * Opens the key store and loads the Go library on a background thread
     * while Hilt builds the app's singletons, instead of on main when the
     * first of them asks. Nothing waits for it and nothing changes order:
     * [com.nostrvault.data.local.CredentialStore.init] is synchronized and
     * HavenBridge loads in its class initializer, so a main-thread caller
     * that gets there first, or while this runs, simply waits for the one
     * open or load to finish, the same as before. The config is still read
     * on main (MainActivity.onCreate) before anything is drawn or saved.
     *
     * The Go environment is set here on main first: setenv is not safe while
     * other threads run, so the warm-up thread only loads. The library load
     * is not wrapped in runCatching: if HavenBridge's initializer throws,
     * the crash report keeps that cause instead of the bare
     * NoClassDefFoundError main would hit later.
     */
    private fun warmUpOffMain() {
        com.nostrvault.relay.GoRuntimeEnv.ensure()
        Thread({
            runCatching { com.nostrvault.data.local.CredentialStore.init(this) }
            com.nostrvault.relay.HavenBridge.isLoaded
        }, "nv-startup-warmup").start()
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
                trimGoMemory()
            }
            level >= ComponentCallbacks2.TRIM_MEMORY_MODERATE -> {
                Log.w("NostrVaultApp", "Moderate memory pressure (level=$level), trimming caches")
                trimGoMemory()
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

    /** The relay's free Go memory back to the system, off the main thread ([HavenBridge.trimMemory]). */
    private fun trimGoMemory() {
        if (!com.nostrvault.relay.HavenBridge.isLoaded) return
        applicationScope.launch(kotlinx.coroutines.Dispatchers.IO) {
            runCatching { com.nostrvault.relay.HavenBridge.trimMemory() }
        }
    }

    private fun createNotificationChannels() {
        val relayChannel = NotificationChannel(
            RelayForegroundService.CHANNEL_ID,
            getString(R.string.relay_notification_channel),
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "Keeps your vault running in the background"
            setShowBadge(false)
        }

        val notificationManager = getSystemService(NotificationManager::class.java)
        notificationManager.createNotificationChannel(relayChannel)
    }
}
