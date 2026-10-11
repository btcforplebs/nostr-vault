package com.nostrvault.ui.screens

import androidx.compose.animation.*
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.ui.theme.*
import kotlinx.coroutines.flow.first

/** The feature descriptions that used to fill the first screen. */
@Composable
internal fun WhatsInsideSheet(onDone: () -> Unit) {
    val features = listOf(
        Triple(NostrVaultIcons.AppIcon, "Personal Relay", "Run your own relay on-device. Notes are stored locally and broadcast to the network — you always have a copy."),
        Triple(NostrVaultIcons.Articles, "Full Nostr Client", "Browse your feed, post notes, reply, repost, and discover content from the network."),
        Triple(NostrVaultIcons.Lock, "Private Messaging", "NIP-17 encrypted DMs that stay on your device. No third-party server reads your conversations."),
        Triple(NostrVaultIcons.Media, "Blossom Media", "Host images and videos on your device with Blossom. Mirror media from the network to your local storage."),
        Triple(NostrVaultIcons.Zap, "Lightning Zaps", "Send and receive zaps over Lightning by connecting your own wallet with Nostr Wallet Connect."),
    )
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 20.dp)
            .padding(bottom = 20.dp)
            .navigationBarsPadding(),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
            Text(
                text = "What's inside",
                color = PrimaryText,
                fontSize = 20.sp,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier
                    .weight(1f)
                    .semantics { heading() },
            )
            TextButton(onClick = onDone) {
                Text("Done", color = WizardAccent, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
            }
        }
        Spacer(Modifier.height(12.dp))
        for ((icon, title, line) in features) {
            Row(
                verticalAlignment = Alignment.Top,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(bottom = 10.dp)
                    .background(WizardBgCard, RoundedCornerShape(12.dp))
                    .border(1.dp, BorderStrong, RoundedCornerShape(12.dp))
                    .padding(14.dp)
                    .semantics(mergeDescendants = true) {},
            ) {
                Icon(icon, contentDescription = null, tint = WizardAccent, modifier = Modifier.size(22.dp))
                Spacer(Modifier.width(14.dp))
                Column {
                    Text(title, color = PrimaryText, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
                    Text(line, color = SecondaryText, fontSize = 14.sp, lineHeight = 20.sp)
                }
            }
        }
    }
}
