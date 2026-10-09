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
import coil.decode.ImageDecoderDecoder
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
            // Bounded timeouts so a slow/dead avatar host fails fast (and can retry)
            // instead of hanging forever as a perpetually-blank profile picture.
            .okHttpClient {
                okhttp3.OkHttpClient.Builder()
                    .connectTimeout(15, java.util.concurrent.TimeUnit.SECONDS)
                    .readTimeout(15, java.util.concurrent.TimeUnit.SECONDS)
                    .callTimeout(25, java.util.concurrent.TimeUnit.SECONDS)
                    // Blossom media through Morganite when it runs on this phone.
                    .addInterceptor(com.nostrvault.service.LocalBlossomCache.interceptor)
                    // A friend's vault on the FIPS mesh serves its blobs directly.
                    .addInterceptor(com.nostrvault.fips.FipsMeshInterceptor())
                    .build()
            }
            .components {
                // Before the built-in HTTP fetcher, which would download a whole
                // video to read one frame of it.
                add(com.nostrvault.service.RemoteVideoFrameFetcher.Factory())
                // ImageDecoder (API 28+) decodes animated GIF/WebP natively and
                // draws through AnimatedImageDrawable on the render thread;
                // GifDecoder is the old software Movie path, which decodes every
                // frame on the CPU and dropped frames on a scrolling feed.
                if (android.os.Build.VERSION.SDK_INT >= 28) {
                    add(ImageDecoderDecoder.Factory())
                } else {
                    add(GifDecoder.Factory())
                }
                add(VideoFrameDecoder.Factory())
            }
            .crossfade(false) // Disable crossfade for instant rendering and better scroll performance
            .respectCacheHeaders(false) // Nostr profile pics rarely have proper cache headers
            .build()
}
