package com.nostrvault.data.remote

/**
 * Whether any of the app's activities is on screen, from the process
 * lifecycle ([com.nostrvault.relay.AppForegroundReporter]). Relay sockets
 * read it to back off harder and to stop redialling in the background.
 *
 * True until the first report, so code and tests that never register the
 * observer keep the on-screen behaviour.
 */
object AppOnScreen {
    @Volatile
    var onScreen: Boolean = true
        private set

    private val listeners = java.util.concurrent.CopyOnWriteArrayList<(Boolean) -> Unit>()

    /** Called on every change, on the reporting thread (main). */
    fun addListener(listener: (Boolean) -> Unit) { listeners += listener }

    fun set(on: Boolean) {
        if (onScreen == on) return
        onScreen = on
        listeners.forEach { it(on) }
    }

    internal fun setForTest(on: Boolean) { onScreen = on }
}
