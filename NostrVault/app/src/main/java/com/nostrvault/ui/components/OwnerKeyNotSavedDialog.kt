package com.nostrvault.ui.components

import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue

/**
 * Shown while [notSaved]: the phone's secure key storage would not take the
 * account's key, so it is only in memory and gone when the app closes. The
 * key is never written to the config file instead (ConfigStore.ownerKeyNotSaved).
 * Comes back if the key goes unsaved again after it was saved.
 */
@Composable
fun OwnerKeyNotSavedDialog(notSaved: Boolean) {
    var dismissed by remember { mutableStateOf(false) }
    LaunchedEffect(notSaved) { if (!notSaved) dismissed = false }
    if (!notSaved || dismissed) return
    AlertDialog(
        onDismissRequest = { dismissed = true },
        title = { Text("Your key isn't saved on this phone") },
        text = {
            Text(
                "This phone's secure key storage didn't take your key, so it is only kept until the app closes. " +
                    "Keep your nsec or your encrypted key and password: you'll need one to sign in again.",
            )
        },
        confirmButton = { TextButton(onClick = { dismissed = true }) { Text("OK") } },
    )
}
