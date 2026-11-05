package com.nostrvault.ui.screens

import android.content.Context
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.di.ApplicationScope
import com.nostrvault.relay.MacSync
import com.nostrvault.service.ListHistoryScan
import com.nostrvault.service.RelayImportService
import com.nostrvault.ui.notification.NotificationManager
import com.nostrvault.ui.notification.PillTone
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Watches the copy from the linked Mac after setup (§5a): the relay's own Mac sync pulls the full history once it
 * starts, writing mac_sync_status.json. The copy doesn't hold the person in setup; when it stalls for 2 minutes or
 * fails, this falls back quietly to the relay import, with one plain line. The dashboard shows the copy itself.
 */
@Singleton
class BringItOverCopyWatcher @Inject constructor(
    private val configStore: ConfigStore,
    private val relayImportService: RelayImportService,
    private val notificationManager: NotificationManager,
    @ApplicationContext private val appContext: Context,
    @ApplicationScope private val appScope: CoroutineScope,
) {
    private val _copy = MutableStateFlow<BringItOver.Copy?>(null)
    /** The copy as last judged; null while nothing is being watched. */
    val copy: StateFlow<BringItOver.Copy?> = _copy.asStateFlow()

    private var job: Job? = null

    /** Start watching from [linkedAt] (unix seconds): the moment setup finished with a Mac linked. */
    fun watch(linkedAt: Long) {
        job?.cancel()
        _copy.value = BringItOver.Copy.Going
        job = appScope.launch {
            var lastKey: Pair<Int, Long>? = null
            var lastProgressAt = linkedAt
            while (true) {
                delay(POLL_MS)
                val status = withContext(Dispatchers.IO) { MacSync.read(relayDataDir()) }
                val now = System.currentTimeMillis() / 1000
                val key = BringItOver.progressKey(status)
                if (key != null && key != lastKey && (status?.startedAt ?: 0) >= linkedAt - 5) {
                    lastKey = key
                    lastProgressAt = now
                }
                when (val judged = BringItOver.judge(status, linkedAt, lastProgressAt, now)) {
                    BringItOver.Copy.Going -> _copy.value = judged
                    is BringItOver.Copy.Done -> { _copy.value = judged; return@launch }
                    BringItOver.Copy.Stalled -> {
                        _copy.value = judged
                        notificationManager.showToast(BringItOver.FALLBACK_LINE, PillTone.NEUTRAL)
                        relayImportService.importNotes(listHistory = ListHistoryScan.DEFAULT_ON)
                        return@launch
                    }
                }
            }
        }
    }

    private fun relayDataDir(): File =
        configStore.config.value.relayDataDir?.let(::File) ?: File(appContext.filesDir, "relay_data")

    private companion object {
        const val POLL_MS = 5_000L
    }
}
