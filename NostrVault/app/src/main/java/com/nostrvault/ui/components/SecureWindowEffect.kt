package com.nostrvault.ui.components

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.view.Window
import android.view.WindowManager
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.ui.platform.LocalContext
import java.util.WeakHashMap

/**
 * Keeps the window out of screenshots, screen recording and the Recents thumbnail
 * (FLAG_SECURE) while a secret key is on screen, and lets it go when the key leaves.
 * [enabled] false is the same as not being there: a field that only sometimes holds an nsec.
 */
@Composable
fun SecureWindowEffect(enabled: Boolean = true) {
    val activity = LocalContext.current.findActivity()
    DisposableEffect(activity, enabled) {
        val window = activity?.window
        if (!enabled || window == null) return@DisposableEffect onDispose {}
        val holders = SecureWindows.holdersFor(window)
        if (holders.acquire()) window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        onDispose { if (holders.release()) window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE) }
    }
}

/** True when [text] holds an nsec, as a pasted or typed field shows it in full. */
internal fun showsSecretKey(text: String): Boolean = text.trim().startsWith("nsec1", ignoreCase = true)

/**
 * How many secret-key screens hold one window secure. Two can be up at once (a revealed key and an
 * Add Account field holding an nsec): the first sets the flag, the last one leaving clears it.
 */
internal class SecureHolders {
    private var count = 0

    /** True when this is the first holder: set the flag. */
    fun acquire(): Boolean = ++count == 1

    /** True when this was the last holder: clear the flag. A release with none held does nothing. */
    fun release(): Boolean {
        if (count == 0) return false
        count--
        return count == 0
    }
}

/** One [SecureHolders] per window. Compose effects run on the main thread only. */
private object SecureWindows {
    private val byWindow = WeakHashMap<Window, SecureHolders>()
    fun holdersFor(window: Window): SecureHolders = byWindow.getOrPut(window) { SecureHolders() }
}

private tailrec fun Context.findActivity(): Activity? = when (this) {
    is Activity -> this
    is ContextWrapper -> baseContext.findActivity()
    else -> null
}
