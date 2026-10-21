package com.nostrvault.service

import com.nostrvault.data.model.ReturnSummary
import com.nostrvault.data.model.ReturnWindow
import com.nostrvault.ui.navigation.DeepLinkTarget
import com.nostrvault.ui.navigation.PendingDeepLink
import com.nostrvault.ui.navigation.Screen
import com.nostrvault.ui.navigation.VaultSection
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/**
 * The one pill for what came in while the app was away (iOS
 * `ReturnPillManager`). The app coming back from the background opens a
 * [ReturnWindow]; every arrival pill raised inside it is counted here instead
 * of getting a top pill and a sound of its own, and the first one puts up a
 * single bottom pill, with one sound, pointing at the Vault. Tapping it opens
 * the Vault. Once the window closes, arrivals get the ordinary top pill again.
 */
object ReturnPillManager {
    /** How an arrival pill went. */
    enum class Gathered {
        /** Not gathering: show the ordinary top pill. */
        NO,
        /** Counted, and it is the first: play the one sound. */
        FIRST,
        /** Counted, silently. */
        ADDED,
    }

    /** What the pill says; a new value each time it changes. */
    private val _text = MutableStateFlow("")
    val text: StateFlow<String> = _text.asStateFlow()
    private val _spoken = MutableStateFlow("")
    val spoken: StateFlow<String> = _spoken.asStateFlow()
    private val _isShowing = MutableStateFlow(false)
    val isShowing: StateFlow<Boolean> = _isShowing.asStateFlow()

    private val lock = Any()
    private var window: ReturnWindow? = null
    private var summary = ReturnSummary()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var hideJob: Job? = null
    private var followerSerial = 0L

    /** The app is back from the background (or has just launched): start gathering. A pill still up goes. */
    fun beginReturn(now: Long = System.currentTimeMillis()) = synchronized(lock) {
        hideJob?.cancel()
        window = ReturnWindow(now)
        summary = ReturnSummary()
        publish()
        _isShowing.value = false
    }

    /** The app left the foreground: nothing more is gathered into a pill nobody can see. */
    fun endReturn() = synchronized(lock) {
        hideJob?.cancel()
        window = null
        _isShowing.value = false
    }

    /**
     * Called for every arrival pill before it is shown. [createdAt] is the
     * event's own time in epoch ms, when known (see [ReturnWindow.arrive]).
     */
    fun gather(type: String, key: String, createdAt: Long? = null, now: Long = System.currentTimeMillis()): Gathered =
        synchronized(lock) {
            val w = window ?: return Gathered.NO
            if (!w.arrive(now, createdAt)) return Gathered.NO
            val first = summary.isEmpty
            // The folded strangers' alert keeps one id however many follow, and
            // each call is one more stranger, so each counts.
            summary.add(type, if (type == "followers") "followers-${followerSerial++}" else key)
            publish()
            _isShowing.value = true
            scheduleHide(w, now)
            if (first) Gathered.FIRST else Gathered.ADDED
        }

    /** The pill was tapped: open the Vault's "Vault" list, everything new. */
    fun open() {
        endReturn()
        VaultSection.showActivity()
        PendingDeepLink.post(DeepLinkTarget(Screen.Dashboard.route))
    }

    private fun publish() {
        _text.value = summary.text
        _spoken.value = summary.spokenText
    }

    private fun scheduleHide(w: ReturnWindow, now: Long) {
        val until = w.showsUntil ?: return
        hideJob?.cancel()
        hideJob = scope.launch {
            delay(maxOf(0L, until - now))
            synchronized(lock) { if (window === w) _isShowing.value = false }
        }
    }
}
