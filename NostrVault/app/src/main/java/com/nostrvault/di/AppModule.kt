package com.nostrvault.di

import android.content.Context
import coil.ImageLoader
import com.nostrvault.data.local.CredentialStore
import com.nostrvault.data.local.EngagementTracker
import com.nostrvault.data.local.ProfileRepository
import com.nostrvault.service.ContactManager
import com.nostrvault.service.EventPublisher
import com.nostrvault.service.FeedFilterEngine
import coil.decode.GifDecoder
import coil.decode.VideoFrameDecoder
import coil.disk.DiskCache
import coil.memory.MemoryCache
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.android.qualifiers.ApplicationContext
import dagger.hilt.components.SingletonComponent
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import javax.inject.Qualifier
import javax.inject.Singleton

@Qualifier
@Retention(AnnotationRetention.BINARY)
annotation class ApplicationScope

@Module
@InstallIn(SingletonComponent::class)
object AppModule {

    @Provides
    @Singleton
    @ApplicationScope
    fun provideApplicationScope(): CoroutineScope =
        CoroutineScope(SupervisorJob() + Dispatchers.Default)

    @Provides
    @Singleton
    fun provideCredentialStore(@ApplicationContext context: Context): CredentialStore {
        CredentialStore.init(context)
        return CredentialStore
    }

    @Provides
    @Singleton
    fun provideProfileRepository(): ProfileRepository = ProfileRepository

    @Provides
    @Singleton
    fun provideEventPublisher(): EventPublisher = EventPublisher

    @Provides
    @Singleton
    fun provideFeedFilterEngine(): FeedFilterEngine = FeedFilterEngine

    @Provides
    @Singleton
    fun provideEngagementTracker(@ApplicationContext context: Context): EngagementTracker {
        // Must initialize dataDir before any load/saveInteractionState call,
        // mirroring provideCredentialStore above. Without this, FeedService's
        // saveInteractionState() (e.g. from pauseFeed) crashes with an
        // uninitialized-lateinit error.
        EngagementTracker.init(context)
        return EngagementTracker
    }

    @Provides
    @Singleton
    fun provideContactManager(): ContactManager = ContactManager

    @Provides
    @Singleton
    fun provideImageLoader(@ApplicationContext context: Context): ImageLoader =
        ImageLoader.Builder(context)
            .memoryCache {
                MemoryCache.Builder(context)
                    .maxSizePercent(0.15) // 15%: ~45MB on 3GB, ~180MB on 12GB — ample for downsampled avatars
                    .build()
            }
            .diskCache {
                DiskCache.Builder()
                    .directory(context.cacheDir.resolve("image_cache"))
                    .maxSizeBytes(256L * 1024 * 1024) // 256 MB
                    .build()
            }
            .components {
                add(GifDecoder.Factory())
                add(VideoFrameDecoder.Factory())
            }
            .crossfade(false) // Disable crossfade for instant rendering and better scroll performance
            .respectCacheHeaders(false) // Nostr profile pics rarely have proper cache headers
            .build()
}
