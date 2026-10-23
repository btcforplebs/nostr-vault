package com.nostrvault.ui.components

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.nostrvault.data.model.WotUnlock
import com.nostrvault.service.FeedService
import com.nostrvault.service.NostrService
import com.nostrvault.ui.theme.ErrorRed
import com.nostrvault.ui.theme.LocalNostrVaultColors
import dagger.hilt.EntryPoint
import dagger.hilt.InstallIn
import dagger.hilt.android.EntryPointAccessors
import dagger.hilt.components.SingletonComponent

@EntryPoint
@InstallIn(SingletonComponent::class)
interface EveryoneSwitchEntryPoint {
    fun feedService(): FeedService
    fun nostrService(): NostrService
}

/**
 * What tapping the shield shows when it would turn the Web of Trust off:
 * the sensitive content warning, or, under [WotUnlock.MIN_FOLLOWS] follows,
 * why it is locked and how far there is to go. One dialog for every shield
 * (Global, Hashtags, a #tag's feed).
 */
@Composable
fun EveryoneSwitchDialog(onDismiss: () -> Unit, onProceed: () -> Unit) {
    val context = LocalContext.current
    val services = remember(context) {
        EntryPointAccessors.fromApplication(context.applicationContext, EveryoneSwitchEntryPoint::class.java)
    }
    val followed by services.feedService().followedPubkeys.collectAsState()
    val known by services.feedService().followListIsKnown.collectAsState()
    val count = WotUnlock.followCount(followed, services.nostrService().activeHexPubkey)
    val needed = WotUnlock.followsNeeded(count)

    if (known && needed == 0) {
        AlertDialog(
            onDismissRequest = onDismiss,
            title = { Text("Sensitive Content Warning") },
            text = {
                Text("Everyone shows posts from people outside your Web of Trust, unfiltered. Expect spam and sensitive content.")
            },
            confirmButton = { TextButton(onClick = onProceed) { Text("Proceed", color = ErrorRed) } },
            dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
        )
        return
    }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Web of Trust stays on for now") },
        text = {
            Column {
                Text(
                    "Your Web of Trust keeps spam and strangers out of your feeds. " +
                        "You can turn it off once you follow at least ${WotUnlock.MIN_FOLLOWS} people.",
                )
                Spacer(Modifier.height(16.dp))
                Text(
                    if (known) WotUnlock.progressLine(needed) else "Checking who you follow…",
                    fontWeight = FontWeight.SemiBold,
                )
                Spacer(Modifier.height(8.dp))
                LinearProgressIndicator(
                    progress = { if (known) count.coerceAtMost(WotUnlock.MIN_FOLLOWS) / WotUnlock.MIN_FOLLOWS.toFloat() else 0f },
                    color = LocalNostrVaultColors.current.primary,
                )
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text("OK") } },
    )
}
