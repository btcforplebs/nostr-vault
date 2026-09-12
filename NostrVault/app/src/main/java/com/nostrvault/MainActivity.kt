package com.nostrvault

import android.Manifest
import android.app.PictureInPictureParams
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.net.Uri
import android.os.Build
import android.os.Bundle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.Surface
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.fips.FipsMeshManager
import com.nostrvault.relay.LogStore
import com.nostrvault.relay.RelayForegroundService
import com.nostrvault.service.AmberResultBridge
import com.nostrvault.service.DMService
import com.nostrvault.service.FeedService
import com.nostrvault.service.LocalNotificationService
import com.nostrvault.service.MediaUploadManager
import com.nostrvault.service.NostrService
import com.nostrvault.service.PendingPostManager
import com.nostrvault.ui.components.FullScreenMediaHost
import com.nostrvault.ui.components.VideoPiPBridge
import com.nostrvault.ui.navigation.BridgeEntityDecoder
import com.nostrvault.ui.navigation.DeepLinkRouter
import com.nostrvault.ui.navigation.NostrVaultNavHost
import com.nostrvault.ui.navigation.PendingDeepLink
import com.nostrvault.ui.notification.NotificationManager
import com.nostrvault.ui.theme.AppTheme
import com.nostrvault.ui.theme.NostrVaultTheme
import com.nostrvault.ui.theme.Surface0
import com.nostrvault.widget.WidgetPublisher
import androidx.fragment.app.FragmentActivity
import dagger.hilt.android.AndroidEntryPoint
import javax.inject.Inject

@AndroidEntryPoint
class MainActivity : FragmentActivity() {

    @Inject lateinit var configStore: ConfigStore
    @Inject lateinit var dmService: DMService
    @Inject lateinit var feedService: FeedService
    @Inject lateinit var nostrService: NostrService
    @Inject lateinit var logStore: LogStore
    @Inject lateinit var localNotificationService: LocalNotificationService
    @Inject lateinit var notificationManager: NotificationManager
    @Inject lateinit var pendingPostManager: PendingPostManager
    @Inject lateinit var mediaUploadManager: MediaUploadManager
    @Inject lateinit var widgetPublisher: WidgetPublisher
    @Inject lateinit var fipsMeshManager: FipsMeshManager

    private val notificationPermissionLauncher =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { /* result ignored */ }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Must register before Activity reaches STARTED state
        AmberResultBridge.initialize(this)

        enableEdgeToEdge()

        // Ask for notification permission (Android 13+) so local notifications for
        // inbound mentions/DMs/zaps can be shown. No-op on older versions.
        requestNotificationPermissionIfNeeded()

        // Load persisted config so hasCompletedSetup reflects saved state
        configStore.reload()

        // After reload(), never before: the preference lives in the config file
        // and reads false until it has been loaded, which would make this a
        // silent no-op every launch.
        fipsMeshManager.restoreIfEnabled(lifecycleScope)

        // Handle media shared into the app via the system share sheet (ACTION_SEND)
        handleShareIntent(intent)

        // …and taps that came from a widget, a notification or a nostr: link.
        handleDeepLinkIntent(intent)

        // Keep PiP auto-enter params in sync with whichever video is playing full-screen
        VideoPiPBridge.onActiveVideoChanged = { refreshPipParams() }

        // Home-screen widgets draw from a snapshot on disk; this keeps it
        // current for as long as the app is alive.
        widgetPublisher.start(lifecycleScope)

        setContent {
            val config by configStore.config.collectAsState()

            // Start relay service when setup completes (or on subsequent launches).
            // Both full and browse modes start the relay — browse mode only needs the
            // npub to import notes and cache media (no private key required).
            LaunchedEffect(config.hasCompletedSetup) {
                if (config.hasCompletedSetup) {
                    RelayForegroundService.start(this@MainActivity)

                    // Heals accounts whose kind 10050 still advertises 127.0.0.1
                    // from an older build. 10050 is replaceable, so publishing a
                    // clean one overwrites the broken event everywhere — which is
                    // what makes them reachable again, including from senders
                    // still running that build.
                    runCatching { nostrService.republishDMRelayList() }
                }
            }

            NostrVaultTheme(
                // One appearance: OLED black with the orange accent. fromKey
                // maps any retired theme key to the orange default, and oledMode
                // ignores what was saved so an install that had it switched off
                // doesn't come back looking like the old theme.
                appTheme = AppTheme.fromKey(config.themeColor),
                textSizeScale = config.textSizeScale,
                oledMode = true,
                zapsOnlyMode = config.zapsOnlyMode,
            ) {
                Surface(
                    modifier = Modifier.fillMaxSize(),
                    color = Surface0,
                ) {
                    Box(modifier = Modifier.fillMaxSize()) {
                        NostrVaultNavHost(
                            isSetupComplete = config.hasCompletedSetup,
                            configStore = configStore,
                            feedService = feedService,
                            nostrService = nostrService,
                            logStore = logStore,
                            dmUnreadCount = dmService.totalUnreadCountFlow,
                            hasNewRelayActivity = RelayForegroundService.hasNewRelayActivity,
                            notificationManager = notificationManager,
                            pendingPostManager = pendingPostManager,
                        )
                        // Full-screen media viewer overlay — lives in the activity window
                        // (not a Dialog) so Picture-in-Picture can capture the video.
                        FullScreenMediaHost()
                    }
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleShareIntent(intent)
        handleDeepLinkIntent(intent)
    }

    /**
     * Route a tap that started (or resumed) the app: a `nostrvault://` link
     * from a widget, a `nostr:` link handed over by another app, or the extras
     * on a notification's PendingIntent.
     *
     * The extras had been set on that intent for a while with nothing reading
     * them, so tapping a mention opened the app wherever it last was. All three
     * sources go through [DeepLinkRouter]; the nav host does the navigating.
     */
    private fun handleDeepLinkIntent(intent: Intent?) {
        if (intent == null) return

        val fromNotification = DeepLinkRouter.fromNotification(
            type = intent.getStringExtra("notif_type"),
            eventId = intent.getStringExtra("notif_event_id"),
            author = intent.getStringExtra("notif_author"),
            npub = intent.getStringExtra("notif_npub"),
        )
        if (fromNotification != null) {
            // Consumed: a rotation re-delivers the same intent, and without this
            // the app would jump back to the note every time.
            intent.removeExtra("notif_type")
            PendingDeepLink.post(fromNotification)
            return
        }

        if (intent.action != Intent.ACTION_VIEW) return
        val data = intent.data?.toString() ?: return
        DeepLinkRouter.fromUri(data, BridgeEntityDecoder)?.let {
            intent.data = null
            PendingDeepLink.post(it)
        }
    }

    /** Request POST_NOTIFICATIONS on Android 13+ if not already granted. */
    private fun requestNotificationPermissionIfNeeded() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            return
        }
        notificationPermissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
    }

    /**
     * Receive image/video shared from another app via the system share sheet and
     * push it to Blossom. Supports single (ACTION_SEND) and multi (ACTION_SEND_MULTIPLE)
     * shares. Uploads run in the app-scoped [MediaUploadManager] with notification
     * feedback, serialized so external signers (Amber) aren't hit concurrently.
     */
    private fun handleShareIntent(intent: Intent?) {
        if (intent == null) return
        val action = intent.action
        if (action != Intent.ACTION_SEND && action != Intent.ACTION_SEND_MULTIPLE) return

        val type = intent.type ?: return
        if (!type.startsWith("image/") && !type.startsWith("video/")) {
            notificationManager.showError("Only images and videos can be uploaded")
            return
        }

        if (!configStore.config.value.hasCompletedSetup) {
            notificationManager.showError("Finish setup before uploading media")
            return
        }

        val uris: List<Uri> = when (action) {
            Intent.ACTION_SEND -> listOfNotNull(
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
                } else {
                    @Suppress("DEPRECATION") intent.getParcelableExtra(Intent.EXTRA_STREAM)
                }
            )
            Intent.ACTION_SEND_MULTIPLE -> (
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
                } else {
                    @Suppress("DEPRECATION") intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)
                }
            ) ?: emptyList()
            else -> emptyList()
        }

        if (uris.isEmpty()) return
        uris.forEach { mediaUploadManager.upload(it, contentResolver) }
        notificationManager.showToast(
            if (uris.size == 1) "Uploading to Blossom…" else "Uploading ${uris.size} files to Blossom…"
        )
    }

    // ---- Picture-in-Picture ----

    private val hasPipFeature: Boolean
        get() = packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)

    private fun pipParams(): PictureInPictureParams {
        val builder = PictureInPictureParams.Builder()
        VideoPiPBridge.aspectRatio?.let { builder.setAspectRatio(it) }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            // Swiping home while a full-screen video plays pops it into PiP automatically
            builder.setAutoEnterEnabled(VideoPiPBridge.hasActiveVideo)
        }
        return builder.build()
    }

    private fun refreshPipParams() {
        if (!hasPipFeature) return
        runCatching { setPictureInPictureParams(pipParams()) }
    }

    /** Manual PiP entry, called from the video player's PiP button. */
    fun enterVideoPiP() {
        if (!hasPipFeature || !VideoPiPBridge.hasActiveVideo) return
        runCatching { enterPictureInPictureMode(pipParams()) }
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        // Pre-Android 12 has no auto-enter param — enter PiP by hand on home-press.
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S &&
            hasPipFeature && VideoPiPBridge.hasActiveVideo
        ) {
            runCatching { enterPictureInPictureMode(pipParams()) }
        }
    }

    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: Configuration,
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        VideoPiPBridge.isInPiP.value = isInPictureInPictureMode
        // Leaving PiP while the activity is not visible means the PiP window was
        // closed (not expanded back) — stop playback so audio doesn't continue.
        if (!isInPictureInPictureMode &&
            !lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED)
        ) {
            VideoPiPBridge.pauseActive()
        }
    }

    override fun onStop() {
        super.onStop()
        localNotificationService.appInForeground = false
        // Entering PiP pauses but does not stop the activity, so this only runs on a
        // real background transition: snapshot the feed and disconnect WebSockets.
        // The Go relay keeps running via the foreground service.
        if (configStore.config.value.hasCompletedSetup) {
            feedService.pauseFeed()
        }
    }

    override fun onStart() {
        super.onStart()
        localNotificationService.appInForeground = true
        // Restore the snapshot for instant UI, then reconnect in the background.
        if (configStore.config.value.hasCompletedSetup) {
            feedService.resumeFeed()
            // Start DM listeners once, then catch up from external relays each
            // time the app returns to the foreground.
            dmService.startIfNeeded()
            dmService.syncOnForeground()
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        AmberResultBridge.detach()
    }
}
