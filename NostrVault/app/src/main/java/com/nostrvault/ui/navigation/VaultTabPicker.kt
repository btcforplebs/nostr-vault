package com.nostrvault.ui.navigation

import androidx.compose.runtime.Composable
import androidx.compose.runtime.Stable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import com.nostrvault.data.model.VaultMode
import com.nostrvault.relay.RelayForegroundService
import com.nostrvault.ui.screens.icon
import kotlinx.coroutines.flow.MutableStateFlow

/**
 * Hold the Vault tab, slide onto one of its pages (Vault, Notes, Articles,
 * Highlights, Media, Likes, Zaps, Followers), let go: that page opens. Same
 * order and red dots as the mode pill; Likes is left out in Zaps Only. The
 * gesture and the menu are the shared dock engine ([DockHoldMenu]).
 * iOS: VaultTabHoldItem.swift (#1505).
 */
@Stable
object VaultTabPicker {
    /** The menu, lined up with the Vault tab's right edge. */
    val menu = DockHoldMenu<VaultMode>(alignEnd = true)

    val isOpen: Boolean get() = menu.isOpen

    /** The page on screen, reported by the Vault tab; drives the checkmark. */
    var shownMode by mutableStateOf<VaultMode?>(null)

    /** The lists' own new-item dots, reported by the Vault tab once it has been built. */
    var listDots by mutableStateOf<Set<VaultMode>>(emptySet())

    /**
     * A pick waiting for the Vault tab to apply it. Its lists live in the
     * tab's own ViewModel, which does not exist on a first visit, so the pick
     * is parked here until the tab takes it.
     */
    val request = MutableStateFlow<VaultMode?>(null)

    /** The pages with something new: the lists' dots and what lit the tab's dot. */
    fun news(relayNews: Set<VaultMode>, zapsOnly: Boolean): Set<VaultMode> =
        (listDots + relayNews).filterNot { zapsOnly && it == VaultMode.LIKES }.toSet()
}

/** The Vault menu, over the whole window above the bar. */
@Composable
fun VaultTabPickerOverlay(
    zapsOnly: Boolean,
    onPick: (VaultMode) -> Unit,
    modifier: Modifier = Modifier,
) {
    val relayNews by RelayForegroundService.newActivityModes.collectAsState()
    val news = VaultTabPicker.news(relayNews, zapsOnly)
    DockHoldMenuOverlay(
        menu = VaultTabPicker.menu,
        items = VaultMode.menu(zapsOnly),
        row = { m ->
            DockHoldRow(m.icon, m.displayName, current = VaultTabPicker.shownMode == m, hasNews = m in news)
        },
        closeLabel = "Close Vault pages",
        onPick = onPick,
        modifier = modifier,
    )
}
