package com.nostrvault

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.Surface
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.relay.LogStore
import com.nostrvault.relay.RelayForegroundService
import com.nostrvault.service.AmberResultBridge
import com.nostrvault.service.DMService
import com.nostrvault.service.FeedService
import com.nostrvault.service.MediaUploadManager
import com.nostrvault.service.LocalNotificationService
import com.nostrvault.service.NostrService
import com.nostrvault.service.PendingPostManager
import com.nostrvault.ui.navigation.NostrVaultNavHost
import com.nostrvault.ui.notification.NotificationManager
import com.nostrvault.ui.theme.NostrVaultTheme
import com.nostrvault.ui.theme.WindowBackground
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
    @Inject lateinit var notificationManager: NotificationManager
    @Inject lateinit var pendingPostManager: PendingPostManager
    @Inject lateinit var mediaUploadManager: MediaUploadManager

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

        // Handle media shared into the app via the system share sheet (ACTION_SEND)
        handleShareIntent(intent)

        setContent {
            val config by configStore.config.collectAsState()

            // Start relay service when setup completes (or on subsequent launches).
            // Both full and browse modes start the relay — browse mode only needs the
            // npub to import notes and cache media (no private key required).
            LaunchedEffect(config.hasCompletedSetup) {
                if (config.hasCompletedSetup) {
                    RelayForegroundService.start(this@MainActivity)
                }
            }

            NostrVaultTheme {
                Surface(
                    modifier = Modifier.fillMaxSize(),
                    color = WindowBackground,
                ) {
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
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleShareIntent(intent)
    }

    override fun onResume() {
        super.onResume()
        // App is on screen: suppress system notifications (the in-app dot covers it).
        LocalNotificationService.appInForeground = true
    }

    override fun onPause() {
        super.onPause()
        LocalNotificationService.appInForeground = false
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

    override fun onStop() {
        super.onStop()
        // Snapshot the feed and disconnect WebSockets when the app goes to background.
        // The Go relay keeps running via the foreground service.
        if (configStore.config.value.hasCompletedSetup) {
            feedService.pauseFeed()
        }
    }

    override fun onStart() {
        super.onStart()
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
