package com.nostrvault.ui.screens.dm

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.ui.theme.SecondaryGroupedBg
import com.nostrvault.ui.theme.SecondaryText

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

/**
 * Replaces the message box on an account that has no key on this device. Sending
 * would throw and reading decrypts nothing, so saying why beats an empty thread
 * with a live-looking composer.
 */
@Composable
internal fun DMUnavailableNotice(reason: String) {
    Surface(color = SecondaryGroupedBg, tonalElevation = 2.dp) {
        Column(modifier = Modifier.navigationBarsPadding()) {
            Text(
                text = reason,
                color = SecondaryText,
                fontSize = 13.sp,
                textAlign = TextAlign.Center,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 20.dp, vertical = 14.dp),
            )
        }
    }
}
