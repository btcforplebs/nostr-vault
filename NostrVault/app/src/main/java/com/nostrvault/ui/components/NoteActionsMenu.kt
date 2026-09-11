package com.nostrvault.ui.components

import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import com.nostrvault.ui.theme.ErrorRed
import com.nostrvault.ui.theme.PrimaryText

/**
 * One item in a note's overflow menu.
 *
 * [destructive] only colours the row; it carries no confirmation of its own.
 * Anything that needs one still opens its dialog from [onClick], because the
 * confirmation belongs to the action, not to the menu that launched it.
 */
@Immutable
data class NoteAction(
    val icon: ImageVector,
    val label: String,
    val destructive: Boolean = false,
    val onClick: () -> Unit,
)

/**
 * The overflow menu for a note. One definition, anchored to the button that
 * opened it.
 *
 * There were two of these: an anchored [DropdownMenu] on the focused note in
 * `NoteDetailScreen` and an `AlertDialog` in `FeedScreen` — same gesture, same
 * screen once replies got a menu, two patterns. The anchored menu is the one
 * that survived: it is Material's overflow affordance, and it keeps the
 * connection to the note you tapped, which a modal dialog loses. (That lost
 * anchor is also why the dialog's Cancel had drifted into `confirmButton`.)
 *
 * The item set is a parameter because it legitimately differs by surface — the
 * focused note can follow and unfollow its author, a search result can only
 * copy a link. What must not differ is the presentation, which is here.
 */
@Composable
fun NoteActionsMenu(
    expanded: Boolean,
    actions: List<NoteAction>,
    onDismiss: () -> Unit,
) {
    DropdownMenu(expanded = expanded, onDismissRequest = onDismiss) {
        for (action in actions) {
            val tint: Color = if (action.destructive) ErrorRed else PrimaryText
            DropdownMenuItem(
                text = { Text(action.label, color = tint) },
                onClick = {
                    onDismiss()
                    action.onClick()
                },
                leadingIcon = { Icon(action.icon, contentDescription = null, tint = tint) },
            )
        }
    }
}
