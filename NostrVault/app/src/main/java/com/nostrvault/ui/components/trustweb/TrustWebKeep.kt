package com.nostrvault.ui.components

import androidx.compose.runtime.Composable
import androidx.compose.runtime.MutableState
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.lifecycle.ViewModel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel

/**
 * The WOT tab's globe and everything around it, kept in the tab's back-stack
 * entry so leaving the tab and coming back shows the same globe at once
 * instead of building it again. iOS keeps WOTTabView alive the same way.
 * Work started on the tab (a refresh, someone's web) runs on in [scope] while
 * you are away, so new data still lands.
 */
internal class TrustWebKeep : ViewModel() {
    private var owner: String? = null
    private val slots = HashMap<String, Any>()
    var scope = newScope()
        private set

    /** A new account starts from nothing: its globe is a different web. */
    fun account(me: String) {
        if (owner == me) return
        owner = me
        slots.clear()
        scope.cancel()
        scope = newScope()
    }

    @Suppress("UNCHECKED_CAST")
    fun <T : Any> slot(name: String, init: () -> T): T = slots.getOrPut(name, init) as T

    override fun onCleared() = scope.cancel()

    private fun newScope() = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
}

/** The WOT tab's keep; null on a post's or a profile's globe, which start fresh each time. */
internal val LocalTrustWebKeep = staticCompositionLocalOf<TrustWebKeep?> { null }

/** [init] kept in the WOT tab's keep under [name], or remembered as usual off the tab. */
@Composable
internal fun <T : Any> rememberKept(name: String, init: () -> T): T {
    val keep = LocalTrustWebKeep.current
    return remember(keep) { keep?.slot(name, init) ?: init() }
}

/** A `remember { mutableStateOf(init()) }` that the WOT tab keeps across tab switches. */
@Composable
internal fun <T> keptState(name: String, init: () -> T): MutableState<T> =
    rememberKept(name) { mutableStateOf(init()) }
