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
import com.nostrvault.ui.theme.NostrVaultIcons
import kotlinx.coroutines.flow.MutableStateFlow

/**
 * Hold the Vault tab, slide onto one of its pages (Vault, Notes, Articles,
 * Highlights, Media, Likes, Zaps, Followers), let go: that page opens. Same
 * order and red dots as the mode pill; Likes is left out in Zaps Only.
 * Messages is the top row and opens the inbox (Logen 2026-11-02). The
 * gesture and the menu are the shared dock engine ([DockHoldMenu]).
 * iOS: VaultTabHoldItem.swift (#1505).
 */
/** A row of the Vault tab's hold menu: one of its pages, or the inbox. */
sealed interface VaultPick {
    data class Page(val mode: VaultMode) : VaultPick
    data object Messages : VaultPick
}

@Stable
object VaultTabPicker {
    /** The menu, on the Vault tab's side of the screen. */
    val menu = DockHoldMenu<VaultPick>()

    /**
     * The rows in menu order. They are drawn bottom-up from the tab, so the
     * pages sit nearest the finger and Messages, last, is the top row.
     */
    fun items(zapsOnly: Boolean): List<VaultPick> =
        VaultMode.menu(zapsOnly).map { VaultPick.Page(it) } + VaultPick.Messages

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
    messagesUnread: Boolean,
    onPick: (VaultPick) -> Unit,
    modifier: Modifier = Modifier,
) {
    val relayNews by RelayForegroundService.newActivityModes.collectAsState()
    val news = VaultTabPicker.news(relayNews, zapsOnly)
    DockHoldMenuOverlay(
        menu = VaultTabPicker.menu,
        items = VaultTabPicker.items(zapsOnly),
        row = { pick ->
            when (pick) {
                is VaultPick.Page -> pick.mode.let { m ->
                    DockHoldRow(m.icon, m.displayName, current = VaultTabPicker.shownMode == m, hasNews = m in news)
                }
                VaultPick.Messages -> DockHoldRow(NostrVaultIcons.Messages, "Messages", current = false, hasNews = messagesUnread)
            }
        },
        closeLabel = "Close Vault pages",
        onPick = onPick,
        modifier = modifier,
    )
}
