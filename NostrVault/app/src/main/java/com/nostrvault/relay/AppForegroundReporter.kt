package com.nostrvault.relay

import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner

/**
 * Reports to the relay whether the app is on screen, from the process
 * lifecycle: started = on screen, stopped = background.
 *
 * It reports background as soon as it is registered, before any activity has
 * started, so a relay that starts with no UI (boot, a widget) doesn't run its
 * screen-only work until someone opens the app.
 */
class AppForegroundReporter(private val report: (Boolean) -> Unit) : DefaultLifecycleObserver {
    override fun onCreate(owner: LifecycleOwner) = report(false)
    override fun onStart(owner: LifecycleOwner) = report(true)
    override fun onStop(owner: LifecycleOwner) = report(false)
}
