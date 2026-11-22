package com.nostrvault.ui.screens.feed

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Verified
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.relay.HavenBridge
import com.nostrvault.service.NostrService
import com.nostrvault.setup.InviterWelcome
import com.nostrvault.ui.components.AvatarImage
import com.nostrvault.ui.theme.*
import dagger.hilt.EntryPoint
import dagger.hilt.InstallIn
import dagger.hilt.android.EntryPointAccessors
import dagger.hilt.components.SingletonComponent
import kotlinx.coroutines.launch

@EntryPoint
@InstallIn(SingletonComponent::class)
internal interface InviterWelcomeEntryPoint {
    fun nostrService(): NostrService
}

/**
 * Where the feed puts [InviterWelcomeCard]: above the first row, for the
 * active account while [InviterWelcome] says so, following account switches.
 * Drawn inside the first row's item rather than as an item of its own, so
 * the feed's row indexes (FeedStayPut, held taps) don't move. Twin of iOS
 * InviterWelcomeSlot (#2417).
 */
@Composable
internal fun InviterWelcomeSlot(onMessage: (String) -> Unit) {
    val context = LocalContext.current
    val nostr = remember(context) {
        EntryPointAccessors.fromApplication(context.applicationContext, InviterWelcomeEntryPoint::class.java).nostrService()
    }
    val account = nostr.activeHexPubkey
    var inviter by remember(account) {
        mutableStateOf(InviterWelcome.inviterFor(InviterWelcome.load(context), account, System.currentTimeMillis()))
    }
    AnimatedVisibility(visible = inviter != null) {
        inviter?.let { pk ->
            InviterWelcomeCard(
                inviter = pk,
                nostr = nostr,
                onMessage = onMessage,
                onDone = { inviter = null },
                modifier = Modifier.padding(start = 12.dp, end = 12.dp, top = 6.dp, bottom = 6.dp),
            )
        }
    }
}

/**
 * The first card on a new account's feed when an invite brought it in: the
 * inviter, "invited you", Wave back (a one-tap public note that mentions
 * them, so they see you made it) and Message. The Vault chip says the key
 * steps are done: setup asks for the key, spare and lock before the feed.
 */
@Composable
private fun InviterWelcomeCard(
    inviter: String,
    nostr: NostrService,
    onMessage: (String) -> Unit,
    onDone: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val profiles by nostr.profiles.collectAsState()
    val profile = profiles[inviter]
    val canSign = com.nostrvault.ui.components.rememberCanSign()
    val accent = LocalNostrVaultColors.current.primary
    var waving by remember { mutableStateOf(false) }
    var waveFailed by remember { mutableStateOf(false) }
    LaunchedEffect(inviter) { nostr.fetchMissingProfiles(listOf(inviter)) }
    val name = profile?.bestName?.takeIf { it.isNotBlank() }
        ?: HavenBridge.hexToNpub(inviter)?.let { it.take(12) + "…" } ?: inviter.take(8)

    fun wave() {
        val npub = HavenBridge.hexToNpub(inviter) ?: return
        val account = nostr.activeHexPubkey.lowercase()
        waving = true
        waveFailed = false
        scope.launch {
            val event = runCatching {
                nostr.signEventAsync(kind = 1, content = InviterWelcome.waveContent(npub), tags = InviterWelcome.waveTags(inviter))
            }.getOrNull()
            waving = false
            // Only as the account this card is for.
            if (event == null || !event.pubkey.equals(account, ignoreCase = true)) {
                waveFailed = true
                return@launch
            }
            nostr.postEvent(event)
            InviterWelcome.markWaved(context)
            onDone()
        }
    }

    Column(
        modifier = modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(16.dp))
            .background(SecondaryGroupedBg)
            .border(1.dp, accent.copy(alpha = 0.3f), RoundedCornerShape(16.dp))
            .padding(16.dp),
    ) {
        Row(verticalAlignment = Alignment.Top) {
            AvatarImage(url = profile?.pictureURL, pubkey = inviter, size = 48.dp, displayName = profile?.bestName)
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Text(name, color = PrimaryText, fontSize = 16.sp, fontWeight = FontWeight.Bold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Spacer(Modifier.height(3.dp))
                Text("invited you to Nostr Vault", color = SecondaryText, fontSize = 14.sp)
            }
            Spacer(Modifier.width(8.dp))
            VaultChip()
            IconButton(
                onClick = { InviterWelcome.close(context); onDone() },
                modifier = Modifier.size(32.dp),
            ) {
                Icon(Icons.Default.Close, contentDescription = "Close", tint = SecondaryText, modifier = Modifier.size(16.dp))
            }
        }
        Spacer(Modifier.height(14.dp))
        Text(
            if (waveFailed) "Couldn't send your wave. Try again." else "Say hi so $name knows you made it.",
            color = if (waveFailed) ErrorRed else PrimaryText,
            fontSize = 15.sp,
        )
        Spacer(Modifier.height(14.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Button(
                onClick = ::wave,
                enabled = canSign && !waving,
                shape = CircleShape,
                colors = ButtonDefaults.buttonColors(containerColor = accent, contentColor = Color.White),
                modifier = Modifier.weight(1f).heightIn(min = 44.dp),
            ) {
                if (waving) {
                    CircularProgressIndicator(color = Color.White, strokeWidth = 2.dp, modifier = Modifier.size(16.dp))
                } else {
                    Text("👋")
                }
                Spacer(Modifier.width(6.dp))
                Text("Wave back", fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
            }
            OutlinedButton(
                onClick = { onMessage(inviter) },
                shape = CircleShape,
                border = androidx.compose.foundation.BorderStroke(1.5.dp, accent.copy(alpha = 0.5f)),
                modifier = Modifier.weight(1f).heightIn(min = 44.dp),
            ) {
                Text("Message", color = LocalNostrVaultColors.current.primaryText, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
            }
        }
    }
}

/** Key, spare and lock: all three are done before setup lets you in. */
@Composable
private fun VaultChip() {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .heightIn(min = 26.dp)
            .clip(CircleShape)
            .background(SuccessGreen.copy(alpha = 0.12f))
            .padding(horizontal = 8.dp)
            .clearAndSetSemantics { contentDescription = "Vault: key, spare and lock done" },
    ) {
        Icon(Icons.Default.Verified, contentDescription = null, tint = SuccessGreen, modifier = Modifier.size(12.dp))
        Spacer(Modifier.width(4.dp))
        Text("Vault 3/3", color = SuccessGreen, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
    }
}
