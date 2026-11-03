package com.nostrvault.ui.components

import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.unit.dp
import com.nostrvault.ui.theme.NostrVaultIcons
import com.nostrvault.ui.theme.SecondaryText

/**
 * Unread messages and the way to the inbox. Messages is a page in the Vault
 * menu, not a toolbar button (Logen 2026-11-03): the mode pill's dropdown
 * lists it with this count.
 */
data class VaultMessages(val unread: Int, val open: () -> Unit) {
    /** The menu row's count: null at 0, capped at "99+". */
    val badge: String? get() = when {
        unread <= 0 -> null
        unread > 99 -> "99+"
        else -> unread.toString()
    }
}

/** Provided by the Vault tab, so its mode pill can offer Messages. */
val LocalVaultMessages = compositionLocalOf<VaultMessages?> { null }

/**
 * The Vault tab's right pill: search, then this mode's filters as bare
 * icons. iOS `trailingToolbarInline`.
 */
@Composable
fun VaultRightPill(
    modifier: Modifier = Modifier,
    filters: (@Composable RowScope.() -> Unit)? = null,
) {
    val openSearch = com.nostrvault.ui.screens.vault.LocalOpenVaultSearch.current
    GlassPill(modifier = modifier) {
        // The Vault's search opens out of this glass (iOS `searchToggleButton`).
        if (openSearch != null) {
            IconButton(onClick = openSearch, modifier = Modifier.size(36.dp)) {
                Icon(NostrVaultIcons.Search, contentDescription = "Search your Vault", tint = SecondaryText,
                    modifier = Modifier.size(20.dp))
            }
        }
        filters?.invoke(this)
    }
}

/**
 * "Mentions · 18", or [empty] rather than a 0. A list that stopped at its
 * page size says so with a "+". iOS `filterNoteText`.
 */
fun countNote(icon: ImageVector, name: String, count: Int, capped: Boolean, empty: String): FilterNote =
    FilterNote(icon, if (count == 0) empty else "$name · %,d%s".format(count, if (capped) "+" else ""))
