package com.nostrvault.ui.screens.dm

import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable

/**
 * A DM that could not be sent. Same alert as iOS (DMThreadView and
 * DMInboxView): "Failed to Send", the error's text, and OK. The screen puts
 * the message back in the box so nothing typed is lost.
 */
object DMSendFailure {
    const val TITLE = "Failed to Send"

    /** The photo never reached a Blossom server, so sending stops before the text goes out. */
    const val PHOTO_UPLOAD_FAILED = "Couldn't upload that photo."

    private const val FALLBACK = "The message could not be sent."

    /** The alert's message for [error]: its own text, or a plain fallback when it has none. */
    fun message(error: Throwable): String =
        error.message?.trim()?.takeIf { it.isNotEmpty() } ?: FALLBACK
}

/** Thrown when a DM's photo could not be uploaded. */
class DMPhotoUploadException : Exception(DMSendFailure.PHOTO_UPLOAD_FAILED)

@Composable
internal fun DMSendFailedDialog(message: String, onDismiss: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(DMSendFailure.TITLE) },
        text = { Text(message) },
        confirmButton = {
            TextButton(onClick = onDismiss) { Text("OK") }
        },
    )
}
