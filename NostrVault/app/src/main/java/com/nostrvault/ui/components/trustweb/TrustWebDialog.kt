package com.nostrvault.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.only
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.compose.ui.window.DialogWindowProvider
import com.nostrvault.data.model.TrustMap
import com.nostrvault.data.model.TrustPath
import com.nostrvault.ui.theme.LocalNostrVaultColors
import kotlinx.coroutines.flow.first

/**
 * The Trust Path card opened up into a globe, full screen. Someone sits at the
 * core (you, at first) with everyone they follow as stars on a sphere around
 * them, people further out as a faint outer shell, and the author between the
 * two. Threads run from the core through each person who follows the author.
 * Each star's spot comes from its key ([TrustMap.direction]), so nothing is
 * ever laid out: spinning and zooming only move the camera, and re-centering
 * on someone only changes how far each star sits from the core.
 *
 * With no [initialPath] (the post bar's Web of Trust button) it finds the path
 * the same way the card does first.
 *
 * Port of iOS Views/TrustWebView.swift (TrustWebView and TrustWebSheet).
 */
@Composable
fun TrustWebDialog(
    author: String,
    initialPath: TrustPath?,
    onProfileClick: ((String) -> Unit)?,
    onDismiss: () -> Unit,
) {
    Dialog(
        onDismissRequest = onDismiss,
        properties = DialogProperties(usePlatformDefaultWidth = false),
    ) {
        // A full-width Compose dialog measures its content against the whole
        // display, but its window stops at the status and navigation bars, so
        // the bottom of the globe (the footer buttons) ran off the screen.
        // Size the content to the part of the screen the window can show.
        val view = LocalView.current
        // Black out what shows behind the bars, as the status bar already is.
        SideEffect { (view.parent as? DialogWindowProvider)?.window?.setDimAmount(1f) }
        var visibleHeight by remember { mutableIntStateOf(0) }
        DisposableEffect(view) {
            val frame = android.graphics.Rect()
            val origin = IntArray(2)
            val measure = {
                view.getWindowVisibleDisplayFrame(frame)
                view.getLocationOnScreen(origin)
                visibleHeight = (frame.bottom - origin[1]).coerceAtLeast(0)
            }
            val listener = android.view.View.OnLayoutChangeListener { _, _, _, _, _, _, _, _, _ -> measure() }
            view.addOnLayoutChangeListener(listener)
            measure()
            onDispose { view.removeOnLayoutChangeListener(listener) }
        }
        val size = if (visibleHeight > 0) {
            Modifier.fillMaxWidth().height(with(LocalDensity.current) { visibleHeight.toDp() })
        } else {
            Modifier.fillMaxSize()
        }
        Surface(color = Color.Black, modifier = size) {
            Box(Modifier.fillMaxSize().background(SpaceBrush)) {
                val trust = rememberTrustPathServices().trustPathService()
                var path by remember(author) { mutableStateOf(initialPath) }
                LaunchedEffect(author) {
                    if (path == null) path = trust.path(author)
                }
                val loaded = path
                if (loaded != null) {
                    // Opened over the WOT tab, it starts fresh rather than share the tab's keep.
                    CompositionLocalProvider(LocalTrustWebKeep provides null) {
                        TrustWebContent(
                            author = author,
                            path = loaded,
                            onProfileClick = onProfileClick?.let { open -> { pubkey: String -> onDismiss(); open(pubkey) } },
                            onDismiss = onDismiss,
                        )
                    }
                } else {
                    Column(Modifier.safeDrawingPadding()) {
                        TopBar(title = "Web of Trust", onDone = onDismiss, onList = null)
                        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                            CircularProgressIndicator(color = LocalNostrVaultColors.current.primary)
                        }
                    }
                }
            }
        }
    }
}
