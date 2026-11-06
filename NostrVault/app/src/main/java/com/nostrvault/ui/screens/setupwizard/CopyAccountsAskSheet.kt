package com.nostrvault.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.nostrvault.fips.CopyAccountsSync

/**
 * The ask as a sheet over the app, once setup is done, whenever a copy or catch-up left accounts to ask about.
 * It only closes through an answer, so nothing is settled by a stray tap. Twin of iOS `CopyAccountsAskSheet`.
 */
@Composable
fun CopyAccountsAskSheet(sync: CopyAccountsSync, enabled: Boolean) {
    val offered by sync.offered.collectAsState()
    if (!enabled || offered.isEmpty()) return
    Dialog(
        onDismissRequest = {},
        properties = DialogProperties(dismissOnBackPress = false, dismissOnClickOutside = false, usePlatformDefaultWidth = false),
    ) {
        androidx.compose.foundation.layout.Box(
            Modifier.padding(16.dp).fillMaxWidth().background(WizardBgPrimary, RoundedCornerShape(16.dp)),
        ) {
            CopyAccountsAskView(offered) { ticked -> sync.answer(ticked) }
        }
    }
}
