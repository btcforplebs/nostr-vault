package com.nostrvault.ui.components

import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import com.nostrvault.ui.theme.ErrorRed

/**
 * One confirmation treatment for every action that cannot be undone.
 *
 * The shape of the question is fixed rather than left to each call site:
 *
 * - the **title** repeats the button that opened it, so you can tell which
 *   control you actually hit;
 * - the **consequence** is one plain sentence about what you lose, and it
 *   carries the amount whenever money moves — a payment confirmation that
 *   does not show the number is not a confirmation, since a bolt11 string is
 *   opaque;
 * - **Cancel is the easy way out**: back gesture and outside tap both dismiss,
 *   and the destructive verb is the only thing that commits.
 *
 * Mirrors `confirmDestructive` on the Swift side.
 *
 * @param confirmLabel the destructive verb. Not "OK".
 */
@Composable
fun DestructiveConfirmDialog(
    title: String,
    consequence: String,
    confirmLabel: String,
    onConfirm: () -> Unit,
    onDismiss: () -> Unit,
    cancelLabel: String = "Cancel",
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = { Text(consequence) },
        confirmButton = {
            TextButton(onClick = {
                onDismiss()
                onConfirm()
            }) { Text(confirmLabel, color = ErrorRed) }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text(cancelLabel) }
        },
    )
}
