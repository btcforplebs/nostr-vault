package com.nostrvault.ui.screens

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.ui.screens.settings.SECRET_CLIP_LIFETIME_MS
import com.nostrvault.ui.screens.settings.copySecretKey
import com.nostrvault.ui.theme.*
import kotlinx.coroutines.delay

/**
 * The key steps' Copy button (This key is you, Back up your key). A full
 * outlined button so it is seen, not a text link under Next (Logen
 * 2026-11-22: "needs a copy button"). The nsec goes on the clipboard marked
 * sensitive and is taken off after [SECRET_CLIP_LIFETIME_MS] ([copySecretKey]).
 * [onCopied] lets the step show its own hint while "Copied" is up.
 * Twin of the iOS key steps' Copy my key.
 */
@Composable
internal fun KeyCopyButton(nsec: String, onCopied: (Boolean) -> Unit = {}) {
    val context = LocalContext.current
    var copied by remember { mutableStateOf(false) }
    LaunchedEffect(copied) {
        onCopied(copied)
        if (copied) { delay(SECRET_CLIP_LIFETIME_MS); copied = false }
    }
    OutlinedButton(
        onClick = { copySecretKey(context, nsec); copied = true },
        border = BorderStroke(1.dp, WizardBorderActive),
        modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp),
    ) {
        Icon(
            if (copied) Icons.Default.Check else Icons.Default.ContentCopy,
            contentDescription = null,
            tint = WizardAccent,
            modifier = Modifier.size(18.dp),
        )
        Spacer(Modifier.width(8.dp))
        Text(
            if (copied) "Copied" else "Copy my key",
            color = WizardAccent,
            fontSize = 15.sp,
            fontWeight = FontWeight.SemiBold,
        )
    }
}
