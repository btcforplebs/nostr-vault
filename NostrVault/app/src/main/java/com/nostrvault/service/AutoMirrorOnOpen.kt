package com.nostrvault.service

import com.nostrvault.data.local.ConfigStore
import com.nostrvault.di.ApplicationScope
import com.nostrvault.relay.RelayForegroundService
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.launch
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Auto-Mirror runs when the app opens, not only when the Media tab does
 * (Logen 2026-11-11), so a file mirrored from another device is on this one
 * without visiting the tab. An open while the relay isn't serving yet waits
 * for it: the run stores into this phone's vault and would only fail. A relay
 * restart on its own is not an open. Every open asks; the 3 hour rule in
 * [BlossomService.runAutoMirrorIfDue] decides. iOS twin: Ted's.
 */
internal class AutoMirrorOnOpenRule(
    private val enabled: () -> Boolean,
    private val relayReady: () -> Boolean,
    private val runIfDue: () -> Boolean,
) {
    private var pending = false

    @Synchronized
    fun appOpened() {
        pending = true
        tryRun()
    }

    @Synchronized
    fun relayCameUp() = tryRun()

    private fun tryRun() {
        if (!pending) return
        if (!enabled()) {
            pending = false
            return
        }
        if (!relayReady()) return
        pending = false
        runIfDue()
    }
}

@Singleton
class AutoMirrorOnOpen @Inject constructor(
    private val configStore: ConfigStore,
    private val blossom: BlossomService,
    @ApplicationScope private val scope: CoroutineScope,
) {
    private val rule = AutoMirrorOnOpenRule(
        enabled = { configStore.config.value.autoMirrorMedia },
        relayReady = { RelayForegroundService.readyForConnections.value },
        runIfDue = { blossom.runAutoMirrorIfDue() },
    )

    /** Listens for the relay serving, for an open that came before it. */
    fun start() {
        scope.launch {
            RelayForegroundService.readyForConnections.filter { it }.collect { rule.relayCameUp() }
        }
    }

    /** The app came on screen (NostrVaultApp's foreground observer). */
    fun onForeground() = rule.appOpened()
}
