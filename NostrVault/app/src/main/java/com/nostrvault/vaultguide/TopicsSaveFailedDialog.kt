package com.nostrvault.vaultguide

import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue

/**
 * "Couldn't save" over the guide's topics card when "Show posts" couldn't
 * save the picked hashtags ([FillYourVaultCoordinator.topicsError]). The
 * picks stay ticked, so Show posts tries again. Same words as the hashtag
 * feed's Follow ([com.nostrvault.service.InterestListService.failedText]).
 */
@Composable
internal fun TopicsSaveFailedDialog() {
    val error by FillYourVaultCoordinator.topicsError.collectAsState()
    val text = error ?: return
    AlertDialog(
        onDismissRequest = FillYourVaultCoordinator::clearTopicsError,
        title = { Text("Couldn't save") },
        text = { Text(text) },
        confirmButton = { TextButton(onClick = FillYourVaultCoordinator::clearTopicsError) { Text("OK") } },
    )
}
