package com.nostrvault.ui.components

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.unit.dp
import com.nostrvault.ui.theme.ErrorRed
import com.nostrvault.ui.theme.NostrVaultIcons
import com.nostrvault.ui.theme.SecondaryText

/** Unread messages and the way to the inbox, for the Vault tab's right pill. */
data class VaultMessages(val unread: Int, val open: () -> Unit)

/** Provided by the Vault tab, so each of its screens can lead with ✉️. */
val LocalVaultMessages = compositionLocalOf<VaultMessages?> { null }

/**
 * The Vault tab's right pill: Messages, a line, this mode's filters as bare
 * icons, a line, then search at the right end. Media has no filters, so
 * Messages and search. iOS `trailingToolbarInline` + `VaultMessagesButton`.
 */
@Composable
fun VaultRightPill(
    modifier: Modifier = Modifier,
    filters: (@Composable RowScope.() -> Unit)? = null,
) {
    val messages = LocalVaultMessages.current
    val openSearch = com.nostrvault.ui.screens.vault.LocalOpenVaultSearch.current
    GlassPill(modifier = modifier) {
        if (messages != null) VaultMessagesButton(messages)
        if (filters != null) {
            if (messages != null) PillDivider()
            filters()
        }
        // The Vault's search opens out of this glass (iOS `searchToggleButton`),
        // the same filter button as the rest; grey, as iOS shows it while the
        // search is closed.
        if (openSearch != null) {
            if (messages != null || filters != null) PillDivider()
            com.nostrvault.ui.screens.dashboard.IconFilterButton(
                icon = NostrVaultIcons.Search,
                contentDescription = "Search your Vault",
                isSelected = false,
                onClick = openSearch,
            )
        }
    }
}

/** The thin line between the pill's groups (iOS `Divider().frame(height: 20)`). */
@Composable
private fun PillDivider() {
    Box(
        Modifier
            .padding(horizontal = 2.dp)
            .width(1.dp)
            .height(20.dp)
            .background(Color.White.copy(alpha = 0.18f)),
    )
}

/** The envelope: opens the inbox, with a red dot while a message is unread. */
@Composable
fun VaultMessagesButton(messages: VaultMessages) {
    Box {
        IconButton(onClick = messages.open, modifier = Modifier.size(36.dp)) {
            Icon(
                NostrVaultIcons.Messages,
                contentDescription = if (messages.unread > 0) "Messages, ${messages.unread} unread" else "Messages",
                tint = SecondaryText,
                modifier = Modifier.size(20.dp),
            )
        }
        AnimatedVisibility(
            visible = messages.unread > 0,
            enter = scaleIn() + fadeIn(),
            exit = scaleOut() + fadeOut(),
            modifier = Modifier.align(Alignment.TopEnd).offset(x = (-5).dp, y = 6.dp),
        ) {
            Box(Modifier.size(8.dp).background(ErrorRed, CircleShape))
        }
    }
}

/**
 * What the filter shows, that it's on, then how many: "Mentions · on · 18",
 * "none yet" rather than a 0. A list that stopped at its page size says so
 * with a "+". iOS `filterNoteText`.
 */
fun countNote(icon: ImageVector, name: String, count: Int, capped: Boolean): FilterNote =
    FilterNote.setting(icon, name, "on", countTally(count, capped))

/** A pick whose list is still being rebuilt: "Mentions · on", its count to follow. */
fun pickedNote(icon: ImageVector, name: String): FilterNote = FilterNote.setting(icon, name, "on")

/** "18", "500+", or "none yet". */
internal fun countTally(count: Int, capped: Boolean): String =
    if (count == 0) "none yet" else "%,d%s".format(count, if (capped) "+" else "")
